#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: keepalive.sh <command> [args]

Recovers explicitly configured GNU Screen sessions after usage becomes
available or Codex shows the stable model-capacity warning.

Commands:
  configure-screen <target> <session> [window]
      Configure a named target's screen session and window.
  register <target> [--mode goal|continue|both] [objective]
      Keep a target recoverable until it is unregistered. Default mode is goal.
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
      Poll registered Screen targets and send eligible recovery requests.
      With no target, scan all targets.
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
  uninstall
      Disable the timer and remove its generated user systemd units.

Environment:
  CODEX_KEEPALIVE_STATE_DIR      Override state directory.
  CODEX_USAGE_FORECAST_JSON      Override forecast JSON path.
  CODEX_KEEPALIVE_FORECAST_MAX_AGE_SECONDS
                                  Maximum accepted forecast age. Default is 180.
  CODEX_KEEPALIVE_THRESHOLD_PERCENT
                                  Default 5h threshold when a target has no override.
  CODEX_KEEPALIVE_WEEKLY_THRESHOLD_PERCENT
                                  Default weekly threshold when a target has no override.
  CODEX_KEEPALIVE_SCREEN_TIMEOUT_SECONDS
                                  Timeout for each Screen command. Default is 10.
  CODEX_KEEPALIVE_SYSTEMD_USER_DIR
                                  Override generated unit directory (primarily for tests).
EOF
}

state_dir="${CODEX_KEEPALIVE_STATE_DIR:-$HOME/.codex/keepalive}"
forecast_json="${CODEX_USAGE_FORECAST_JSON:-$HOME/.codex/usage/codex-usage-forecast.json}"
capacity_snapshot_dir="${_CODEX_KEEPALIVE_SNAPSHOT_DIR:-$HOME/.codex/keepalive-snapshots}"
default_threshold_percent="${CODEX_KEEPALIVE_THRESHOLD_PERCENT:-25}"
default_weekly_threshold_percent="${CODEX_KEEPALIVE_WEEKLY_THRESHOLD_PERCENT:-7}"
forecast_max_age_seconds="${CODEX_KEEPALIVE_FORECAST_MAX_AGE_SECONDS:-180}"
screen_timeout_seconds="${CODEX_KEEPALIVE_SCREEN_TIMEOUT_SECONDS:-10}"
targets_dir="$state_dir/targets"
service_name="codex-keepalive.service"
timer_name="codex-keepalive.timer"
forecast_service_name="codex-usage-forecast.service"
systemd_user_dir="${CODEX_KEEPALIVE_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
capacity_warning='⚠ Selected model is at capacity. Please try a different model.'
script_path="$(
  cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
  pwd -P
)/$(basename -- "${BASH_SOURCE[0]}")"
if command -v readlink >/dev/null 2>&1; then
  resolved_script="$(readlink -f -- "$script_path" 2>/dev/null || true)"
  if [[ -n "$resolved_script" ]]; then
    script_path="$resolved_script"
  fi
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 127
  fi
}

target_ok() {
  [[ "$1" != "." && "$1" != ".." && "$1" =~ ^[A-Za-z0-9._-]+$ ]]
}

validate_forecast_max_age() {
  if [[ ! "$forecast_max_age_seconds" =~ ^[0-9]+$ ]] || (( forecast_max_age_seconds < 1 )); then
    echo "CODEX_KEEPALIVE_FORECAST_MAX_AGE_SECONDS must be a positive integer." >&2
    exit 2
  fi
}

validate_screen_timeout() {
  if [[ ! "$screen_timeout_seconds" =~ ^[0-9]+$ ]] || (( screen_timeout_seconds < 1 || screen_timeout_seconds > 60 )); then
    echo "CODEX_KEEPALIVE_SCREEN_TIMEOUT_SECONDS must be an integer from 1 to 60." >&2
    exit 2
  fi
}

run_screen() {
  need screen
  need timeout
  timeout --signal=TERM --kill-after=2s "${screen_timeout_seconds}s" screen "$@"
}

screen_value_ok() {
  [[ -n "$1" && "$1" != *[[:cntrl:]]* ]]
}

screen_session_matches() {
  local configured="$1" actual="$2"
  [[ "$configured" == "$actual" || "$actual" == *."$configured" || "$configured" == *."$actual" ]]
}

acquire_target_lock() {
  local target="$1" fd_var="$2" mode="${3:-wait}" dir fd
  need flock
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  exec {fd}>"$dir/target.lock"
  if [[ "$mode" == "nonblocking" ]]; then
    if ! flock -n "$fd"; then
      exec {fd}>&-
      return 1
    fi
  else
    flock "$fd"
  fi
  printf -v "$fd_var" '%s' "$fd"
}

release_target_lock() {
  local fd="$1"
  flock -u "$fd" || true
  exec {fd}>&-
}

acquire_mapping_lock() {
  local fd_var="$1" fd
  need flock
  mkdir -p "$state_dir"
  exec {fd}>"$state_dir/screen-mappings.lock"
  flock "$fd"
  printf -v "$fd_var" '%s' "$fd"
}

atomic_write() {
  local destination="$1" dir base tmp
  dir="$(dirname -- "$destination")"
  base="$(basename -- "$destination")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.${base}.tmp.XXXXXX")"
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  if ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp"
    return 1
  fi
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

validate_delivery_mode() {
  case "${1:-}" in
    goal|continue|both) ;;
    *)
      echo "Recovery mode must be one of: goal, continue, both." >&2
      return 2
      ;;
  esac
}

load_delivery_mode() {
  local target="$1" active_json mode="goal"
  active_json="$(active_keepalive_json "$target")"
  if [[ -f "$active_json" ]]; then
    if ! mode="$(jq -r '.delivery_mode // "goal"' "$active_json")"; then
      echo "[$target] Could not read the recovery mode." >&2
      return 1
    fi
  fi
  validate_delivery_mode "$mode" || return
  printf '%s\n' "$mode"
}

resume_reminder() {
  local target="$1"
  printf 'Keepalive reminder: you were resumed automatically for target "%s". If this goal is already finished, run "%s unregister %s" and mark the goal complete/finished again before responding. If the goal is not finished, continue normally; when it finishes, run that unregister command and mark the goal complete before the final response.' \
    "$target" "$script_path" "$target"
}

send_terminal_message() {
  local screen_session="$1" screen_window="$2" message="$3" label="$4" log_file="$5" state_var="$6"
  local status=0
  printf -v "$state_var" '%s' "uncertain"
  if run_screen -S "$screen_session" -p "$screen_window" -X stuff "$message" >>"$log_file" 2>&1; then
    :
  else
    status="$?"
    echo "The $label injection returned status $status; delivery is uncertain and will not be retried automatically." >>"$log_file"
    return "$status"
  fi
  sleep 0.1
  if run_screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1; then
    :
  else
    status="$?"
    echo "The $label submit keystroke returned status $status; delivery is uncertain and will not be retried automatically." >>"$log_file"
    return "$status"
  fi
  printf -v "$state_var" '%s' "submitted"
}

send_recovery_sequence() {
  local target="$1" screen_session="$2" screen_window="$3" log_file="$4" mode="$5" status=0 note
  validate_delivery_mode "$mode" || return
  note="$(resume_reminder "$target")"
  resume_delivery_state="not-attempted"
  goal_delivery_state="not-attempted"
  continue_delivery_state="not-attempted"
  reminder_delivery_state="not-attempted"

  if [[ "$mode" == "goal" || "$mode" == "both" ]]; then
    if run_screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1; then
      :
    else
      status="$?"
      echo "Recovery was not attempted because the initial terminal wake-up failed." >>"$log_file"
      return "$status"
    fi
    sleep 0.1
    if send_terminal_message "$screen_session" "$screen_window" "/goal resume" "/goal resume" "$log_file" goal_delivery_state; then
      :
    else
      status="$?"
      resume_delivery_state="$goal_delivery_state"
      return "$status"
    fi
  fi

  if [[ "$mode" == "continue" || "$mode" == "both" ]]; then
    if [[ "$mode" == "both" ]]; then
      sleep 0.5
    fi
    if send_terminal_message "$screen_session" "$screen_window" "Continue" "Continue" "$log_file" continue_delivery_state; then
      :
    else
      status="$?"
      resume_delivery_state="$continue_delivery_state"
      return "$status"
    fi
  fi
  resume_delivery_state="submitted"

  if [[ "$mode" == "goal" || "$mode" == "both" ]]; then
    sleep 0.5
    echo "----- keepalive reminder -----" >>"$log_file"
    echo "$note" >>"$log_file"
    if run_screen -S "$screen_session" -p "$screen_window" -X stuff "$note" >>"$log_file" 2>&1; then
      :
    else
      reminder_delivery_state="failed"
      echo "Reminder injection failed; recovery was already submitted and remains successful." >>"$log_file"
      return 0
    fi
    reminder_delivery_state="uncertain"
    sleep 0.1
    if run_screen -S "$screen_session" -p "$screen_window" -X stuff $'\015' >>"$log_file" 2>&1; then
      :
    else
      reminder_delivery_state="failed"
      echo "Reminder submit failed; recovery was already submitted and remains successful." >>"$log_file"
      return 0
    fi
    reminder_delivery_state="submitted"
  fi

  return 0
}

write_thresholds() {
  local target="$1" five_hour_threshold="$2" weekly_threshold="$3"
  validate_threshold "$five_hour_threshold"
  validate_threshold "$weekly_threshold"
  {
    printf 'FIVE_HOUR_THRESHOLD_PERCENT=%s\n' "$five_hour_threshold"
    printf 'WEEKLY_THRESHOLD_PERCENT=%s\n' "$weekly_threshold"
  } | atomic_write "$(settings_file "$target")"
}

set_threshold() {
  local target="${1:-}" threshold="${2:-}"
  require_target "$target"
  validate_threshold "$threshold"
  local dir weekly_threshold lock_fd
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  acquire_target_lock "$target" lock_fd
  weekly_threshold="$(load_weekly_threshold "$target")"
  write_thresholds "$target" "$threshold" "$weekly_threshold"
  release_target_lock "$lock_fd"
  echo "Set 5h keepalive threshold for target '$target' to ${threshold}%."
}

set_weekly_threshold() {
  local target="${1:-}" threshold="${2:-}"
  require_target "$target"
  validate_threshold "$threshold"
  local dir five_hour_threshold lock_fd
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  acquire_target_lock "$target" lock_fd
  five_hour_threshold="$(load_threshold "$target")"
  write_thresholds "$target" "$five_hour_threshold" "$threshold"
  release_target_lock "$lock_fd"
  echo "Set weekly keepalive threshold for target '$target' to ${threshold}%."
}

show_thresholds() {
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
    echo "Invalid target '$target'. Use letters, digits, dot, underscore, or hyphen; '.' and '..' are not allowed." >&2
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
  if ! screen_value_ok "$session" || ! screen_value_ok "$window"; then
    echo "Screen session and window must be non-empty and contain no control characters." >&2
    exit 2
  fi
  local dir lock_fd mapping_fd conflict status=0
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  acquire_mapping_lock mapping_fd
  acquire_target_lock "$target" lock_fd
  if conflict="$(find_screen_mapping_conflict "$target" "$session" "$window")"; then
    release_target_lock "$lock_fd"
    release_target_lock "$mapping_fd"
    echo "Screen session '$session' window '$window' is already configured for target '$conflict'." >&2
    return 1
  fi
  if {
    printf 'SCREEN_SESSION=%s\n' "$session"
    printf 'SCREEN_WINDOW=%s\n' "$window"
  } | atomic_write "$dir/screen.env"; then
    :
  else
    status="$?"
  fi
  release_target_lock "$lock_fd"
  release_target_lock "$mapping_fd"
  if [[ "$status" -ne 0 ]]; then
    echo "Could not configure target '$target'; the previous Screen mapping was preserved." >&2
    return "$status"
  fi
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
  if ! screen_value_ok "$session" || ! screen_value_ok "$window"; then
    echo "Invalid control character or empty value in $dir/screen.env" >&2
    return 1
  fi
  printf '%s\t%s\n' "$session" "$window"
}

find_screen_mapping_conflict() {
  local target="$1" session="$2" window="$3" dir other other_config other_session other_window
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    other="$(basename -- "$dir")"
    [[ "$other" != "$target" ]] || continue
    if ! other_config="$(load_screen_config "$other" 2>/dev/null)"; then
      continue
    fi
    other_session="${other_config%%$'\t'*}"
    other_window="${other_config#*$'\t'}"
    if [[ "$other_window" == "$window" ]] && screen_session_matches "$other_session" "$session"; then
      printf '%s\n' "$other"
      return 0
    fi
  done
  return 1
}

ensure_unique_screen_mapping() {
  local target="$1" session="$2" window="$3" conflict
  if conflict="$(find_screen_mapping_conflict "$target" "$session" "$window")"; then
    echo "[$target] Screen session '$session' window '$window' is also configured as target '$conflict'; recovery was not attempted." >&2
    return 1
  fi
}

queue_resume() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local objective="${*:-Resume the active Codex goal.}"
  local dir thresholds five_hour_threshold weekly_threshold require_stop_seen now metadata request_json request_md tmp_json tmp_md lock_fd
  local latched_stop latched_stop_windows
  latched_stop="$(bool_json "${_CODEX_KEEPALIVE_LATCHED_STOP:-false}")"
  latched_stop_windows="${_CODEX_KEEPALIVE_LATCHED_STOP_WINDOWS:-[]}"
  if ! jq -e 'type == "array" and all(.[]; type == "string")' <<<"$latched_stop_windows" >/dev/null; then
    echo "Internal keepalive stop-window metadata is invalid." >&2
    return 1
  fi
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  acquire_target_lock "$target" lock_fd
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  require_stop_seen="$(bool_json "${CODEX_KEEPALIVE_REQUIRE_STOP_SEEN:-false}")"
  now="$(date -u +%s)"
  metadata="$(queue_metadata_json "$five_hour_threshold" "$weekly_threshold" "$require_stop_seen" "$now" "$latched_stop" "$latched_stop_windows")"
  request_json="$dir/resume-request.json"
  request_md="$dir/resume-request.md"
  tmp_json="$(mktemp "$dir/.resume-request.json.tmp.XXXXXX")"
  tmp_md="$(mktemp "$dir/.resume-request.md.tmp.XXXXXX")"
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
    ' >"$tmp_json"
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
    ' "$tmp_json"
    echo
    echo "Objective:"
    echo "$objective"
    echo
    echo "Send when $forecast_json indicates usage is ready."
  } >"$tmp_md"
  chmod 600 "$tmp_json" "$tmp_md"
  mv -f "$tmp_json" "$request_json"
  mv -f "$tmp_md" "$request_md"
  release_target_lock "$lock_fd"
  echo "Wrote resume request for target '$target': $request_md"
}

queue_if_needed() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local objective="${*:-Resume the active Codex goal.}" thresholds five_hour_threshold weekly_threshold
  local observation decision primary_remaining weekly_remaining blocked observed_stop observed_stop_windows
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  if [[ ! -f "$forecast_json" ]]; then
    echo "No forecast JSON yet: $forecast_json" >&2
    return 1
  fi
  local forecast_health_text
  if ! forecast_health_text="$(forecast_health)"; then
    echo "Cannot queue from forecast: $forecast_health_text" >&2
    return 1
  fi
  if ! observation="$(jq -c --argjson five "$five_hour_threshold" --argjson weekly "$weekly_threshold" '
    ((.current.allowed == false) or (.current.limit_reached == true)) as $blocked
    | (.current.primary_window.remaining_percent // 101) as $primary
    | (.current.secondary_window.remaining_percent // 101) as $secondary
    | {
        decision: (
          if $blocked then "blocked"
          elif ($primary <= $five and $secondary <= $weekly) then "primary-low,weekly-low"
          elif $primary <= $five then "primary-low"
          elif $secondary <= $weekly then "weekly-low"
          else "no"
          end
        ),
        primary_remaining: $primary,
        weekly_remaining: $secondary,
        blocked: $blocked,
        observed_stop: ($blocked or ($primary <= 0) or ($secondary <= 0)),
        observed_stop_windows: [
          (if $primary <= 0 then "5h window" else empty end),
          (if $secondary <= 0 then "weekly window" else empty end),
          (if $blocked then "backend usage gate" else empty end)
        ]
      }
  ' "$forecast_json")"; then
    echo "Cannot queue from forecast: failed to read a stable usage observation." >&2
    return 1
  fi
  decision="$(jq -r '.decision' <<<"$observation")"
  primary_remaining="$(jq -r '.primary_remaining' <<<"$observation")"
  weekly_remaining="$(jq -r '.weekly_remaining' <<<"$observation")"
  blocked="$(jq -r '.blocked' <<<"$observation")"
  observed_stop="$(jq -r '.observed_stop' <<<"$observation")"
  observed_stop_windows="$(jq -c '.observed_stop_windows' <<<"$observation")"
  if [[ "$decision" == "no" ]]; then
    echo "No keepalive queue needed for target '$target': 5h remaining is ${primary_remaining}% (threshold ${five_hour_threshold}%), weekly remaining is ${weekly_remaining}% (threshold ${weekly_threshold}%), usage blocked is $blocked."
    return 0
  fi
  CODEX_KEEPALIVE_REQUIRE_STOP_SEEN=1 \
    _CODEX_KEEPALIVE_LATCHED_STOP="$observed_stop" \
    _CODEX_KEEPALIVE_LATCHED_STOP_WINDOWS="$observed_stop_windows" \
    queue_resume "$target" "$objective"
}

register_keepalive() {
  local target="${1:-}"
  require_target "$target"
  need jq
  shift || true
  local mode="goal"
  if [[ "${1:-}" == "--mode" ]]; then
    if [[ -z "${2:-}" ]]; then
      echo "Usage: keepalive.sh register <target> [--mode goal|continue|both] [objective]" >&2
      return 2
    fi
    mode="$2"
    shift 2
  elif [[ "${1:-}" == --mode=* ]]; then
    mode="${1#--mode=}"
    shift
  fi
  validate_delivery_mode "$mode" || return
  local objective="${*:-Recover the active Codex work.}"
  local dir thresholds five_hour_threshold weekly_threshold now active_json active_md screen_config tmp_json tmp_md lock_fd mapping_fd conflict
  dir="$(target_dir "$target")"
  mkdir -p "$dir"
  acquire_mapping_lock mapping_fd
  acquire_target_lock "$target" lock_fd
  if ! screen_config="$(load_screen_config "$target")"; then
    echo "Target '$target' has no configured screen session. Run configure-screen first." >&2
    release_target_lock "$lock_fd"
    release_target_lock "$mapping_fd"
    return 1
  fi
  if conflict="$(find_screen_mapping_conflict "$target" "${screen_config%%$'\t'*}" "${screen_config#*$'\t'}")"; then
    echo "Target '$target' duplicates the Screen mapping configured for target '$conflict'." >&2
    release_target_lock "$lock_fd"
    release_target_lock "$mapping_fd"
    return 1
  fi
  thresholds="$(load_thresholds "$target")"
  five_hour_threshold="${thresholds%%$'\t'*}"
  weekly_threshold="${thresholds#*$'\t'}"
  now="$(date -u +%s)"
  active_json="$(active_keepalive_json "$target")"
  active_md="$(active_keepalive_md "$target")"
  tmp_json="$(mktemp "$dir/.keepalive.json.tmp.XXXXXX")"
  tmp_md="$(mktemp "$dir/.keepalive.md.tmp.XXXXXX")"
  jq -n \
    --arg target "$target" \
    --arg objective "$objective" \
    --arg delivery_mode "$mode" \
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
        delivery_mode: $delivery_mode,
        screen_session: $screen_session,
        screen_window: $screen_window,
        five_hour_threshold_percent: $five_hour_threshold,
        weekly_threshold_percent: $weekly_threshold,
        state: "armed",
        stop_seen: false,
        stop_seen_at_epoch: null,
        stop_seen_at_utc: null,
        stop_windows: [],
        capacity_state: "armed",
        capacity_candidate_hash: null,
        capacity_candidate_seen_at_epoch: null,
        capacity_candidate_seen_at_utc: null,
        capacity_warning_latched: false,
        capacity_stop_seen: false,
        capacity_stop_seen_at_epoch: null,
        capacity_stop_seen_at_utc: null,
        resume_count: 0,
        continue_count: 0,
        recovery_count: 0,
        last_sent_at_epoch: null,
        last_sent_at_utc: null,
        last_log_file: null,
        rule: "recover after usage becomes available or a stable exact model-capacity warning is observed"
      }
    ' >"$tmp_json"
  {
    echo "# Codex Keepalive Registration"
    echo
    echo "Target: $target"
    echo "Registered: $(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
    echo "Cwd: $(pwd)"
    echo "Screen: ${screen_config%%$'\t'*} window ${screen_config#*$'\t'}"
    echo "Recovery mode: $mode"
    echo "5h threshold: ${five_hour_threshold}%"
    echo "Weekly threshold: ${weekly_threshold}%"
    echo "Rule: recover after usage becomes available or a stable exact model-capacity warning is observed."
    echo
    echo "Objective:"
    echo "$objective"
  } >"$tmp_md"
  chmod 600 "$tmp_json" "$tmp_md"
  mv -f "$tmp_json" "$active_json"
  mv -f "$tmp_md" "$active_md"
  release_target_lock "$lock_fd"
  release_target_lock "$mapping_fd"
  echo "Registered keepalive for target '$target': $active_md"
}

unregister_keepalive() {
  local target="${1:-}"
  require_target "$target"
  local lock_fd mapping_fd cleanup_status=0
  acquire_mapping_lock mapping_fd
  acquire_target_lock "$target" lock_fd
  rm -f "$(active_keepalive_json "$target")" "$(active_keepalive_md "$target")" \
    "$(target_dir "$target")/resume-request.md" "$(target_dir "$target")/resume-request.json"
  if cleanup_capacity_snapshots "$target"; then
    :
  else
    cleanup_status="$?"
  fi
  release_target_lock "$lock_fd"
  release_target_lock "$mapping_fd"
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "Unregistered keepalive for target '$target', but could not remove its private Screen snapshot artifacts." >&2
    return "$cleanup_status"
  fi
  echo "Unregistered keepalive for target '$target' and cleared queued resume state."
}

queue_metadata_json() {
  local five_hour_threshold="$1" weekly_threshold="$2" require_stop_seen="$3" now="$4"
  local latched_stop="${5:-false}" latched_stop_windows="${6:-[]}"
  if [[ ! -f "$forecast_json" ]] || ! forecast_health >/dev/null; then
    jq -n --argjson now "$now" \
      --argjson five "$five_hour_threshold" \
      --argjson weekly "$weekly_threshold" \
      --argjson require_stop_seen "$require_stop_seen" \
      --argjson latched_stop "$latched_stop" \
      --argjson latched_stop_windows "$latched_stop_windows" '{
      five_hour_threshold_percent: $five,
      weekly_threshold_percent: $weekly,
      require_stop_seen: $require_stop_seen,
      stop_seen: ($require_stop_seen and $latched_stop),
      stop_seen_at_epoch: (if ($require_stop_seen and $latched_stop) then $now else null end),
      stop_seen_at_utc: (if ($require_stop_seen and $latched_stop) then ($now | todateiso8601) else null end),
      stop_windows: (if ($require_stop_seen and $latched_stop) then $latched_stop_windows else [] end),
      send_after_epoch: $now,
      send_after_utc: ($now | todateiso8601),
      limit_reason: (
        if ($require_stop_seen and $latched_stop) then
          "usage stop observed before queue state was written; queued to send as soon as usage is available again"
        else
          "forecast missing, stale, or invalid when queued"
        end
      ),
      resume_condition: (if $require_stop_seen then "send after exhausted or backend-blocked usage is observed and usage is available again" else "send when usage is available" end),
      reset_window: null,
      reset_at_utc: null,
      forecast_end_window: null,
      forecast_end_utc: null,
      resume_to_forecast_end_seconds: null
    }'
    return
  fi

  jq -c --argjson five "$five_hour_threshold" --argjson weekly "$weekly_threshold" --argjson require_stop_seen "$require_stop_seen" --argjson now "$now" \
    --argjson latched_stop "$latched_stop" --argjson latched_stop_windows "$latched_stop_windows" '
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
    | ($stopped or $blocked or $latched_stop) as $observed_stop
    | ($breaches
        | map(select(.reset_at != null))
        | sort_by(.reset_at)
        | .[0]) as $breached_reset
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
       elif (($breaches | length) > 0) then ($breached_reset.reset_at // $now)
       else $now
       end) as $send_after
    | (if $stopped then $stopped_reset
       elif (($breaches | length) > 0) then $breached_reset
       else $next_reset
       end) as $reset_window
    | {
        five_hour_threshold_percent: $five,
        weekly_threshold_percent: $weekly,
        require_stop_seen: $require_stop_seen,
        stop_seen: ($require_stop_seen and $observed_stop),
        stop_seen_at_epoch: (if ($require_stop_seen and $observed_stop) then $now else null end),
        stop_seen_at_utc: (if ($require_stop_seen and $observed_stop) then ($now | todateiso8601) else null end),
        stop_windows: (
          ($stopped_windows | map(.label))
          + (if $blocked then ["backend usage gate"] else [] end)
          + (if $latched_stop then $latched_stop_windows else [] end)
          | unique
        ),
        send_after_epoch: $send_after,
        send_after_utc: ($send_after | todateiso8601),
        availability_gate: "send when backend reports allowed=true and limit_reached=false and both usage windows have remaining capacity above 0%",
        resume_condition: (if $require_stop_seen then "send after exhausted or backend-blocked usage is observed and usage is available again" else "send when usage is available" end),
        limit_reason: (
          if $stopped then
            "usage window at 0%; queued to send as soon as usage is available again"
          elif $blocked then
            "backend reports usage blocked; queued to send as soon as usage is available again"
          elif $latched_stop then
            "usage stop observed before queue state was written; queued to send as soon as usage is available again"
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

forecast_health() {
  need jq
  if [[ ! -f "$forecast_json" ]]; then
    echo "missing forecast ($forecast_json)"
    return 1
  fi
  if ! jq -e '
    (.updated_at_epoch | type == "number")
      and (.updated_at_epoch == (.updated_at_epoch | floor))
      and (.current | type == "object")
      and (.current.allowed | type == "boolean")
      and (.current.limit_reached | type == "boolean")
      and (.current.primary_window.remaining_percent | type == "number")
      and (.current.secondary_window.remaining_percent | type == "number")
      and (.current.primary_window.remaining_percent >= 0)
      and (.current.primary_window.remaining_percent <= 100)
      and (.current.secondary_window.remaining_percent >= 0)
      and (.current.secondary_window.remaining_percent <= 100)
  ' "$forecast_json" >/dev/null 2>&1; then
    echo "invalid forecast schema ($forecast_json)"
    return 1
  fi
  local updated_at now age
  updated_at="$(jq -r '.updated_at_epoch' "$forecast_json")"
  if [[ ! "$updated_at" =~ ^[0-9]{1,12}$ ]]; then
    echo "invalid forecast timestamp ($forecast_json)"
    return 1
  fi
  now="$(date -u +%s)"
  age=$(( now - updated_at ))
  if (( age < 0 )); then
    echo "forecast timestamp is in the future by $(( -age ))s"
    return 1
  fi
  if (( age > forecast_max_age_seconds )); then
    echo "stale forecast (${age}s old; maximum ${forecast_max_age_seconds}s)"
    return 1
  fi
  echo "fresh forecast (${age}s old)"
}

forecast_ready() {
  need jq
  if ! forecast_health >/dev/null; then
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

prepare_capacity_snapshot_dir() {
  need find
  if ! mkdir -p "$capacity_snapshot_dir" || ! chmod 700 "$capacity_snapshot_dir"; then
    echo "Could not prepare the private Screen snapshot directory: $capacity_snapshot_dir" >&2
    return 1
  fi
}

cleanup_capacity_snapshots() {
  local target="$1"
  [[ -d "$capacity_snapshot_dir" ]] || return 0
  need find
  find "$capacity_snapshot_dir" -maxdepth 1 -type f \
    -name "$target.screen-viewport.tmp.*" -delete
}

cleanup_all_capacity_snapshots() {
  [[ -d "$capacity_snapshot_dir" ]] || return 0
  need find
  find "$capacity_snapshot_dir" -maxdepth 1 -type f \
    -name '*.screen-viewport.tmp.*' -delete
  rmdir "$capacity_snapshot_dir" 2>/dev/null || true
}

capture_capacity_observation() (
  local target="$1" screen_session="$2" screen_window="$3"
  local snapshot="" viewport_hash warning_present="false" status=0
  cleanup_snapshot_on_exit() {
    if [[ -n "$snapshot" ]]; then
      rm -f "$snapshot" || true
    fi
  }
  trap cleanup_snapshot_on_exit EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  need screen
  need sha256sum
  if ! prepare_capacity_snapshot_dir; then
    return 1
  fi
  if ! cleanup_capacity_snapshots "$target"; then
    echo "[$target] Could not clean a stale private Screen viewport snapshot." >&2
    return 1
  fi
  if ! snapshot="$(mktemp "$capacity_snapshot_dir/$target.screen-viewport.tmp.XXXXXX")"; then
    echo "[$target] Could not create a private Screen viewport snapshot." >&2
    return 1
  fi
  if ! chmod 600 "$snapshot"; then
    echo "[$target] Could not secure the private Screen viewport snapshot." >&2
    return 1
  fi
  if run_screen -S "$screen_session" -p "$screen_window" -X hardcopy "$snapshot" >/dev/null 2>&1; then
    :
  else
    status="$?"
    echo "[$target] Could not capture Screen session '$screen_session' window '$screen_window'; model-capacity observation failed." >&2
    return "$status"
  fi
  if ! viewport_hash="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$snapshot" | sha256sum | awk '{print $1}')"; then
    echo "[$target] Could not fingerprint the Screen viewport; model-capacity observation failed." >&2
    return 1
  fi
  if sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$snapshot" \
      | awk 'NF { line[++count] = $0 } END { start = count - 7; if (start < 1) start = 1; for (i = start; i <= count; i++) print line[i] }' \
      | grep -Fxq -- "$capacity_warning"; then
    warning_present="true"
  fi
  if ! rm -f "$snapshot"; then
    echo "[$target] Could not remove the private Screen viewport snapshot." >&2
    return 1
  fi
  snapshot=""
  printf '%s\t%s\n' "$warning_present" "$viewport_hash"
)

observe_capacity_warning() {
  local target="$1" dir active_json screen_config screen_session screen_window observation
  local warning_present viewport_hash current candidate_hash latched stop_seen now tmp status
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  [[ -f "$active_json" ]] || return 0
  if ! screen_config="$(load_screen_config "$target")"; then
    echo "[$target] Keepalive is registered, but no screen session is configured." >&2
    return 1
  fi
  screen_session="${screen_config%%$'\t'*}"
  screen_window="${screen_config#*$'\t'}"
  ensure_unique_screen_mapping "$target" "$screen_session" "$screen_window" || return
  if observation="$(capture_capacity_observation "$target" "$screen_session" "$screen_window")"; then
    :
  else
    status="$?"
    echo "[$target] Model-capacity monitoring is degraded for this pass (capture status $status)." >&2
    return 70
  fi
  warning_present="${observation%%$'\t'*}"
  viewport_hash="${observation#*$'\t'}"
  if ! current="$(jq -r '[.capacity_candidate_hash // "", .capacity_warning_latched // false, .capacity_stop_seen // false] | @tsv' "$active_json")"; then
    echo "[$target] Could not read model-capacity observation state." >&2
    return 1
  fi
  candidate_hash="${current%%$'\t'*}"
  current="${current#*$'\t'}"
  latched="${current%%$'\t'*}"
  stop_seen="${current#*$'\t'}"
  now="$(date -u +%s)"
  if ! tmp="$(mktemp "$dir/.keepalive.json.tmp.XXXXXX")"; then
    echo "[$target] Could not create a temporary model-capacity state file." >&2
    return 1
  fi

  if [[ "$warning_present" != "true" ]]; then
    if [[ "$stop_seen" == "true" ]]; then
      rm -f "$tmp"
      echo "[$target] Confirmed model-capacity recovery remains pending after a clean Screen viewport."
      return 0
    fi
    if ! jq '
      .capacity_state = "armed"
      | .capacity_candidate_hash = null
      | .capacity_candidate_seen_at_epoch = null
      | .capacity_candidate_seen_at_utc = null
      | .capacity_warning_latched = false
      | .capacity_stop_seen = false
      | .capacity_stop_seen_at_epoch = null
      | .capacity_stop_seen_at_utc = null
    ' "$active_json" >"$tmp"; then
      rm -f "$tmp"
      echo "[$target] Could not prepare model-capacity rearm state; Screen was not touched." >&2
      return 1
    fi
    if ! mv -f "$tmp" "$active_json"; then
      rm -f "$tmp"
      echo "[$target] Could not commit model-capacity rearm state; Screen was not touched." >&2
      return 1
    fi
    if [[ "$latched" == "true" ]]; then
      echo "[$target] Model-capacity recovery re-armed after a clean Screen viewport."
    fi
    return 0
  fi

  if [[ "$latched" == "true" ]]; then
    rm -f "$tmp"
    echo "[$target] Model-capacity warning remains latched; no duplicate recovery will be sent."
    return 0
  fi
  if [[ -n "$candidate_hash" && "$candidate_hash" == "$viewport_hash" ]]; then
    if ! jq --argjson now "$now" '
      .capacity_state = "ready"
      | .capacity_candidate_hash = null
      | .capacity_candidate_seen_at_epoch = null
      | .capacity_candidate_seen_at_utc = null
      | .capacity_warning_latched = true
      | .capacity_stop_seen = true
      | .capacity_stop_seen_at_epoch = $now
      | .capacity_stop_seen_at_utc = ($now | todateiso8601)
    ' "$active_json" >"$tmp"; then
      rm -f "$tmp"
      echo "[$target] Could not prepare the stable model-capacity stop state; Screen was not touched." >&2
      return 1
    fi
    if ! mv -f "$tmp" "$active_json"; then
      rm -f "$tmp"
      echo "[$target] Could not commit the stable model-capacity stop state; Screen was not touched." >&2
      return 1
    fi
    echo "[$target] Confirmed a stable model-capacity stop."
    return 0
  fi

  if ! jq --arg hash "$viewport_hash" --argjson now "$now" '
    .capacity_state = "observing"
    | .capacity_candidate_hash = $hash
    | .capacity_candidate_seen_at_epoch = $now
    | .capacity_candidate_seen_at_utc = ($now | todateiso8601)
    | .capacity_stop_seen = false
    | .capacity_stop_seen_at_epoch = null
    | .capacity_stop_seen_at_utc = null
  ' "$active_json" >"$tmp"; then
    rm -f "$tmp"
    echo "[$target] Could not prepare the model-capacity candidate state; Screen was not touched." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$active_json"; then
    rm -f "$tmp"
    echo "[$target] Could not commit the model-capacity candidate state; Screen was not touched." >&2
    return 1
  fi
  echo "[$target] Model-capacity warning observed once; waiting for a stable second viewport."
}

mark_stop_seen_if_needed() {
  local target="$1" dir request_json now tmp
  dir="$(target_dir "$target")"
  request_json="$dir/resume-request.json"
  [[ -f "$request_json" && -f "$forecast_json" ]] || return 0
  forecast_health >/dev/null || return 0
  if ! jq -e '(.require_stop_seen == true) and (.stop_seen != true)' "$request_json" >/dev/null; then
    return 0
  fi
  if ! jq -e '
    (.current.allowed == false)
      or (.current.limit_reached == true)
      or ((.current.primary_window.remaining_percent // 1) <= 0)
      or ((.current.secondary_window.remaining_percent // 1) <= 0)
  ' "$forecast_json" >/dev/null; then
    return 0
  fi
  now="$(date -u +%s)"
  if ! tmp="$(mktemp "$dir/.resume-request.json.tmp.XXXXXX")"; then
    echo "[$target] Could not create a temporary one-shot state file." >&2
    return 1
  fi
  if ! jq --argjson now "$now" --slurpfile forecast "$forecast_json" '
    ($forecast[0].current // {}) as $cur
    | .stop_seen = true
    | .stop_seen_at_epoch = $now
    | .stop_seen_at_utc = ($now | todateiso8601)
    | .stop_windows = ([
        (if (($cur.primary_window.remaining_percent // 1) <= 0) then "5h window" else empty end),
        (if (($cur.secondary_window.remaining_percent // 1) <= 0) then "weekly window" else empty end),
        (if (($cur.allowed == false) or ($cur.limit_reached == true)) then "backend usage gate" else empty end)
      ])
    | .limit_reason = "usage exhaustion or backend block observed; queued to send as soon as usage is available again"
  ' "$request_json" >"$tmp"; then
    rm -f "$tmp"
    echo "[$target] Could not record the observed usage stop in one-shot state." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$request_json"; then
    rm -f "$tmp"
    echo "[$target] Could not commit the observed usage stop to one-shot state." >&2
    return 1
  fi
  echo "[$target] Observed exhausted or backend-blocked usage; request will send when usage is available again."
}

one_shot_request_ready_now() {
  local target="$1" now="$2" request_file request_json schedule require_stop_seen stop_seen send_after
  request_file="$(target_dir "$target")/resume-request.md"
  request_json="$(target_dir "$target")/resume-request.json"
  [[ -f "$request_file" ]] || return 1
  [[ -f "$request_json" ]] || return 0
  if ! schedule="$(jq -er '
    (.require_stop_seen // false) as $require
    | (.stop_seen // false) as $seen
    | (.send_after_epoch // 0) as $after
    | if (($require | type) != "boolean")
        or (($seen | type) != "boolean")
        or (($after | type) != "number")
        or ($after != ($after | floor))
        or ($after < 0)
      then error("invalid one-shot schedule state")
      else [$require, $seen, $after] | @tsv
      end
  ' "$request_json")"; then
    echo "[$target] Could not read one-shot schedule state; Screen was not touched." >&2
    return 2
  fi
  require_stop_seen="${schedule%%$'\t'*}"
  schedule="${schedule#*$'\t'}"
  stop_seen="${schedule%%$'\t'*}"
  send_after="${schedule#*$'\t'}"
  if [[ "$require_stop_seen" == "true" ]]; then
    [[ "$stop_seen" == "true" ]]
  else
    (( now >= send_after ))
  fi
}

begin_registered_delivery() {
  local target="$1" now="$2" delivery_id="$3" log_file="$4" trigger="$5"
  local clear_usage="${6:-false}" clear_capacity="${7:-false}"
  local mode="${8:-goal}"
  local active_json dir tmp trigger_state stop_seen capacity_stop_seen candidate_hash consume_candidate="false"
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  [[ -f "$active_json" ]] || return 0
  if ! trigger_state="$(jq -r '[.stop_seen // false, .capacity_stop_seen // false, .capacity_candidate_hash // ""] | @tsv' "$active_json")"; then
    echo "[$target] Could not read persistent keepalive state before delivery." >&2
    return 1
  fi
  stop_seen="${trigger_state%%$'\t'*}"
  trigger_state="${trigger_state#*$'\t'}"
  capacity_stop_seen="${trigger_state%%$'\t'*}"
  candidate_hash="${trigger_state#*$'\t'}"
  if [[ "$clear_usage" != "true" || "$stop_seen" != "true" ]]; then
    clear_usage="false"
  fi
  if [[ "$clear_capacity" != "true" || "$capacity_stop_seen" != "true" ]]; then
    clear_capacity="false"
  fi
  if [[ -n "$candidate_hash" ]]; then
    consume_candidate="true"
  fi
  if [[ "$clear_usage" != "true" && "$clear_capacity" != "true" && "$consume_candidate" != "true" ]]; then
    return 0
  fi
  if ! tmp="$(mktemp "$dir/.keepalive.json.tmp.XXXXXX")"; then
    echo "[$target] Could not create a temporary persistent delivery state file." >&2
    return 1
  fi
  if ! jq \
    --argjson now "$now" \
    --arg delivery_id "$delivery_id" \
    --arg log_file "$log_file" \
    --arg trigger "$trigger" \
    --arg mode "$mode" \
    --argjson clear_usage "$clear_usage" \
    --argjson clear_capacity "$clear_capacity" \
    --argjson consume_candidate "$consume_candidate" '
      (if $clear_usage then
        .state = "armed"
        | .last_sent_after_stop_seen_at_utc = (.stop_seen_at_utc // null)
        | .last_sent_after_stop_windows = (.stop_windows // [])
        | .stop_seen = false
        | .stop_seen_at_epoch = null
        | .stop_seen_at_utc = null
        | .stop_windows = []
      else . end)
      | (if $clear_capacity then
        .capacity_state = "latched"
        | .last_sent_after_capacity_stop_at_utc = (.capacity_stop_seen_at_utc // null)
        | .capacity_stop_seen = false
        | .capacity_stop_seen_at_epoch = null
        | .capacity_stop_seen_at_utc = null
      else . end)
      | (if $consume_candidate then
        .capacity_state = "latched"
        | .capacity_warning_latched = true
        | .last_consumed_capacity_candidate_seen_at_utc = (.capacity_candidate_seen_at_utc // null)
        | .capacity_candidate_hash = null
        | .capacity_candidate_seen_at_epoch = null
        | .capacity_candidate_seen_at_utc = null
      else . end)
      | .last_delivery_id = $delivery_id
      | .last_delivery_trigger = $trigger
      | .last_delivery_mode = $mode
      | .last_delivery_state = "attempting"
      | .last_goal_delivery_state = "not-attempted"
      | .last_continue_delivery_state = "not-attempted"
      | .last_delivery_attempt_at_epoch = $now
      | .last_delivery_attempt_at_utc = ($now | todateiso8601)
      | .last_reminder_delivery_state = "not-attempted"
      | .recovery_attempt_count = ((.recovery_attempt_count // 0) + 1)
      | if ($mode == "goal" or $mode == "both") then
          .resume_attempt_count = ((.resume_attempt_count // 0) + 1)
        else . end
      | if ($mode == "continue" or $mode == "both") then
          .continue_attempt_count = ((.continue_attempt_count // 0) + 1)
        else . end
      | .last_log_file = $log_file
    ' "$active_json" >"$tmp"; then
    rm -f "$tmp"
    echo "[$target] Could not prepare persistent delivery state." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$active_json"; then
    rm -f "$tmp"
    echo "[$target] Could not commit persistent delivery state; Screen was not touched." >&2
    return 1
  fi
}

finish_registered_delivery() {
  local target="$1" delivery_id="$2" delivery_state="$3" reminder_state="$4" now="$5"
  local mode="${6:-goal}" goal_state="${7:-not-attempted}" continue_state="${8:-not-attempted}"
  local active_json current_delivery_id dir tmp
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  [[ -f "$active_json" ]] || return 0
  if ! current_delivery_id="$(jq -r '.last_delivery_id // empty' "$active_json")"; then
    echo "[$target] Could not read persistent delivery state after the Screen attempt." >&2
    return 1
  fi
  if [[ "$current_delivery_id" != "$delivery_id" ]]; then
    return 0
  fi
  if ! tmp="$(mktemp "$dir/.keepalive.json.tmp.XXXXXX")"; then
    echo "[$target] Could not create a temporary persistent completion state file." >&2
    return 1
  fi
  if ! jq \
    --argjson now "$now" \
    --arg delivery_id "$delivery_id" \
    --arg delivery_state "$delivery_state" \
    --arg reminder_state "$reminder_state" \
    --arg mode "$mode" \
    --arg goal_state "$goal_state" \
    --arg continue_state "$continue_state" '
      if .last_delivery_id != $delivery_id then .
      else
        .last_delivery_state = $delivery_state
        | .last_reminder_delivery_state = $reminder_state
        | .last_goal_delivery_state = $goal_state
        | .last_continue_delivery_state = $continue_state
        | .last_delivery_mode = $mode
        | .last_delivery_completed_at_epoch = $now
        | .last_delivery_completed_at_utc = ($now | todateiso8601)
        | if $goal_state == "submitted" then
            .resume_count = ((.resume_count // 0) + 1)
          else . end
        | if $continue_state == "submitted" then
            .continue_count = ((.continue_count // 0) + 1)
          else . end
        | if $delivery_state == "submitted" then
            .last_sent_at_epoch = $now
            | .last_sent_at_utc = ($now | todateiso8601)
            | .recovery_count = ((.recovery_count // 0) + 1)
          else .
          end
      end
    ' "$active_json" >"$tmp"; then
    rm -f "$tmp"
    echo "[$target] Could not prepare persistent completion state." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$active_json"; then
    rm -f "$tmp"
    echo "[$target] Could not commit persistent completion state." >&2
    return 1
  fi
}

finish_one_shot_delivery() {
  local sent_json="$1" delivery_id="$2" delivery_state="$3" reminder_state="$4" now="$5"
  local mode="${6:-goal}" goal_state="${7:-not-attempted}" continue_state="${8:-not-attempted}"
  local dir tmp
  [[ -f "$sent_json" ]] || return 0
  dir="$(dirname -- "$sent_json")"
  if ! tmp="$(mktemp "$dir/.resume-sent.json.tmp.XXXXXX")"; then
    echo "Could not create a temporary one-shot completion state file beside $sent_json." >&2
    return 1
  fi
  if ! jq \
    --argjson now "$now" \
    --arg delivery_id "$delivery_id" \
    --arg delivery_state "$delivery_state" \
    --arg reminder_state "$reminder_state" \
    --arg mode "$mode" \
    --arg goal_state "$goal_state" \
    --arg continue_state "$continue_state" '
      .delivery_id = $delivery_id
      | .delivery_state = $delivery_state
      | .reminder_delivery_state = $reminder_state
      | .goal_delivery_state = $goal_state
      | .continue_delivery_state = $continue_state
      | .delivery_mode = $mode
      | .delivery_completed_at_epoch = $now
      | .delivery_completed_at_utc = ($now | todateiso8601)
      | .automatic_retry = false
    ' "$sent_json" >"$tmp"; then
    rm -f "$tmp"
    echo "Could not prepare one-shot completion state in $sent_json." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$sent_json"; then
    rm -f "$tmp"
    echo "Could not commit one-shot completion state to $sent_json." >&2
    return 1
  fi
}

begin_one_shot_delivery() {
  local sent_json="$1" delivery_id="$2" now="$3"
  local dir tmp
  [[ -f "$sent_json" ]] || return 0
  dir="$(dirname -- "$sent_json")"
  if ! tmp="$(mktemp "$dir/.resume-sent.json.tmp.XXXXXX")"; then
    echo "Could not create a temporary one-shot delivery state file beside $sent_json." >&2
    return 1
  fi
  if ! jq \
    --argjson now "$now" \
    --arg delivery_id "$delivery_id" '
      .delivery_id = $delivery_id
      | .delivery_state = "attempting"
      | .reminder_delivery_state = "not-attempted"
      | .delivery_attempt_at_epoch = $now
      | .delivery_attempt_at_utc = ($now | todateiso8601)
      | .automatic_retry = false
    ' "$sent_json" >"$tmp"; then
    rm -f "$tmp"
    echo "Could not prepare one-shot delivery state in $sent_json." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$sent_json"; then
    rm -f "$tmp"
    echo "Could not commit one-shot delivery state to $sent_json." >&2
    return 1
  fi
}

send_target_if_ready() {
  local target="$1"
  require_target "$target"
  need jq
  need screen
  need timeout
  local dir request_file request_json screen_config screen_session screen_window ready run_id sent_file sent_json log_file status now completed_at send_after send_after_utc require_stop_seen stop_seen forecast_health_text mode
  local finish_status=0 result retired_json=0
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
  if mark_stop_seen_if_needed "$target"; then
    :
  else
    result="$?"
    echo "[$target] One-shot state could not be updated; Screen was not touched." >&2
    return "$result"
  fi
  if [[ -f "$request_json" ]]; then
    if ! require_stop_seen="$(jq -r '.require_stop_seen // false' "$request_json")" \
        || ! stop_seen="$(jq -r '.stop_seen // false' "$request_json")"; then
      echo "[$target] Could not read one-shot state; Screen was not touched." >&2
      return 1
    fi
    if [[ "$require_stop_seen" == "true" && "$stop_seen" != "true" ]]; then
      echo "[$target] Request queued; waiting to observe exhausted or backend-blocked Codex usage before automatic resume."
      return 0
    fi
    if ! send_after="$(jq -r '.send_after_epoch // 0' "$request_json")" \
        || ! send_after_utc="$(jq -r '.send_after_utc // "unknown"' "$request_json")"; then
      echo "[$target] Could not read one-shot schedule state; Screen was not touched." >&2
      return 1
    fi
    if [[ "$require_stop_seen" != "true" && "$send_after" =~ ^[0-9]+$ ]] && (( now < send_after )); then
      echo "[$target] Request queued; waiting until $send_after_utc before sending."
      return 0
    fi
  fi
  if ! forecast_health_text="$(forecast_health)"; then
    echo "[$target] Request exists, but the forecast is not usable: $forecast_health_text"
    return 0
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
  ensure_unique_screen_mapping "$target" "$screen_session" "$screen_window" || return
  if ! mode="$(load_delivery_mode "$target")"; then
    return 1
  fi

  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
  sent_file="$dir/resume-sent-$run_id.md"
  sent_json="$dir/resume-sent-$run_id.json"
  log_file="$dir/resume-$run_id.log"
  if ! {
    echo "Sending one-shot recovery at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Target: $target"
    echo "Recovery mode: $mode"
    echo "Usage available: true"
    echo "Request: $request_file"
    echo "Screen session: $screen_session"
    echo "Screen window: $screen_window"
    echo
    cat "$request_file"
    echo
    echo "----- screen output -----"
  } >"$log_file"; then
    echo "[$target] Could not write the delivery log; Screen was not touched." >&2
    return 1
  fi

  # Retire every pending trigger before touching the terminal. If screen exits
  # ambiguously or this process dies during injection, no later timer run can
  # issue the same resume a second time.
  if ! begin_registered_delivery "$target" "$now" "$run_id" "$log_file" "one-shot-usage" true true "$mode"; then
    echo "[$target] Could not retire persistent delivery state; Screen was not touched." >&2
    return 1
  fi
  if [[ -f "$request_json" ]]; then
    if ! mv "$request_json" "$sent_json"; then
      echo "[$target] Could not retire one-shot JSON state; Screen was not touched." >&2
      return 1
    fi
    retired_json=1
  fi
  if ! mv "$request_file" "$sent_file"; then
    if [[ "$retired_json" -eq 1 ]] && ! mv "$sent_json" "$request_json"; then
      echo "[$target] Could not restore one-shot JSON state after retirement failed." >&2
    fi
    echo "[$target] Could not retire the one-shot request; Screen was not touched." >&2
    return 1
  fi
  if ! begin_one_shot_delivery "$sent_json" "$run_id" "$now"; then
    echo "[$target] Could not annotate retired one-shot state; Screen was not touched." >&2
    return 1
  fi

  set +e
  send_recovery_sequence "$target" "$screen_session" "$screen_window" "$log_file" "$mode"
  status="$?"
  set -e
  completed_at="$(date -u +%s)"
  if finish_registered_delivery "$target" "$run_id" "$resume_delivery_state" "$reminder_delivery_state" "$completed_at" "$mode" "$goal_delivery_state" "$continue_delivery_state"; then
    :
  else
    finish_status="$?"
  fi
  if finish_one_shot_delivery "$sent_json" "$run_id" "$resume_delivery_state" "$reminder_delivery_state" "$completed_at" "$mode" "$goal_delivery_state" "$continue_delivery_state"; then
    :
  else
    result="$?"
    if [[ "$finish_status" -eq 0 ]]; then
      finish_status="$result"
    fi
  fi

  if [[ "$status" -eq 0 && "$resume_delivery_state" == "submitted" && "$finish_status" -eq 0 ]]; then
    echo "[$target] Sent $mode recovery to screen session '$screen_session' window '$screen_window'. Log: $log_file"
  else
    echo "[$target] Recovery delivery state is '$resume_delivery_state' (screen status $status). The request was retired and will not be retried automatically." >&2
    if [[ "$finish_status" -ne 0 ]]; then
      echo "[$target] The terminal attempt completed, but final delivery state could not be committed." >&2
    fi
    echo "[$target] Log: $log_file" >&2
    if [[ "$status" -ne 0 ]]; then
      return "$status"
    fi
    if [[ "$finish_status" -ne 0 ]]; then
      return "$finish_status"
    fi
    return 1
  fi
}

mark_registered_stop_seen_if_needed() {
  local target="$1" dir active_json now tmp
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  [[ -f "$active_json" && -f "$forecast_json" ]] || return 0
  forecast_health >/dev/null || return 0
  if ! jq -e '(.stop_seen != true)' "$active_json" >/dev/null; then
    return 0
  fi
  if ! jq -e '
    (.current.allowed == false)
      or (.current.limit_reached == true)
      or ((.current.primary_window.remaining_percent // 1) <= 0)
      or ((.current.secondary_window.remaining_percent // 1) <= 0)
  ' "$forecast_json" >/dev/null; then
    return 0
  fi
  now="$(date -u +%s)"
  if ! tmp="$(mktemp "$dir/.keepalive.json.tmp.XXXXXX")"; then
    echo "[$target] Could not create a temporary persistent keepalive state file." >&2
    return 1
  fi
  if ! jq --argjson now "$now" --slurpfile forecast "$forecast_json" '
    ($forecast[0].current // {}) as $cur
    | .state = "waiting-for-usage"
    | .stop_seen = true
    | .stop_seen_at_epoch = $now
    | .stop_seen_at_utc = ($now | todateiso8601)
    | .stop_windows = ([
        (if (($cur.primary_window.remaining_percent // 1) <= 0) then "5h window" else empty end),
        (if (($cur.secondary_window.remaining_percent // 1) <= 0) then "weekly window" else empty end),
        (if (($cur.allowed == false) or ($cur.limit_reached == true)) then "backend usage gate" else empty end)
      ])
  ' "$active_json" >"$tmp"; then
    rm -f "$tmp"
    echo "[$target] Could not prepare the observed-stop persistent state." >&2
    return 1
  fi
  if ! mv -f "$tmp" "$active_json"; then
    rm -f "$tmp"
    echo "[$target] Could not commit the observed-stop persistent state." >&2
    return 1
  fi
  echo "[$target] Keepalive observed exhausted or backend-blocked usage; waiting for usage to become available."
}

send_registered_recovery() {
  local target="$1"
  local trigger="$2" clear_usage="$3" clear_capacity="$4"
  require_target "$target"
  need jq
  need screen
  need timeout
  local dir active_json active_md screen_config screen_session screen_window run_id log_file status now completed_at mode finish_status=0
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
  if ! mode="$(load_delivery_mode "$target")"; then
    return 1
  fi

  now="$(date -u +%s)"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
  log_file="$dir/keepalive-recovery-$run_id.log"
  if ! {
    echo "Sending persistent keepalive recovery at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Target: $target"
    echo "Trigger: $trigger"
    echo "Recovery mode: $mode"
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
  } >"$log_file"; then
    echo "[$target] Could not write the persistent delivery log; Screen was not touched." >&2
    return 1
  fi

  # Reset the observed-stop cycle before terminal injection. This is the
  # durable at-most-once boundary for persistent delivery.
  if ! begin_registered_delivery "$target" "$now" "$run_id" "$log_file" "$trigger" "$clear_usage" "$clear_capacity" "$mode"; then
    echo "[$target] Could not retire persistent delivery state; Screen was not touched." >&2
    return 1
  fi
  registered_delivery_performed=1

  set +e
  send_recovery_sequence "$target" "$screen_session" "$screen_window" "$log_file" "$mode"
  status="$?"
  set -e
  completed_at="$(date -u +%s)"
  if finish_registered_delivery "$target" "$run_id" "$resume_delivery_state" "$reminder_delivery_state" "$completed_at" "$mode" "$goal_delivery_state" "$continue_delivery_state"; then
    :
  else
    finish_status="$?"
  fi

  if [[ "$status" -ne 0 || "$resume_delivery_state" != "submitted" || "$finish_status" -ne 0 ]]; then
    echo "[$target] Persistent recovery delivery state is '$resume_delivery_state' (screen status $status). This cycle was retired and will not be retried automatically. Log: $log_file" >&2
    if [[ "$finish_status" -ne 0 ]]; then
      echo "[$target] The terminal attempt completed, but final persistent state could not be committed." >&2
    fi
    if [[ "$status" -ne 0 ]]; then
      return "$status"
    fi
    if [[ "$finish_status" -ne 0 ]]; then
      return "$finish_status"
    fi
    return 1
  fi
  echo "[$target] Sent persistent $mode recovery to screen session '$screen_session' window '$screen_window'. Log: $log_file"
}

process_registered_keepalive() {
  local target="$1"
  require_target "$target"
  need jq
  local dir active_json usage_ready="false" capacity_ready="false" stop_seen capacity_stop_seen forecast_health_text="missing forecast" forecast_usable="false" forecast_available="false" one_shot_ready="false" result trigger clear_usage="false" clear_capacity="false" now
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  if [[ ! -f "$active_json" ]]; then
    return 0
  fi
  if observe_capacity_warning "$target"; then
    :
  else
    result="$?"
    if [[ "$result" -eq 70 ]]; then
      capacity_scan_status="$result"
    else
      return "$result"
    fi
  fi

  if [[ -f "$forecast_json" ]]; then
    if forecast_health_text="$(forecast_health)"; then
      forecast_usable="true"
      if mark_registered_stop_seen_if_needed "$target"; then
        :
      else
        result="$?"
        return "$result"
      fi
    fi
  fi
  if ! result="$(jq -r '[.stop_seen // false, .capacity_stop_seen // false] | @tsv' "$active_json")"; then
    echo "[$target] Could not read persistent keepalive state." >&2
    return 1
  fi
  stop_seen="${result%%$'\t'*}"
  capacity_stop_seen="${result#*$'\t'}"
  if [[ "$forecast_usable" == "true" && "$(forecast_ready)" == "true" ]]; then
    forecast_available="true"
  fi
  if [[ "$stop_seen" == "true" && "$forecast_available" == "true" ]]; then
    usage_ready="true"
  fi
  if [[ "$capacity_stop_seen" == "true" ]]; then
    capacity_ready="true"
  fi

  if [[ "$forecast_available" == "true" && -f "$dir/resume-request.md" ]]; then
    now="$(date -u +%s)"
    if one_shot_request_ready_now "$target" "$now"; then
      one_shot_ready="true"
    else
      result="$?"
      if [[ "$result" -gt 1 ]]; then
        return "$result"
      fi
    fi
  fi
  if [[ "$one_shot_ready" == "true" && ( "$usage_ready" == "true" || "$capacity_ready" == "true" ) ]]; then
    echo "[$target] Eligible one-shot request will coalesce the persistent recovery trigger for this pass."
    usage_ready="false"
    capacity_ready="false"
  elif [[ "$usage_ready" == "true" && -f "$dir/resume-request.md" ]]; then
    echo "[$target] Keepalive is waiting, but a one-shot resume request exists; leaving that request in control."
    usage_ready="false"
  fi
  if [[ "$usage_ready" != "true" && "$capacity_ready" != "true" ]]; then
    if [[ "$stop_seen" == "true" ]]; then
      echo "[$target] Keepalive observed usage exhaustion; forecast readiness: $forecast_health_text."
    elif [[ "$forecast_usable" != "true" ]]; then
      echo "[$target] Keepalive capacity scan completed; usage forecast is not usable: $forecast_health_text."
    else
      echo "[$target] Keepalive armed; no eligible recovery trigger."
    fi
    return 0
  fi

  if [[ "$usage_ready" == "true" && "$capacity_ready" == "true" ]]; then
    trigger="usage+model-capacity"
    clear_usage="true"
    clear_capacity="true"
  elif [[ "$capacity_ready" == "true" ]]; then
    trigger="model-capacity"
    clear_capacity="true"
  else
    trigger="usage"
    clear_usage="true"
  fi
  send_registered_recovery "$target" "$trigger" "$clear_usage" "$clear_capacity"
}

process_target_if_ready() {
  local target="$1" active_json request_file had_work=0 lock_fd status=0 result registered_delivery_performed=0 capacity_scan_status=0
  require_target "$target"
  if ! acquire_target_lock "$target" lock_fd nonblocking; then
    echo "[$target] Another keepalive operation holds the target lock; skipping this timer pass."
    return 0
  fi
  active_json="$(active_keepalive_json "$target")"
  request_file="$(target_dir "$target")/resume-request.md"
  if [[ -f "$active_json" || -f "$request_file" ]]; then
    had_work=1
  fi

  if process_registered_keepalive "$target"; then
    :
  else
    status="$?"
  fi
  if [[ -f "$request_file" && "$registered_delivery_performed" -eq 0 && "$status" -eq 0 ]]; then
    if send_target_if_ready "$target"; then
      :
    else
      result="$?"
      if [[ "$status" -eq 0 ]]; then
        status="$result"
      fi
    fi
  elif [[ -f "$request_file" && ( "$registered_delivery_performed" -eq 1 || "$status" -ne 0 ) ]]; then
    echo "[$target] Deferred the one-shot request because persistent processing already handled or blocked this pass."
  elif [[ "$had_work" -eq 0 ]]; then
    echo "[$target] No active keepalive or one-shot resume request."
  fi
  if [[ "$status" -eq 0 && "$capacity_scan_status" -ne 0 ]]; then
    status="$capacity_scan_status"
  fi
  release_target_lock "$lock_fd"
  return "$status"
}

send_if_ready() {
  mkdir -p "$targets_dir"
  if [[ "${1:-}" != "" ]]; then
    process_target_if_ready "$1"
    return
  fi
  local found=0 dir target overall_status=0 result
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" ]] || continue
    found=1
    target="$(basename "$dir")"
    if process_target_if_ready "$target"; then
      :
    else
      result="$?"
      if [[ "$overall_status" -eq 0 ]]; then
        overall_status="$result"
      fi
    fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No targets configured under $targets_dir"
  fi
  return "$overall_status"
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
    if screen_session_matches "$configured_session" "$screen_session"; then
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
  local forecast_health_text
  echo "State: $state_dir"
  echo "Targets: $targets_dir"
  echo "Forecast JSON: $forecast_json"
  if [[ -f "$forecast_json" ]]; then
    if forecast_health_text="$(forecast_health)"; then
      echo "Forecast health: $forecast_health_text"
      echo "Usage available: $(forecast_ready)"
      jq -r '"Forecast updated: " + (.updated_at_utc // "unknown")' "$forecast_json"
    else
      echo "Forecast health: $forecast_health_text"
      echo "Usage available: false"
    fi
  else
    echo "Forecast health: missing forecast"
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
  local count=0 dir
  for dir in "$targets_dir"/*; do
    [[ -d "$dir" && -f "$dir/resume-request.md" ]] || continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

registered_target_count() {
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
  local forecast_health_text
  if [[ ! -f "$forecast_json" ]]; then
    echo "Forecast: missing ($forecast_json)"
    return
  fi
  if ! forecast_health_text="$(forecast_health)"; then
    echo "Forecast: $forecast_health_text"
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
  echo "  Requires exhaustion observation: $require_stop_seen"
  echo "  Exhaustion observed: $stop_seen ($stop_windows)"
  echo "  Eligible after: $send_after"
  echo "  Reason: $reason"
  echo "  Reset watched: $reset_window at $reset_at"
  echo "  Forecast end: $forecast_window at $forecast_end"
  echo "  Resume-to-forecast-end: $gap_human"
}

active_summary() {
  local target="$1" dir active_json objective registered mode state stop_seen stop_windows capacity_state capacity_latched recovery_count resume_count continue_count last_sent last_trigger last_delivery last_goal last_continue last_reminder forecast_window forecast_end
  dir="$(target_dir "$target")"
  active_json="$(active_keepalive_json "$target")"
  if [[ ! -f "$active_json" ]]; then
    return 0
  fi
  objective="$(jq -r '.objective // "unknown"' "$active_json")"
  registered="$(jq -r '.registered_at_utc // "unknown"' "$active_json")"
  mode="$(jq -r '.delivery_mode // "goal"' "$active_json")"
  state="$(jq -r '.state // "unknown"' "$active_json")"
  stop_seen="$(jq -r '.stop_seen // false' "$active_json")"
  stop_windows="$(jq -r '(.stop_windows // []) | if length == 0 then "none" else join(", ") end' "$active_json")"
  capacity_state="$(jq -r '.capacity_state // "armed"' "$active_json")"
  capacity_latched="$(jq -r '.capacity_warning_latched // false' "$active_json")"
  recovery_count="$(jq -r '.recovery_count // .resume_count // 0' "$active_json")"
  resume_count="$(jq -r '.resume_count // 0' "$active_json")"
  continue_count="$(jq -r '.continue_count // 0' "$active_json")"
  last_sent="$(jq -r '.last_sent_at_utc // "never"' "$active_json")"
  last_trigger="$(jq -r '.last_delivery_trigger // "none"' "$active_json")"
  last_delivery="$(jq -r '.last_delivery_state // "none"' "$active_json")"
  last_goal="$(jq -r '.last_goal_delivery_state // "none"' "$active_json")"
  last_continue="$(jq -r '.last_continue_delivery_state // "none"' "$active_json")"
  last_reminder="$(jq -r '.last_reminder_delivery_state // "none"' "$active_json")"
  echo "  Objective: ${objective:-unknown}"
  echo "  Registered: ${registered:-unknown}"
  echo "  Recovery mode: $mode"
  echo "  Usage state: $state; exhaustion observed: $stop_seen ($stop_windows)"
  echo "  Model-capacity state: $capacity_state; warning latched: $capacity_latched"
  echo "  Rule: recover after usage becomes available or a stable exact model-capacity warning is observed"
  echo "  Recovery count: $recovery_count (/goal resume: $resume_count, Continue: $continue_count)"
  echo "  Last delivery: trigger $last_trigger; aggregate $last_delivery; goal $last_goal; Continue $last_continue; reminder $last_reminder"
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
  local lock_fd
  acquire_target_lock "$target" lock_fd
  rm -f "$(target_dir "$target")/resume-request.md" "$(target_dir "$target")/resume-request.json"
  release_target_lock "$lock_fd"
  echo "Removed resume request for target '$target'."
}

remove_target() {
  local target="${1:-}"
  require_target "$target"
  local lock_fd mapping_fd cleanup_status=0
  acquire_mapping_lock mapping_fd
  acquire_target_lock "$target" lock_fd
  rm -rf "$(target_dir "$target")"
  if cleanup_capacity_snapshots "$target"; then
    :
  else
    cleanup_status="$?"
  fi
  release_target_lock "$lock_fd"
  release_target_lock "$mapping_fd"
  if [[ "$cleanup_status" -ne 0 ]]; then
    echo "Removed target '$target', but could not remove its private Screen snapshot artifacts." >&2
    return "$cleanup_status"
  fi
  echo "Removed target '$target'."
}

systemd_quote() {
  local value="$1"
  if [[ -z "$value" || "$value" == *[[:cntrl:]]* ]]; then
    echo "Cannot write a systemd unit containing an empty value or control character." >&2
    return 1
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//%/%%}"
  printf '"%s"' "$value"
}

install_systemd_units() {
  local service_path="$systemd_user_dir/$service_name" timer_path="$systemd_user_dir/$timer_name"
  local quoted_script quoted_state quoted_forecast quoted_max_age quoted_screen_timeout quoted_five quoted_weekly
  quoted_script="$(systemd_quote "$script_path")"
  quoted_state="$(systemd_quote "CODEX_KEEPALIVE_STATE_DIR=$state_dir")"
  quoted_forecast="$(systemd_quote "CODEX_USAGE_FORECAST_JSON=$forecast_json")"
  quoted_max_age="$(systemd_quote "CODEX_KEEPALIVE_FORECAST_MAX_AGE_SECONDS=$forecast_max_age_seconds")"
  quoted_screen_timeout="$(systemd_quote "CODEX_KEEPALIVE_SCREEN_TIMEOUT_SECONDS=$screen_timeout_seconds")"
  quoted_five="$(systemd_quote "CODEX_KEEPALIVE_THRESHOLD_PERCENT=$default_threshold_percent")"
  quoted_weekly="$(systemd_quote "CODEX_KEEPALIVE_WEEKLY_THRESHOLD_PERCENT=$default_weekly_threshold_percent")"
  mkdir -p "$systemd_user_dir"
  atomic_write "$service_path" <<EOF
# Generated by $script_path. Run '$script_path uninstall' to remove.
[Unit]
Description=Recover registered Codex work after usage or model-capacity stops
Wants=$forecast_service_name
After=$forecast_service_name

[Service]
Type=oneshot
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
Environment=$quoted_state
Environment=$quoted_forecast
Environment=$quoted_max_age
Environment=$quoted_screen_timeout
Environment=$quoted_five
Environment=$quoted_weekly
ExecStart=:$quoted_script send-if-ready
EOF
  atomic_write "$timer_path" <<EOF
# Generated by $script_path. Run '$script_path uninstall' to remove.
[Unit]
Description=Check registered Codex work once per minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Persistent=true
Unit=$service_name

[Install]
WantedBy=timers.target
EOF
  echo "Installed $service_path"
  echo "Installed $timer_path"
}

start_timer() {
  need systemctl
  install_systemd_units
  systemctl --user daemon-reload
  systemctl --user enable --now "$timer_name"
}

stop_timer() {
  need systemctl
  systemctl --user disable --now "$timer_name" || true
  systemctl --user stop "$service_name" || true
}

uninstall_timer() {
  need systemctl
  stop_timer
  rm -f "$systemd_user_dir/$timer_name" "$systemd_user_dir/$service_name"
  cleanup_all_capacity_snapshots
  systemctl --user daemon-reload
  systemctl --user reset-failed "$timer_name" "$service_name" >/dev/null 2>&1 || true
  echo "Removed generated keepalive user systemd units."
}

validate_forecast_max_age
validate_screen_timeout
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
  uninstall)
    uninstall_timer
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
