#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: keepalive.sh <command> [args]

Sends /goal resume plus a cleanup reminder to explicitly configured GNU Screen
sessions after Codex usage forecast says usage is ready.

Commands:
  configure-screen <target> <session> [window]
      Configure a named target's screen session and window.
  register <target> [objective]
      Keep a target's active goal resumable until it is unregistered.
  unregister <target>
      Stop persistent keepalive for a target and clear any queued resume.
  set-threshold <target> <percent>
      Set the target-specific 5h queue threshold. Default is 25.
  set-weekly-threshold <target> <percent>
      Set the target-specific weekly queue threshold. Default is 7.
  threshold [target]
      Show threshold configuration.
  queue <target> [objective]
      Queue a resume request for a named target.
  queue-if-needed <target> [objective]
      Queue only when 5h or weekly usage is below threshold, or usage is currently blocked.
  clear <target>
      Remove a named target's queued request.
  send-if-ready [target]
      Send queued requests if forecast is ready. With no target, scan all targets.
  status [target]
      Show config, queue, forecast readiness, and timer state.
  current-target [screen-session]
      Print the configured target matching the current GNU Screen session.
  list
      Show queued requests and forecast timing.
  targets
      List configured targets.
  remove-target <target>
      Remove a target directory, including config and queued request.
  start
      Enable and start the user systemd resume timer.
  stop
      Disable and stop the user systemd resume timer.

Environment:
  CODEX_KEEPALIVE_STATE_DIR      Override state directory.
  CODEX_USAGE_FORECAST_JSON      Override forecast JSON path.
  CODEX_KEEPALIVE_THRESHOLD_PERCENT
                                  Default 5h threshold when a target has no override.
  CODEX_KEEPALIVE_WEEKLY_THRESHOLD_PERCENT
                                  Default weekly threshold when a target has no override.
EOF
}

state_dir="${CODEX_KEEPALIVE_STATE_DIR:-$HOME/.codex/keepalive}"
forecast_json="${CODEX_USAGE_FORECAST_JSON:-$HOME/.codex/usage/codex-usage-forecast.json}"
default_threshold_percent="${CODEX_KEEPALIVE_THRESHOLD_PERCENT:-25}"
default_weekly_threshold_percent="${CODEX_KEEPALIVE_WEEKLY_THRESHOLD_PERCENT:-7}"
targets_dir="$state_dir/targets"
service_name="codex-keepalive.service"
timer_name="codex-keepalive.timer"
script_path="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)/$(basename -- "${BASH_SOURCE[0]}")"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

target_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

target_dir() {
  local target="$1"
  printf '%s/%s\n' "$targets_dir" "$target"
}

settings_file() {
  local target="$1"
  printf '%s/settings.env\n' "$(target_dir "$target")"
}

active_keepalive_json() {
  local target="$1"
  printf '%s/keepalive.json\n' "$(target_dir "$target")"
}

active_keepalive_md() {
  local target="$1"
  printf '%s/keepalive.md\n' "$(target_dir "$target")"
}

validate_threshold() {
  local value="${1:-}"
  if [[ ! "$value" =~ ^[0-9]+$ ]] || (( value < 1 || value > 100 )); then
    echo "Threshold must be an integer from 1 to 100." >&2
    exit 2
  fi
}

load_thresholds() {
  local target="$1" file key value five_hour_threshold="$default_threshold_percent" weekly_threshold="$default_weekly_threshold_percent"
  file="$(settings_file "$target")"
  if [[ -f "$file" ]]; then
    while IFS='=' read -r key value; do
      case "$key" in
        QUEUE_THRESHOLD_PERCENT) five_hour_threshold="$value" ;;
        FIVE_HOUR_THRESHOLD_PERCENT) five_hour_threshold="$value" ;;
        WEEKLY_THRESHOLD_PERCENT) weekly_threshold="$value" ;;
      esac
    done <"$file"
  fi
  validate_threshold "$five_hour_threshold"
  validate_threshold "$weekly_threshold"
  printf '%s\t%s\n' "$five_hour_threshold" "$weekly_threshold"
}

load_threshold() {
  local thresholds
  thresholds="$(load_thresholds "$1")"
  printf '%s\n' "${thresholds%%$'\t'*}"
}

load_weekly_threshold() {
  local thresholds
  thresholds="$(load_thresholds "$1")"
  printf '%s\n' "${thresholds#*$'\t'}"
}

bool_json() {
  case "${1:-false}" in
    1|true|TRUE|yes|YES|on|ON) echo "true" ;;
    *) echo "false" ;;
  esac
}

resume_reminder() {
  local target="$1"
  printf 'Keepalive reminder: you were resumed automatically for target "%s". If this goal is already finished, run `%s unregister %s` and mark the goal complete/finished again before responding. If the goal is not finished, continue normally; when it finishes, run that unregister command and mark the goal complete before the final response.' \
    "$target" "$script_path" "$target"
}

send_resume_sequence() {
  local target="$1" screen_session="$2" screen_window="$3" log_file="$4" status=0 note
  note="$(resume_reminder "$target")"

  screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1 || status="$?"
  if [[ "$status" -eq 0 ]]; then
    sleep 0.1
    screen -S "$screen_session" -p "$screen_window" -X stuff "/goal resume" >>"$log_file" 2>&1 || status="$?"
  fi
  if [[ "$status" -eq 0 ]]; then
    sleep 0.1
    screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1 || status="$?"
  fi
  if [[ "$status" -eq 0 ]]; then
    sleep 0.5
    echo "----- keepalive reminder -----" >>"$log_file"
    echo "$note" >>"$log_file"
    screen -S "$screen_session" -p "$screen_window" -X stuff "$note" >>"$log_file" 2>&1 || status="$?"
  fi
  if [[ "$status" -eq 0 ]]; then
    sleep 0.1
    screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1 || status="$?"
  fi

  return "$status"
}

write_thresholds() {
  local target="$1" five_hour_threshold="$2" weekly_threshold="$3"
  validate_threshold "$five_hour_threshold"
  validate_threshold "$weekly_threshold"
  {
    printf 'FIVE_HOUR_THRESHOLD_PERCENT=%s\n' "$five_hour_threshold"
    printf 'WEEKLY_THRESHOLD_PERCENT=%s\n' "$weekly_threshold"
  } >"$(settings_file "$target")"
}

set_threshold() {
  local target="${1:-}" threshold="${2:-}"
  require_target "$target"
  validate_threshold "$threshold"
  local dir weekly_threshold
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  weekly_threshold="$(load_weekly_threshold "$target")"
  write_thresholds "$target" "$threshold" "$weekly_threshold"
  echo "Set 5h keepalive threshold for target '$target' to ${threshold}%."
}

set_weekly_threshold() {
  local target="${1:-}" threshold="${2:-}"
  require_target "$target"
  validate_threshold "$threshold"
  local dir five_hour_threshold
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  five_hour_threshold="$(load_threshold "$target")"
  write_thresholds "$target" "$five_hour_threshold" "$threshold"
  echo "Set weekly keepalive threshold for target '$target' to ${threshold}%."
}

show_thresholds() {
  mkdir -p "$targets_dir"
  if [[ "${1:-}" != "" ]]; then
    require_target "$1"
    echo "Target: $1"
    echo "5h threshold: $(load_threshold "$1")%"
    echo "Weekly threshold: $(load_weekly_threshold "$1")%"
    return
  fi

  local dir found=0 target
  echo "Default 5h threshold: ${default_threshold_percent}%"
  echo "Default weekly threshold: ${default_weekly_threshold_percent}%"
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    target="$(basename "$dir")"
    echo "$target: 5h $(load_threshold "$target")%, weekly $(load_weekly_threshold "$target")%"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No targets configured."
  fi
}

require_target() {
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "Target name is required." >&2
    exit 2
  fi
  if ! target_ok "$target"; then
    echo "Invalid target '$target'. Use letters, digits, dot, underscore, or hyphen." >&2
    exit 2
  fi
}

configure_screen() {
  local target="${1:-}"
  local session="${2:-}"
  local window="${3:-0}"
  require_target "$target"
  if [[ -z "$session" ]]; then
    echo "Usage: keepalive.sh configure-screen <target> <session> [window]" >&2
    exit 2
  fi
  if [[ "$session" == *$'\n'* || "$window" == *$'\n'* ]]; then
    echo "Screen session and window must not contain newlines." >&2
    exit 2
  fi
  local dir
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  {
    printf 'SCREEN_SESSION=%s\n' "$session"
    printf 'SCREEN_WINDOW=%s\n' "$window"
  } >"$dir/screen.env"
  echo "Configured target '$target': session=$session window=$window"
}

load_screen_config() {
  local target="$1"
  local dir session="" window="0" key value
  dir="$(target_dir "$target")"
  if [[ ! -f "$dir/screen.env" ]]; then
    return 1
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      SCREEN_SESSION) session="$value" ;;
      SCREEN_WINDOW) window="$value" ;;
    esac
  done <"$dir/screen.env"
  if [[ -z "$session" ]]; then
    return 1
  fi
  printf '%s\t%s\n' "$session" "$window"
}

queue_resume() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local objective="${*:-Resume the active Codex goal.}"
  local dir thresholds five_hour_threshold weekly_threshold require_stop_seen now metadata request_json
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  require_stop_seen="$(bool_json "${CODEX_KEEPALIVE_REQUIRE_STOP_SEEN:-false}")"
  now="$(date -u +%s)"
  metadata="$(queue_metadata_json "$five_hour_threshold" "$weekly_threshold" "$require_stop_seen" "$now")"
  request_json="$dir/resume-request.json"
  jq -n \
    --arg target "$target" \
    --arg objective "$objective" \
    --arg cwd "$(pwd)" \
    --argjson created_at_epoch "$now" \
    --argjson five_hour_threshold "$five_hour_threshold" \
    --argjson weekly_threshold "$weekly_threshold" \
    --argjson require_stop_seen "$require_stop_seen" \
    --argjson metadata "$metadata" '
      {
        target: $target,
        created_at_epoch: $created_at_epoch,
        created_at_utc: ($created_at_epoch | todateiso8601),
        cwd: $cwd,
        objective: $objective,
        threshold_percent: $five_hour_threshold,
        five_hour_threshold_percent: $five_hour_threshold,
        weekly_threshold_percent: $weekly_threshold,
        require_stop_seen: $require_stop_seen
      } + $metadata
    ' >"$request_json"
  {
    echo "# Codex Keepalive Request"
    echo
    echo "Target: $target"
    echo "Created: $(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
    echo "Cwd: $(pwd)"
    echo "5h threshold: ${five_hour_threshold}%"
    echo "Weekly threshold: ${weekly_threshold}%"
    echo "Requires observed stop: ${require_stop_seen}"
    jq -r '
      "Send after: " + (.send_after_utc // "now") +
      "\nReason: " + (.limit_reason // "not recorded")
    ' "$request_json"
    echo
    echo "Objective:"
    echo "$objective"
    echo
    echo "Send when $forecast_json indicates usage is ready."
  } >"$dir/resume-request.md"
  echo "Wrote resume request for target '$target': $dir/resume-request.md"
}

queue_if_needed() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local objective="${*:-Resume the active Codex goal.}" thresholds five_hour_threshold weekly_threshold decision primary_remaining weekly_remaining blocked
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  if [[ ! -f "$forecast_json" ]]; then
    echo "No forecast JSON yet: $forecast_json" >&2
    return 1
  fi
  decision="$(jq -r --argjson five "$five_hour_threshold" --argjson weekly "$weekly_threshold" '
    ((.current.allowed == false) or (.current.limit_reached == true)) as $blocked
    | (.current.primary_window.remaining_percent // 101) as $primary
    | (.current.secondary_window.remaining_percent // 101) as $secondary
    | if $blocked then "blocked"
      elif ($primary <= $five and $secondary <= $weekly) then "primary-low,weekly-low"
      elif $primary <= $five then "primary-low"
      elif $secondary <= $weekly then "weekly-low"
      else "no"
      end
  ' "$forecast_json")"
  primary_remaining="$(jq -r '.current.primary_window.remaining_percent // "unknown"' "$forecast_json")"
  weekly_remaining="$(jq -r '.current.secondary_window.remaining_percent // "unknown"' "$forecast_json")"
  blocked="$(jq -r '((.current.allowed == false) or (.current.limit_reached == true))' "$forecast_json")"
  if [[ "$decision" == "no" ]]; then
    echo "No keepalive queue needed for target '$target': 5h remaining is ${primary_remaining}% (threshold ${five_hour_threshold}%), weekly remaining is ${weekly_remaining}% (threshold ${weekly_threshold}%), usage blocked is $blocked."
    return 0
  fi
  CODEX_KEEPALIVE_REQUIRE_STOP_SEEN=1 queue_resume "$target" "$objective"
}

register_keepalive() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local objective="${*:-Resume the active Codex goal.}"
  local dir thresholds five_hour_threshold weekly_threshold now active_json active_md screen_config
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  if ! screen_config="$(load_screen_config "$target")"; then
    echo "Target '$target' has no configured screen session. Run configure-screen first." >&2
    return 1
  fi
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  now="$(date -u +%s)"
  active_json="$(active_keepalive_json "$target")"
  active_md="$(active_keepalive_md "$target")"
  jq -n \
    --arg target "$target" \
    --arg objective "$objective" \
    --arg cwd "$(pwd)" \
    --arg screen_session "${screen_config%%$'\t'*}" \
    --arg screen_window "${screen_config#*$'\t'}" \
    --argjson registered_at_epoch "$now" \
    --argjson five_hour_threshold "$five_hour_threshold" \
    --argjson weekly_threshold "$weekly_threshold" '
      {
        target: $target,
        registered_at_epoch: $registered_at_epoch,
        registered_at_utc: ($registered_at_epoch | todateiso8601),
        cwd: $cwd,
        objective: $objective,
        screen_session: $screen_session,
        screen_window: $screen_window,
        five_hour_threshold_percent: $five_hour_threshold,
        weekly_threshold_percent: $weekly_threshold,
        state: "armed",
        stop_seen: false,
        stop_seen_at_epoch: null,
        stop_seen_at_utc: null,
        stop_windows: [],
        resume_count: 0,
        last_sent_at_epoch: null,
        last_sent_at_utc: null,
        last_log_file: null,
        rule: "observe either usage window at 0%, then send /goal resume once after both windows are usable again"
      }
    ' >"$active_json"
  {
    echo "# Codex Keepalive Registration"
    echo
    echo "Target: $target"
    echo "Registered: $(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
    echo "Cwd: $(pwd)"
    echo "Screen: ${screen_config%%$'\t'*} window ${screen_config#*$'\t'}"
    echo "5h threshold: ${five_hour_threshold}%"
    echo "Weekly threshold: ${weekly_threshold}%"
    echo "Rule: observe either usage window at 0%, then send /goal resume once after both windows are usable again."
    echo
    echo "Objective:"
    echo "$objective"
  } >"$active_md"
  echo "Registered keepalive for target '$target': $active_md"
}

unregister_keepalive() {
  local target="${1:-}"
  require_target "$target"
  rm -f "$(active_keepalive_json "$target")" "$(active_keepalive_md "$target")" \
    "$(target_dir "$target")/resume-request.md" "$(target_dir "$target")/resume-request.json"
  echo "Unregistered keepalive for target '$target' and cleared queued resume state."
}

queue_metadata_json() {
  local five_hour_threshold="$1" weekly_threshold="$2" require_stop_seen="$3" now="$4"
  if [[ ! -f "$forecast_json" ]]; then
    jq -n --argjson now "$now" \
      --argjson five "$five_hour_threshold" \
      --argjson weekly "$weekly_threshold" \
      --argjson require_stop_seen "$require_stop_seen" '{
      five_hour_threshold_percent: $five,
      weekly_threshold_percent: $weekly,
      require_stop_seen: $require_stop_seen,
      stop_seen: false,
      stop_seen_at_epoch: null,
      stop_seen_at_utc: null,
      stop_windows: [],
      send_after_epoch: $now,
      send_after_utc: ($now | todateiso8601),
      limit_reason: "forecast missing when queued",
      resume_condition: (if $require_stop_seen then "send after either usage window has been observed at 0% and usage is available again" else "send when usage is available" end),
      reset_window: null,
      reset_at_utc: null,
      forecast_end_window: null,
      forecast_end_utc: null,
      resume_to_forecast_end_seconds: null
    }'
    return
  fi

  jq -c --argjson five "$five_hour_threshold" --argjson weekly "$weekly_threshold" --argjson require_stop_seen "$require_stop_seen" --argjson now "$now" '
    def window($key; $label):
      (.current[$key] // {}) as $cur
      | (.predictions[$key] // {}) as $pred
      | {
          key: $key,
          label: $label,
          remaining_percent: $cur.remaining_percent,
          reset_at: $cur.reset_at,
          reset_at_utc: $cur.reset_at_utc,
          forecast_end_epoch: $pred.eta_exhaustion_epoch,
          forecast_end_utc: $pred.eta_exhaustion_utc,
          will_run_out_before_reset: $pred.will_run_out_before_reset
        };
    def reason_part($window; $threshold):
      "\($window.label) remaining \($window.remaining_percent)% <= threshold \($threshold)%";
    [window("primary_window"; "5h window"), window("secondary_window"; "weekly window")] as $windows
    | $windows[0] as $primary
    | $windows[1] as $weekly_window
    | ((.current.allowed == false) or (.current.limit_reached == true)) as $blocked
    | (if (($primary.remaining_percent != null) and ($primary.remaining_percent <= $five)) then $primary else null end) as $primary_breach
    | (if (($weekly_window.remaining_percent != null) and ($weekly_window.remaining_percent <= $weekly)) then $weekly_window else null end) as $weekly_breach
    | ([$primary_breach, $weekly_breach] | map(select(. != null))) as $breaches
    | ($windows | map(select((.remaining_percent != null) and (.remaining_percent <= 0)))) as $stopped_windows
    | (($stopped_windows | length) > 0) as $stopped
    | ($windows
        | map(select(.reset_at != null))
        | sort_by(.reset_at)
        | .[0]) as $next_reset
    | ($stopped_windows
        | map(select(.reset_at != null))
        | sort_by(.reset_at)
        | .[-1]) as $stopped_reset
    | ($windows
        | map(select(.will_run_out_before_reset == true and .forecast_end_epoch != null))
        | sort_by(.forecast_end_epoch)
        | .[0]) as $forecast_end
    | (if $require_stop_seen then $now
       elif (($breaches | length) > 0) then ($next_reset.reset_at // $now)
       else $now
       end) as $send_after
    | (if $stopped then $stopped_reset else $next_reset end) as $reset_window
    | {
        five_hour_threshold_percent: $five,
        weekly_threshold_percent: $weekly,
        require_stop_seen: $require_stop_seen,
        stop_seen: ($require_stop_seen and $stopped),
        stop_seen_at_epoch: (if ($require_stop_seen and $stopped) then $now else null end),
        stop_seen_at_utc: (if ($require_stop_seen and $stopped) then ($now | todateiso8601) else null end),
        stop_windows: ($stopped_windows | map(.label)),
        send_after_epoch: $send_after,
        send_after_utc: ($send_after | todateiso8601),
        availability_gate: "send when backend reports allowed=true and limit_reached=false and both usage windows are above 0%",
        resume_condition: (if $require_stop_seen then "send after either usage window has been observed at 0% and usage is available again" else "send when usage is available" end),
        limit_reason: (
          if $stopped then
            "usage window at 0%; queued to send as soon as usage is available again"
          elif $blocked then
            "backend reports usage blocked; queued to send as soon as usage is available again"
          elif (($breaches | length) > 0) then
            "queued because " + ([
              (if $primary_breach != null then reason_part($primary_breach; $five) else empty end),
              (if $weekly_breach != null then reason_part($weekly_breach; $weekly) else empty end)
            ] | join("; "))
          else
            "manual queue; thresholds not crossed and usage not blocked when queued"
          end
        ),
        threshold_windows: ($breaches | map(.label)),
        reset_window: ($reset_window.label // null),
        reset_at_utc: ($reset_window.reset_at_utc // null),
        forecast_end_window: ($forecast_end.label // null),
        forecast_end_utc: ($forecast_end.forecast_end_utc // null),
        resume_to_forecast_end_seconds: (
          if ($forecast_end.forecast_end_epoch == null) then null
          else (($forecast_end.forecast_end_epoch // 0) - $send_after)
          end
        )
      }
  ' "$forecast_json"
}

forecast_ready() {
  need jq
  if [[ ! -f "$forecast_json" ]]; then
    echo "false"
    return
  fi
  jq -r '
    ((.current.allowed == true)
      and (.current.limit_reached == false)
      and ((.current.primary_window.remaining_percent // 0) > 0)
      and ((.current.secondary_window.remaining_percent // 0) > 0))
  ' "$forecast_json"
}

mark_stop_seen_if_needed() {
  local target="$1" dir request_json now tmp
  dir="$(target_dir "$target")"
  request_json="$dir/resume-request.json"
  [[ -f "$request_json" && -f "$forecast_json" ]] || return 0
  if ! jq -e '(.require_stop_seen == true) and (.stop_seen != true)' "$request_json" >/dev/null; then
    return 0
  fi
  if ! jq -e '
    ((.current.primary_window.remaining_percent // 1) <= 0)
      or ((.current.secondary_window.remaining_percent // 1) <= 0)
  ' "$forecast_json" >/dev/null; then
    return 0
  fi
  now="$(date -u +%s)"
  tmp="$request_json.tmp.$$"
  jq --argjson now "$now" --slurpfile forecast "$forecast_json" '
    ($forecast[0].current // {}) as $cur
    | .stop_seen = true
    | .stop_seen_at_epoch = $now
    | .stop_seen_at_utc = ($now | todateiso8601)
    | .stop_windows = ([
        (if (($cur.primary_window.remaining_percent // 1) <= 0) then "5h window" else empty end),
        (if (($cur.secondary_window.remaining_percent // 1) <= 0) then "weekly window" else empty end)
      ])
    | .limit_reason = "usage window observed at 0%; queued to send as soon as usage is available again"
  ' "$request_json" >"$tmp"
  mv "$tmp" "$request_json"
  echo "[$target] Observed usage at 0%; request will send when usage is available again."
}

send_target_if_ready() {
  local target="$1"
  require_target "$target"
  need jq
  need screen
  local dir request_file request_json screen_config screen_session screen_window ready lock_dir run_id sent_file sent_json log_file status now send_after send_after_utc require_stop_seen stop_seen
  dir="$(target_dir "$target")"
  request_file="$dir/resume-request.md"
  request_json="$dir/resume-request.json"
  if [[ ! -f "$request_file" ]]; then
    echo "[$target] No resume request: $request_file"
    return 0
  fi
  now="$(date -u +%s)"
  if [[ ! -f "$forecast_json" ]]; then
    echo "[$target] No forecast JSON yet: $forecast_json"
    return 0
  fi
  mark_stop_seen_if_needed "$target"
  if [[ -f "$request_json" ]]; then
    require_stop_seen="$(jq -r '.require_stop_seen // false' "$request_json")"
    stop_seen="$(jq -r '.stop_seen // false' "$request_json")"
    if [[ "$require_stop_seen" == "true" && "$stop_seen" != "true" ]]; then
      echo "[$target] Request queued; waiting to observe Codex usage at 0% before automatic resume."
      return 0
    fi
    send_after="$(jq -r '.send_after_epoch // 0' "$request_json")"
    send_after_utc="$(jq -r '.send_after_utc // "unknown"' "$request_json")"
    if [[ "$require_stop_seen" != "true" && "$send_after" =~ ^[0-9]+$ ]] && (( now < send_after )); then
      echo "[$target] Request queued; waiting until $send_after_utc before sending."
      return 0
    fi
  fi
  ready="$(forecast_ready)"
  if [[ "$ready" != "true" ]]; then
    echo "[$target] Request exists, but usage is not available yet."
    return 0
  fi
  if ! screen_config="$(load_screen_config "$target")"; then
    echo "[$target] Request exists and forecast is ready, but no screen session is configured."
    return 0
  fi
  screen_session="${screen_config%%$'\t'*}"
  screen_window="${screen_config#*$'\t'}"

  lock_dir="$dir/send.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "[$target] Send already running or lock exists: $lock_dir"
    return 0
  fi

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  sent_file="$dir/resume-sent-$run_id.md"
  sent_json="$dir/resume-sent-$run_id.json"
  log_file="$dir/resume-$run_id.log"
  {
    echo "Sending /goal resume at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Target: $target"
    echo "Usage available: true"
    echo "Request: $request_file"
    echo "Screen session: $screen_session"
    echo "Screen window: $screen_window"
    echo
    cat "$request_file"
    echo
    echo "----- screen output -----"
  } >"$log_file"

  set +e
  send_resume_sequence "$target" "$screen_session" "$screen_window" "$log_file"
  status="$?"
  set -e
  rmdir "$lock_dir" 2>/dev/null || true

  if [[ "$status" -eq 0 ]]; then
    mv "$request_file" "$sent_file"
    if [[ -f "$request_json" ]]; then
      mv "$request_json" "$sent_json"
    fi
    echo "[$target] Sent /goal resume to screen session '$screen_session' window '$screen_window'. Log: $log_file"
  else
    echo "[$target] Failed to send /goal resume to screen with status $status. Request remains: $request_file" >&2
    echo "[$target] Log: $log_file" >&2
    return "$status"
  fi
}

mark_registered_stop_seen_if_needed() {
  local target="$1" dir active_json now tmp
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  [[ -f "$active_json" && -f "$forecast_json" ]] || return 0
  if ! jq -e '(.stop_seen != true)' "$active_json" >/dev/null; then
    return 0
  fi
  if ! jq -e '
    ((.current.primary_window.remaining_percent // 1) <= 0)
      or ((.current.secondary_window.remaining_percent // 1) <= 0)
  ' "$forecast_json" >/dev/null; then
    return 0
  fi
  now="$(date -u +%s)"
  tmp="$active_json.tmp.$$"
  jq --argjson now "$now" --slurpfile forecast "$forecast_json" '
    ($forecast[0].current // {}) as $cur
    | .state = "waiting-for-usage"
    | .stop_seen = true
    | .stop_seen_at_epoch = $now
    | .stop_seen_at_utc = ($now | todateiso8601)
    | .stop_windows = ([
        (if (($cur.primary_window.remaining_percent // 1) <= 0) then "5h window" else empty end),
        (if (($cur.secondary_window.remaining_percent // 1) <= 0) then "weekly window" else empty end)
      ])
  ' "$active_json" >"$tmp"
  mv "$tmp" "$active_json"
  echo "[$target] Keepalive observed Codex usage at 0%; waiting for usage to become available."
}

send_registered_resume() {
  local target="$1"
  require_target "$target"
  need jq
  need screen
  local dir active_json active_md screen_config screen_session screen_window lock_dir run_id log_file status now tmp
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  active_md="$(active_keepalive_md "$target")"
  if [[ ! -f "$active_json" ]]; then
    return 0
  fi
  if ! screen_config="$(load_screen_config "$target")"; then
    echo "[$target] Keepalive is registered, but no screen session is configured."
    return 0
  fi
  screen_session="${screen_config%%$'\t'*}"
  screen_window="${screen_config#*$'\t'}"

  lock_dir="$dir/keepalive-send.lock"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    echo "[$target] Keepalive send already running or lock exists: $lock_dir"
    return 0
  fi

  run_id="$(date -u +%Y%m%dT%H%M%SZ)"
  log_file="$dir/keepalive-resume-$run_id.log"
  {
    echo "Sending persistent keepalive /goal resume at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Target: $target"
    echo "Usage available: true"
    echo "Screen session: $screen_session"
    echo "Screen window: $screen_window"
    echo
    if [[ -f "$active_md" ]]; then
      cat "$active_md"
    else
      jq -r '.objective // "Resume the active Codex goal."' "$active_json"
    fi
    echo
    echo "----- screen output -----"
  } >"$log_file"

  set +e
  send_resume_sequence "$target" "$screen_session" "$screen_window" "$log_file"
  status="$?"
  set -e
  rmdir "$lock_dir" 2>/dev/null || true

  if [[ "$status" -ne 0 ]]; then
    echo "[$target] Failed to send persistent keepalive resume with status $status. Log: $log_file" >&2
    return "$status"
  fi

  now="$(date -u +%s)"
  tmp="$active_json.tmp.$$"
  jq --argjson now "$now" --arg log_file "$log_file" '
    .state = "armed"
    | .stop_seen = false
    | .last_sent_at_epoch = $now
    | .last_sent_at_utc = ($now | todateiso8601)
    | .last_sent_after_stop_seen_at_utc = (.stop_seen_at_utc // null)
    | .last_sent_after_stop_windows = (.stop_windows // [])
    | .stop_seen_at_epoch = null
    | .stop_seen_at_utc = null
    | .stop_windows = []
    | .resume_count = ((.resume_count // 0) + 1)
    | .last_log_file = $log_file
  ' "$active_json" >"$tmp"
  mv "$tmp" "$active_json"
  echo "[$target] Sent persistent keepalive /goal resume to screen session '$screen_session' window '$screen_window'. Log: $log_file"
}

process_registered_keepalive() {
  local target="$1"
  require_target "$target"
  need jq
  local dir active_json ready stop_seen
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  if [[ ! -f "$active_json" ]]; then
    return 0
  fi
  if [[ ! -f "$forecast_json" ]]; then
    echo "[$target] Keepalive registered, but no forecast JSON yet: $forecast_json"
    return 0
  fi

  mark_registered_stop_seen_if_needed "$target"
  stop_seen="$(jq -r '.stop_seen // false' "$active_json")"
  if [[ "$stop_seen" != "true" ]]; then
    echo "[$target] Keepalive armed; no Codex usage 0% observation yet."
    return 0
  fi

  if [[ -f "$dir/resume-request.md" ]]; then
    echo "[$target] Keepalive is waiting, but a one-shot resume request exists; leaving that request in control."
    return 0
  fi

  ready="$(forecast_ready)"
  if [[ "$ready" != "true" ]]; then
    echo "[$target] Keepalive observed 0%; waiting until both 5h and weekly usage are available."
    return 0
  fi

  send_registered_resume "$target"
}

send_if_ready() {
  mkdir -p "$targets_dir"
  if [[ "${1:-}" != "" ]]; then
    local target="$1" active_json request_file had_work=0
    require_target "$target"
    active_json="$(active_keepalive_json "$target")"
    request_file="$(target_dir "$target")/resume-request.md"
    if [[ -f "$active_json" ]]; then
      had_work=1
    fi
    if [[ -f "$request_file" ]]; then
      had_work=1
    fi
    process_registered_keepalive "$1"
    if [[ -f "$request_file" ]]; then
      send_target_if_ready "$1"
    elif [[ "$had_work" -eq 0 ]]; then
      echo "[$target] No active keepalive or one-shot resume request."
    fi
    return
  fi
  local found=0 dir target
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    target="$(basename "$dir")"
    process_registered_keepalive "$target" || true
    if [[ -f "$dir/resume-request.md" ]]; then
      send_target_if_ready "$target" || true
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No targets configured under $targets_dir"
  fi
}

target_status() {
  local target="$1"
  local dir request_file screen_config
  require_target "$target"
  dir="$(target_dir "$target")"
  request_file="$dir/resume-request.md"
  echo "Target: $target"
  echo "Dir: $dir"
  if screen_config="$(load_screen_config "$target" 2>/dev/null)"; then
    echo "Configured screen: $screen_config"
  else
    echo "Configured screen: none"
  fi
  echo "5h threshold: $(load_threshold "$target")%"
  echo "Weekly threshold: $(load_weekly_threshold "$target")%"
  if [[ -f "$(active_keepalive_json "$target")" ]]; then
    echo "Keepalive registered: true"
    active_summary "$target"
  else
    echo "Keepalive registered: false"
  fi
  if [[ -f "$request_file" ]]; then
    echo "Request exists: true"
    request_summary "$target"
  else
    echo "Request exists: false"
  fi
}

current_target() {
  mkdir -p "$targets_dir"
  local screen_session="${1:-${STY:-}}"
  if [[ -z "$screen_session" ]]; then
    echo "No screen session supplied and STY is not set." >&2
    exit 1
  fi

  local dir target screen_config configured_session match="" matches=0
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    target="$(basename "$dir")"
    if ! screen_config="$(load_screen_config "$target" 2>/dev/null)"; then
      continue
    fi
    configured_session="${screen_config%%$'\t'*}"
    if [[ "$configured_session" == "$screen_session" ]]; then
      match="$target"
      matches=$((matches + 1))
    fi
  done

  if [[ "$matches" -eq 1 ]]; then
    printf '%s\n' "$match"
  elif [[ "$matches" -eq 0 ]]; then
    echo "No configured target matches screen session '$screen_session'." >&2
    exit 1
  else
    echo "Multiple configured targets match screen session '$screen_session'." >&2
    exit 1
  fi
}

status_resume() {
  echo "State: $state_dir"
  echo "Targets: $targets_dir"
  echo "Forecast JSON: $forecast_json"
  if [[ -f "$forecast_json" ]]; then
    echo "Usage available: $(forecast_ready)"
    jq -r '"Forecast updated: " + (.updated_at_utc // "unknown")' "$forecast_json"
  else
    echo "Usage available: false"
  fi
  echo
  if [[ "${1:-}" != "" ]]; then
    target_status "$1"
  else
    list_queue
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user --no-pager status "$timer_name" "$service_name" || true
  fi
}

queued_target_count() {
  mkdir -p "$targets_dir"
  local count=0 dir
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" && -f "$dir/resume-request.md" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

registered_target_count() {
  mkdir -p "$targets_dir"
  local count=0 dir
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" && -f "$dir/keepalive.json" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

format_seconds() {
  local seconds="${1:-}"
  if [[ "$seconds" == "null" || -z "$seconds" || ! "$seconds" =~ ^-?[0-9]+$ ]]; then
    echo "unknown"
    return
  fi
  local sign="" n d h m
  n="$seconds"
  if (( n < 0 )); then
    sign="-"
    n=$(( -n ))
  fi
  d=$(( n / 86400 ))
  h=$(( (n % 86400) / 3600 ))
  m=$(( (n % 3600) / 60 ))
  if (( d > 0 )); then
    printf '%s%dd %dh %dm\n' "$sign" "$d" "$h" "$m"
  elif (( h > 0 )); then
    printf '%s%dh %dm\n' "$sign" "$h" "$m"
  else
    printf '%s%dm\n' "$sign" "$m"
  fi
}

describe_gap() {
  local seconds="${1:-}"
  if [[ "$seconds" == "null" || -z "$seconds" || ! "$seconds" =~ ^-?[0-9]+$ ]]; then
    echo "unknown"
  elif (( seconds < 0 )); then
    echo "forecasted end is $(format_seconds $(( -seconds ))) before queued resume"
  elif (( seconds == 0 )); then
    echo "queued resume is at the forecasted end"
  else
    echo "forecasted end is $(format_seconds "$seconds") after queued resume"
  fi
}

forecast_overview() {
  if [[ ! -f "$forecast_json" ]]; then
    echo "Forecast: missing ($forecast_json)"
    return
  fi
  jq -r '
    def window($key; $label):
      (.current[$key] // {}) as $cur
      | (.predictions[$key] // {}) as $pred
      | ($pred.will_run_out_before_reset == true) as $runs_out
      | "- \($label): "
        + (if $cur.remaining_percent == null then "remaining unknown" else "\($cur.remaining_percent)% left" end)
        + "; reset " + ($cur.reset_at_utc // "unknown")
        + "; forecast end "
        + (if $runs_out and ($pred.eta_exhaustion_utc != null) then $pred.eta_exhaustion_utc
           elif $pred.will_run_out_before_reset == false then "survives to reset"
           else "unknown"
           end);
    "Forecast: updated " + (.updated_at_utc // "unknown"),
    window("primary_window"; "5h"),
    window("secondary_window"; "weekly")
  ' "$forecast_json"
}

request_summary() {
  local target="$1" dir request_json request_file objective created five_hour_threshold weekly_threshold require_stop_seen stop_seen stop_windows send_after reason reset_window reset_at forecast_window forecast_end gap gap_human
  dir="$(target_dir "$target")"
  request_json="$dir/resume-request.json"
  request_file="$dir/resume-request.md"
  if [[ -f "$request_json" ]]; then
    objective="$(jq -r '.objective // "unknown"' "$request_json")"
    created="$(jq -r '.created_at_utc // "unknown"' "$request_json")"
    five_hour_threshold="$(jq -r '.five_hour_threshold_percent // .threshold_percent // "unknown"' "$request_json")"
    weekly_threshold="$(jq -r '.weekly_threshold_percent // "unknown"' "$request_json")"
    require_stop_seen="$(jq -r '.require_stop_seen // false' "$request_json")"
    stop_seen="$(jq -r '.stop_seen // false' "$request_json")"
    stop_windows="$(jq -r '(.stop_windows // []) | if length == 0 then "none" else join(", ") end' "$request_json")"
    send_after="$(jq -r '.send_after_utc // "unknown"' "$request_json")"
    reason="$(jq -r '.limit_reason // "unknown"' "$request_json")"
    reset_window="$(jq -r '.reset_window // "none"' "$request_json")"
    reset_at="$(jq -r '.reset_at_utc // "not waiting for reset"' "$request_json")"
    forecast_window="$(jq -r '.forecast_end_window // "none"' "$request_json")"
    forecast_end="$(jq -r '.forecast_end_utc // "not forecast before reset"' "$request_json")"
    gap="$(jq -r '.resume_to_forecast_end_seconds // "null"' "$request_json")"
  else
    created="$(awk -F': ' '/^Created: / {print $2; exit}' "$request_file" 2>/dev/null || true)"
    objective="$(awk 'prev {print; exit} /^Objective:/ {prev=1}' "$request_file" 2>/dev/null || true)"
    five_hour_threshold="$(load_threshold "$target")"
    weekly_threshold="$(load_weekly_threshold "$target")"
    require_stop_seen="unknown"
    stop_seen="unknown"
    stop_windows="unknown"
    send_after="unknown"
    reason="legacy request without structured timing"
    reset_window="unknown"
    reset_at="unknown"
    forecast_window="unknown"
    forecast_end="unknown"
    gap="null"
  fi
  gap_human="$(describe_gap "$gap")"
  echo "  Objective: ${objective:-unknown}"
  echo "  Created: ${created:-unknown}"
  echo "  Thresholds: 5h ${five_hour_threshold}%, weekly ${weekly_threshold}%"
  echo "  Requires 0% observation: $require_stop_seen"
  echo "  0% observed: $stop_seen ($stop_windows)"
  echo "  Eligible after: $send_after"
  echo "  Reason: $reason"
  echo "  Reset watched: $reset_window at $reset_at"
  echo "  Forecast end: $forecast_window at $forecast_end"
  echo "  Resume-to-forecast-end: $gap_human"
}

active_summary() {
  local target="$1" dir active_json objective registered state stop_seen stop_windows resume_count last_sent forecast_window forecast_end
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  if [[ ! -f "$active_json" ]]; then
    return 0
  fi
  objective="$(jq -r '.objective // "unknown"' "$active_json")"
  registered="$(jq -r '.registered_at_utc // "unknown"' "$active_json")"
  state="$(jq -r '.state // "unknown"' "$active_json")"
  stop_seen="$(jq -r '.stop_seen // false' "$active_json")"
  stop_windows="$(jq -r '(.stop_windows // []) | if length == 0 then "none" else join(", ") end' "$active_json")"
  resume_count="$(jq -r '.resume_count // 0' "$active_json")"
  last_sent="$(jq -r '.last_sent_at_utc // "never"' "$active_json")"
  echo "  Objective: ${objective:-unknown}"
  echo "  Registered: ${registered:-unknown}"
  echo "  State: $state"
  echo "  0% observed: $stop_seen ($stop_windows)"
  echo "  Rule: send once after 0% is observed and both 5h and weekly usage are available"
  echo "  Resume count: $resume_count"
  echo "  Last sent: $last_sent"
  if [[ -f "$forecast_json" ]]; then
    forecast_window="$(jq -r '
      [(.predictions.primary_window // {}) + {label:"5h"}, (.predictions.secondary_window // {}) + {label:"weekly"}]
      | map(select(.will_run_out_before_reset == true and .eta_exhaustion_utc != null))
      | sort_by(.eta_exhaustion_epoch // 0)
      | .[0].label // "none"
    ' "$forecast_json")"
    forecast_end="$(jq -r '
      [(.predictions.primary_window // {}) + {label:"5h"}, (.predictions.secondary_window // {}) + {label:"weekly"}]
      | map(select(.will_run_out_before_reset == true and .eta_exhaustion_utc != null))
      | sort_by(.eta_exhaustion_epoch // 0)
      | .[0].eta_exhaustion_utc // "not forecast before reset"
    ' "$forecast_json")"
    echo "  Forecast end: $forecast_window at $forecast_end"
  fi
}

list_queue() {
  mkdir -p "$targets_dir"
  local queued registered dir target found_active=0 found_queue=0
  queued="$(queued_target_count)"
  registered="$(registered_target_count)"
  echo "Keepalive queue"
  forecast_overview
  echo
  if (( registered == 0 && queued == 0 )); then
    echo "Queued requests: none"
    return
  fi
  if (( registered > 0 )); then
    echo "Active keepalives: $registered"
    for dir in "$targets_dir"/*; do
      [[ -d "$dir" && -f "$dir/keepalive.json" ]] || continue
      found_active=1
      target="$(basename "$dir")"
      echo
      echo "- $target"
      active_summary "$target"
    done
  fi
  if (( queued == 0 )); then
    return
  fi
  if (( registered > 0 )); then
    echo
  fi
  echo "Queued requests: $queued"
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" && -f "$dir/resume-request.md" ]] || continue
    found_queue=1
    target="$(basename "$dir")"
    echo
    echo "- $target"
    request_summary "$target"
  done
  if [[ "$found_active" -eq 0 && "$found_queue" -eq 0 ]]; then
    echo "Queued requests: none"
  fi
}

list_targets() {
  mkdir -p "$targets_dir"
  local dir found=0 target
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    target="$(basename "$dir")"
    target_status "$target"
    echo
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No targets configured."
  fi
}

clear_target() {
  local target="${1:-}"
  require_target "$target"
  rm -f "$(target_dir "$target")/resume-request.md" "$(target_dir "$target")/resume-request.json"
  echo "Removed resume request for target '$target'."
}

remove_target() {
  local target="${1:-}"
  require_target "$target"
  rm -rf "$(target_dir "$target")"
  echo "Removed target '$target'."
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

cmd="${1:-status}"
shift || true
case "$cmd" in
  configure-screen)
    configure_screen "$@"
    ;;
  register)
    register_keepalive "$@"
    ;;
  unregister)
    unregister_keepalive "$@"
    ;;
  set-threshold)
    set_threshold "$@"
    ;;
  set-weekly-threshold)
    set_weekly_threshold "$@"
    ;;
  threshold)
    show_thresholds "$@"
    ;;
  queue)
    queue_resume "$@"
    ;;
  queue-if-needed)
    queue_if_needed "$@"
    ;;
  clear)
    clear_target "$@"
    ;;
  send-if-ready)
    send_if_ready "$@"
    ;;
  status)
    status_resume "$@"
    ;;
  current-target)
    current_target "$@"
    ;;
  list)
    list_queue
    ;;
  targets)
    list_targets
    ;;
  remove-target)
    remove_target "$@"
    ;;
  start)
    start_timer
    ;;
  stop)
    stop_timer
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
