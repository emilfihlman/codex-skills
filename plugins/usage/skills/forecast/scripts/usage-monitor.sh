#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: usage-monitor.sh <once|install|start|stop|uninstall|status|watch>

Polls Codex backend usage through an installed usage helper and writes forecast
files under ~/.codex/usage by default.

Commands:
  once    Query once and update the forecast files.
  install Install or update the user systemd units without starting them.
  start   Install, enable, and start the user systemd forecast timer.
  stop    Disable and stop the user systemd forecast timer.
  uninstall
          Disable the timer and remove its user systemd units.
  status  Show timer status and forecast file paths.
  watch   Poll in the foreground for manual debugging.

Environment:
  CODEX_USAGE_STATE_DIR            Override output directory.
  CODEX_USAGE_MONITOR_INTERVAL     Override timer/watch interval in seconds.
  CODEX_USAGE_FORECAST_LOOKBACK    Override burn-rate lookback in minutes.
  CODEX_USAGE_FORECAST_MIN_ELAPSED Override minimum sample span in minutes.
  CODEX_USAGE_FORECAST_HISTORY     Override max retained samples.
  CODEX_USAGE_HELPER               Override usage helper path.
  CODEX_SYSTEMD_USER_DIR           Override user unit directory.
EOF
}

script_dir="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)"
script_path="$script_dir/$(basename -- "${BASH_SOURCE[0]}")"
if command -v readlink >/dev/null 2>&1; then
  resolved_script="$(readlink -f -- "$script_path" 2>/dev/null || true)"
  if [[ -n "$resolved_script" ]]; then
    script_path="$resolved_script"
    script_dir="${script_path%/*}"
  fi
fi
codex_home="${CODEX_HOME:-$HOME/.codex}"
state_dir="${CODEX_USAGE_STATE_DIR:-$HOME/.codex/usage}"
if [[ -n "${CODEX_USAGE_HELPER:-}" ]]; then
  helper="$CODEX_USAGE_HELPER"
else
  helper_candidates=(
    "$script_dir/../../check/scripts/show-codex-usage.sh"
    "$script_dir/../../codex-usage/scripts/show-codex-usage.sh"
    "$HOME/.agents/skills/codex-usage/scripts/show-codex-usage.sh"
    "$codex_home/skills/codex-usage/scripts/show-codex-usage.sh"
  )
  helper="$codex_home/skills/codex-usage/scripts/show-codex-usage.sh"
  for helper_candidate in "${helper_candidates[@]}"; do
    if [[ -x "$helper_candidate" ]]; then
      helper="$helper_candidate"
      break
    fi
  done
fi
interval="${CODEX_USAGE_MONITOR_INTERVAL:-60}"
lookback_minutes="${CODEX_USAGE_FORECAST_LOOKBACK:-180}"
min_elapsed_minutes="${CODEX_USAGE_FORECAST_MIN_ELAPSED:-15}"
history_limit="${CODEX_USAGE_FORECAST_HISTORY:-10080}"
service_name="codex-usage-forecast.service"
timer_name="codex-usage-forecast.timer"
systemd_user_dir="${CODEX_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
samples_file="$state_dir/codex-usage-samples.jsonl"
forecast_json="$state_dir/codex-usage-forecast.json"
forecast_md="$state_dir/codex-usage-forecast.md"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

positive_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "$name must be a positive integer; got: $value" >&2
    exit 2
  fi
}

nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]]; then
    echo "$name must be a non-negative integer; got: $value" >&2
    exit 2
  fi
}

validate_parameters() {
  positive_integer CODEX_USAGE_MONITOR_INTERVAL "$interval"
  positive_integer CODEX_USAGE_FORECAST_LOOKBACK "$lookback_minutes"
  nonnegative_integer CODEX_USAGE_FORECAST_MIN_ELAPSED "$min_elapsed_minutes"
  positive_integer CODEX_USAGE_FORECAST_HISTORY "$history_limit"
}

temp_files=()
new_temp() {
  REPLY="$(mktemp -- "$1")"
  temp_files+=("$REPLY")
}

forget_temp() {
  local target="$1"
  local item
  local remaining=()
  for item in "${temp_files[@]}"; do
    if [[ "$item" != "$target" ]]; then
      remaining+=("$item")
    fi
  done
  temp_files=("${remaining[@]}")
}

cleanup_temps() {
  if ((${#temp_files[@]} > 0)); then
    rm -f -- "${temp_files[@]}"
  fi
}

trim_samples() {
  local tmp
  if [[ -f "$samples_file" ]]; then
    new_temp "$state_dir/.codex-usage-samples.XXXXXX"
    tmp="$REPLY"
    tail -n "$history_limit" "$samples_file" >"$tmp"
    mv "$tmp" "$samples_file"
    forget_temp "$tmp"
  fi
}

write_once() (
  need jq
  need date
  need flock
  need mktemp
  mkdir -p "$state_dir"
  trap cleanup_temps EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  exec {lock_fd}>"$state_dir/.codex-usage-forecast.lock"
  flock -x "$lock_fd"

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

  payload="$(
    jq -n \
      --argjson current_sample "$sample" \
      --slurpfile samples "$samples_file" \
      --arg source "chatgpt backend /backend-api/wham/usage via usage helper" \
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
            | .will_run_out_before_reset = (if $reset_at == null then null else ($current.sampled_at_epoch < $reset_at) end)
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
                    | .will_run_out_before_reset = (if $reset_at == null then null else ($eta < $reset_at) end)
                    | .status = (
                        if $reset_at == null then "exhaustion_predicted_reset_unknown"
                        elif $eta < $reset_at then "runs_out_before_reset"
                        else "survives_until_reset"
                        end
                      )
                  end
              end
          end;
      ($current_sample) as $current
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
  new_temp "$state_dir/.codex-usage-forecast.json.XXXXXX"
  tmp_json="$REPLY"
  printf '%s\n' "$payload" >"$tmp_json"
  mv "$tmp_json" "$forecast_json"
  forget_temp "$tmp_json"

  new_temp "$state_dir/.codex-usage-forecast.md.XXXXXX"
  tmp_md="$REPLY"
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
      "Source: ChatGPT backend `/backend-api/wham/usage` via the usage helper.",
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
  forget_temp "$tmp_md"

  echo "Updated $forecast_md"
  echo "Forecast JSON: $forecast_json"
)

systemd_escape_value() {
  local value="$1"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "Systemd unit values must not contain line breaks." >&2
    return 1
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '%s' "$value"
}

install_units() (
  need systemctl
  need mktemp
  mkdir -p "$systemd_user_dir"
  trap cleanup_temps EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local service_path timer_path service_tmp timer_tmp
  local unit_script unit_state unit_helper
  service_path="$systemd_user_dir/$service_name"
  timer_path="$systemd_user_dir/$timer_name"
  unit_script="$(systemd_escape_value "$script_path")"
  unit_state="$(systemd_escape_value "$state_dir")"
  unit_helper="$(systemd_escape_value "$helper")"

  new_temp "$systemd_user_dir/.$service_name.XXXXXX"
  service_tmp="$REPLY"
  new_temp "$systemd_user_dir/.$timer_name.XXXXXX"
  timer_tmp="$REPLY"

  cat >"$service_tmp" <<EOF
[Unit]
Description=Update Codex usage forecast
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
UMask=0077
ExecStart=:"$unit_script" once
Environment="CODEX_USAGE_STATE_DIR=$unit_state"
Environment="CODEX_USAGE_HELPER=$unit_helper"
Environment="CODEX_USAGE_FORECAST_LOOKBACK=$lookback_minutes"
Environment="CODEX_USAGE_FORECAST_MIN_ELAPSED=$min_elapsed_minutes"
Environment="CODEX_USAGE_FORECAST_HISTORY=$history_limit"
EOF

  cat >"$timer_tmp" <<EOF
[Unit]
Description=Poll Codex usage forecast every $interval seconds

[Timer]
OnBootSec=${interval}s
OnUnitActiveSec=${interval}s
AccuracySec=10s
Persistent=true
Unit=$service_name

[Install]
WantedBy=timers.target
EOF

  mv "$service_tmp" "$service_path"
  forget_temp "$service_tmp"
  mv "$timer_tmp" "$timer_path"
  forget_temp "$timer_tmp"
  systemctl --user daemon-reload
  echo "Installed $service_path"
  echo "Installed $timer_path"
)

start_timer() {
  install_units
  systemctl --user enable --now "$timer_name"
}

stop_timer() {
  need systemctl
  systemctl --user disable --now "$timer_name" || true
}

uninstall_timer() {
  need systemctl
  stop_timer
  rm -f -- "$systemd_user_dir/$service_name" "$systemd_user_dir/$timer_name"
  systemctl --user daemon-reload
  systemctl --user reset-failed "$service_name" "$timer_name" >/dev/null 2>&1 || true
  echo "Removed $systemd_user_dir/$service_name"
  echo "Removed $systemd_user_dir/$timer_name"
}

status_timer() {
  echo "Forecast: $forecast_md"
  echo "JSON: $forecast_json"
  echo "Samples: $samples_file"
  echo "Service unit: $systemd_user_dir/$service_name"
  echo "Timer unit: $systemd_user_dir/$timer_name"
  echo "Logs: journalctl --user -u $service_name"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user --no-pager status "$timer_name" "$service_name" || true
  fi
}

cmd="${1:-status}"
case "$cmd" in
  once|install|start|stop|uninstall|status|watch) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

validate_parameters

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
  install)
    install_units
    ;;
  start)
    start_timer
    ;;
  stop)
    stop_timer
    ;;
  uninstall)
    uninstall_timer
    ;;
  status)
    status_timer
    ;;
esac
