#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: usage-monitor.sh <once|start|stop|status|watch>

Polls Codex backend usage through the usage check helper and writes forecast
files under ~/.codex/usage by default.

Commands:
  once    Query once and update the forecast files.
  start   Enable and start the user systemd forecast timer.
  stop    Disable and stop the user systemd forecast timer.
  status  Show timer status and forecast file paths.
  watch   Poll in the foreground for manual debugging.

Environment:
  CODEX_USAGE_STATE_DIR            Override output directory.
  CODEX_USAGE_MONITOR_INTERVAL     Override watch interval in seconds.
  CODEX_USAGE_FORECAST_LOOKBACK    Override burn-rate lookback in minutes.
  CODEX_USAGE_FORECAST_MIN_ELAPSED Override minimum sample span in minutes.
  CODEX_USAGE_FORECAST_HISTORY     Override max retained samples.
  CODEX_USAGE_HELPER               Override usage check helper path.
EOF
}

state_dir="${CODEX_USAGE_STATE_DIR:-$HOME/.codex/usage}"
script_dir="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)"
helper="${CODEX_USAGE_HELPER:-$script_dir/../../check/scripts/show-codex-usage.sh}"
interval="${CODEX_USAGE_MONITOR_INTERVAL:-60}"
lookback_minutes="${CODEX_USAGE_FORECAST_LOOKBACK:-180}"
min_elapsed_minutes="${CODEX_USAGE_FORECAST_MIN_ELAPSED:-15}"
history_limit="${CODEX_USAGE_FORECAST_HISTORY:-10080}"
service_name="codex-usage-forecast.service"
timer_name="codex-usage-forecast.timer"
samples_file="$state_dir/codex-usage-samples.jsonl"
forecast_json="$state_dir/codex-usage-forecast.json"
forecast_md="$state_dir/codex-usage-forecast.md"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

trim_samples() {
  if [[ -f "$samples_file" ]]; then
    tmp="$samples_file.tmp.$$"
    tail -n "$history_limit" "$samples_file" >"$tmp"
    mv "$tmp" "$samples_file"
  fi
}

write_once() {
  need jq
  need date
  mkdir -p "$state_dir"
  if [[ ! -x "$helper" ]]; then
    echo "Codex usage helper is not executable: $helper" >&2
    exit 1
  fi

  now="$(date -u +%s)"
  usage_json="$("$helper" --json)"
  sample="$(
    jq -c --argjson now "$now" '
      def number_or_null:
        if . == null then null else tonumber end;
      def compact_window($w):
        ($w // {}) as $x
        | ($x.used_percent | number_or_null) as $used
        | ($x.reset_at | number_or_null) as $reset_at
        | {
            used_percent: $used,
            remaining_percent: (if $used == null then null else ([0, (100 - $used)] | max) end),
            limit_window_seconds: ($x.limit_window_seconds | number_or_null),
            reset_after_seconds: ($x.reset_after_seconds | number_or_null),
            reset_at: $reset_at,
            reset_at_utc: (if $reset_at == null then null else ($reset_at | todateiso8601) end)
          };
      . as $usage
      | ($usage.rate_limit // {}) as $rate
      | ($usage.credits // {}) as $credits
      | ($usage.rate_limit_reset_credits // {}) as $reset_credits
      | {
          sampled_at_epoch: $now,
          sampled_at_utc: ($now | todateiso8601),
          plan_type: $usage.plan_type,
          allowed: $rate.allowed,
          limit_reached: $rate.limit_reached,
          rate_limit_reached_type: $usage.rate_limit_reached_type,
          primary_window: compact_window($rate.primary_window),
          secondary_window: compact_window($rate.secondary_window),
          reset_credits_available: $reset_credits.available_count,
          usage_credits_balance: $credits.balance,
          additional_rate_limits: [
            ($usage.additional_rate_limits // [])[]
            | (.rate_limit // {}) as $extra_rate
            | {
                limit_name: (.limit_name // .metered_feature // "unnamed"),
                metered_feature,
                allowed: $extra_rate.allowed,
                limit_reached: $extra_rate.limit_reached,
                primary_window: compact_window($extra_rate.primary_window),
                secondary_window: compact_window($extra_rate.secondary_window)
              }
          ]
        }
    ' <<<"$usage_json"
  )"
  printf '%s\n' "$sample" >>"$samples_file"
  trim_samples

  current_sample_file="$state_dir/current-sample.tmp.$$"
  printf '%s\n' "$sample" >"$current_sample_file"
  payload="$(
    jq -n \
      --slurpfile current_file "$current_sample_file" \
      --slurpfile samples "$samples_file" \
      --arg source "chatgpt backend /backend-api/wham/usage via usage check skill" \
      --arg markdown "$forecast_md" \
      --arg json "$forecast_json" \
      --arg samples_jsonl "$samples_file" \
      --argjson lookback "$lookback_minutes" \
      --argjson min_elapsed "$min_elapsed_minutes" '
      def duration($seconds):
        if $seconds == null then "unknown"
        else
          (($seconds | floor) as $n
          | ($n / 86400 | floor) as $d
          | (($n % 86400) / 3600 | floor) as $h
          | (($n % 3600) / 60 | floor) as $m
          | if $d > 0 then "\($d)d \($h)h \($m)m"
            elif $h > 0 then "\($h)h \($m)m"
            else "\($m)m"
            end)
        end;
      def number_or_null:
        if . == null then null else tonumber end;
      def prediction($current; $key; $label):
        ($current[$key] // {}) as $w
        | ($w.used_percent | number_or_null) as $used
        | ($w.reset_at | number_or_null) as $reset_at
        | (if $used == null then null else ([0, (100 - $used)] | max) end) as $remaining
        | [ $samples[]
            | select((.[$key].used_percent // null) != null)
            | select((.sampled_at_epoch // 0) >= ($current.sampled_at_epoch - ($lookback * 60)))
            | select(($reset_at == null) or ((.[$key].reset_at | number_or_null) == $reset_at))
          ] as $relevant
        | {
            label: $label,
            used_percent: $used,
            remaining_percent: $remaining,
            reset_at: $reset_at,
            reset_at_utc: (if $reset_at == null then null else ($reset_at | todateiso8601) end),
            reset_after_seconds: (if $reset_at == null then null else ([0, ($reset_at - $current.sampled_at_epoch)] | max) end),
            reset_after_human: (if $reset_at == null then null else duration([0, ($reset_at - $current.sampled_at_epoch)] | max) end),
            status: "unknown",
            basis: "need at least two samples in the same reset window",
            slope_percent_per_hour: null,
            eta_exhaustion_epoch: null,
            eta_exhaustion_utc: null,
            minutes_to_exhaustion: null,
            will_run_out_before_reset: null
          } as $base
        | if $used == null then
            $base | .basis = "current sample has no used_percent"
          elif $used >= 100 then
            $base
            | .status = "exhausted"
            | .basis = "current window is at or above 100%"
            | .eta_exhaustion_epoch = $current.sampled_at_epoch
            | .eta_exhaustion_utc = ($current.sampled_at_epoch | todateiso8601)
            | .minutes_to_exhaustion = 0
            | .will_run_out_before_reset = true
          elif ($relevant | length) < 2 then
            $base | .basis = "\($relevant | length) sample(s) in last \($lookback) minutes"
          else
            ($relevant[0]) as $first
            | ($relevant[-1]) as $last
            | ((($last.sampled_at_epoch - $first.sampled_at_epoch) / 60)) as $elapsed_minutes
            | if $elapsed_minutes < $min_elapsed then
                $base | .basis = "samples span \($elapsed_minutes | tostring)m; need at least \($min_elapsed)m"
              else
                ((($last[$key].used_percent - $first[$key].used_percent) / $elapsed_minutes)) as $slope_per_minute
                | ($base
                  | .slope_percent_per_hour = ($slope_per_minute * 60)
                  | .basis = "\($relevant | length) sample(s) over \($elapsed_minutes | tostring)m in this reset window") as $with_slope
                | if $slope_per_minute <= 0 then
                    $with_slope
                    | .status = "not_increasing"
                    | .will_run_out_before_reset = false
                  else
                    ($remaining / $slope_per_minute) as $minutes_to_exhaustion
                    | ($current.sampled_at_epoch + (($minutes_to_exhaustion * 60) | floor)) as $eta
                    | $with_slope
                    | .minutes_to_exhaustion = $minutes_to_exhaustion
                    | .eta_exhaustion_epoch = $eta
                    | .eta_exhaustion_utc = ($eta | todateiso8601)
                    | .will_run_out_before_reset = (($reset_at == null) or ($eta < $reset_at))
                    | .status = (if (($reset_at == null) or ($eta < $reset_at)) then "runs_out_before_reset" else "survives_until_reset" end)
                  end
              end
          end;
      ($current_file[0]) as $current
      |
      {
        primary_window: prediction($current; "primary_window"; "5h window"),
        secondary_window: prediction($current; "secondary_window"; "weekly window")
      } as $predictions
      | {
          updated_at_epoch: $current.sampled_at_epoch,
          updated_at_utc: $current.sampled_at_utc,
          source: $source,
          sample_count: ($samples | length),
          current: $current,
          predictions: $predictions,
          files: {
            markdown: $markdown,
            json: $json,
            samples_jsonl: $samples_jsonl
          }
        }
    '
  )"
  rm -f "$current_sample_file"
  tmp_json="$forecast_json.tmp.$$"
  printf '%s\n' "$payload" >"$tmp_json"
  mv "$tmp_json" "$forecast_json"

  tmp_md="$forecast_md.tmp.$$"
  jq -r '
    def duration($seconds):
      if $seconds == null then "unknown"
      else
        (($seconds | floor) as $n
        | ($n / 86400 | floor) as $d
        | (($n % 86400) / 3600 | floor) as $h
        | (($n % 3600) / 60 | floor) as $m
        | if $d > 0 then "\($d)d \($h)h \($m)m"
          elif $h > 0 then "\($h)h \($m)m"
          else "\($m)m"
          end)
      end;
    def percent($value): if $value == null then "unknown" else "\($value)%" end;
    def slope($value): if $value == null then "unknown" else "\(($value * 100 | round) / 100)%/h" end;
    def window_lines($w):
      [
        "- Used: \(percent($w.used_percent))",
        "- Remaining: \(percent($w.remaining_percent))",
        "- Reset: \($w.reset_at_utc // "unknown") (\($w.reset_after_human // "unknown"))",
        "- Burn rate: \(slope($w.slope_percent_per_hour))",
        "- Exhaustion ETA: \($w.eta_exhaustion_utc // "not predicted") (\(if $w.minutes_to_exhaustion == null then "unknown" else duration($w.minutes_to_exhaustion * 60) end))",
        "- Status: \($w.status)",
        "- Basis: \($w.basis)"
      ];
    [
      "# Codex Usage Forecast",
      "",
      "Updated: \(.updated_at_utc)",
      "Source: ChatGPT backend `/backend-api/wham/usage` via `$usage:check`.",
      "",
      "## Current",
      "",
      "- Plan: \(.current.plan_type)",
      "- Allowed: \(.current.allowed)",
      "- Limit reached: \(.current.limit_reached)",
      "- Rate-limit reached type: \(.current.rate_limit_reached_type // "none")",
      "- Reset credits available: \(.current.reset_credits_available)",
      "- Usage credits balance: \(.current.usage_credits_balance)",
      "",
      "## 5h Window",
      ""
    ]
    + window_lines(.predictions.primary_window)
    + [
      "",
      "## Weekly Window",
      ""
    ]
    + window_lines(.predictions.secondary_window)
    + [
      "",
      "## Files",
      "",
      "- JSON: `\(.files.json)`",
      "- Samples: `\(.files.samples_jsonl)`",
      ""
    ]
    | .[]
  ' <<<"$payload" >"$tmp_md"
  mv "$tmp_md" "$forecast_md"

  echo "Updated $forecast_md"
  echo "Forecast JSON: $forecast_json"
}

start_timer() {
  need systemctl
  systemctl --user daemon-reload
  systemctl --user enable --now "$timer_name"
}

stop_timer() {
  need systemctl
  systemctl --user disable --now "$timer_name" || true
}

status_timer() {
  echo "Forecast: $forecast_md"
  echo "JSON: $forecast_json"
  echo "Samples: $samples_file"
  echo "Logs: journalctl --user -u $service_name"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user --no-pager status "$timer_name" "$service_name" || true
  fi
}

cmd="${1:-status}"
case "$cmd" in
  once)
    write_once
    ;;
  watch)
    while true; do
      write_once || true
      sleep "$interval"
    done
    ;;
  start)
    start_timer
    ;;
  stop)
    stop_timer
    ;;
  status)
    status_timer
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
