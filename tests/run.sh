#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT INT TERM
tests_run=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  tests_run=$((tests_run + 1))
  echo "ok $tests_run - $1"
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

assert_jq() {
  local file="$1" expression="$2"
  jq -e "$expression" "$file" >/dev/null || fail "$file failed jq assertion: $expression"
}

assert_mode() {
  local file="$1" expected="$2" actual
  actual="$(stat -c '%a' "$file")"
  [[ "$actual" == "$expected" ]] || fail "$file mode is $actual, expected $expected"
}

assert_line_count() {
  local file="$1" expected="$2" wanted="$3" actual
  actual="$(grep -Fxc -- "$expected" "$file" || true)"
  [[ "$actual" == "$wanted" ]] || \
    fail "$file contains $actual exact '$expected' lines, expected $wanted"
}

assert_recovery_sequence() {
  local file="$1"
  shift
  local -a actual=()
  mapfile -t actual < <(grep -Fx -e 'TEXT /goal resume' -e 'TEXT Continue' "$file" || true)
  [[ "${#actual[@]}" == "$#" ]] || \
    fail "$file contains ${#actual[@]} recovery messages, expected $#"
  local index=0 expected
  for expected in "$@"; do
    [[ "${actual[$index]}" == "TEXT $expected" ]] || \
      fail "$file recovery message $((index + 1)) is '${actual[$index]}', expected 'TEXT $expected'"
    index=$((index + 1))
  done
}

assert_message_submitted() {
  local file="$1" message="$2" wanted="$3" actual
  actual="$(awk -v message="TEXT $message" '
    previous == message && $0 == "ENTER" { count++ }
    { previous = $0 }
    END { print count + 0 }
  ' "$file")"
  [[ "$actual" == "$wanted" ]] || \
    fail "$file submitted '$message' $actual times, expected $wanted"
}

assert_logged_paths_absent() {
  local file="$1" path found=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    found=1
    [[ ! -e "$path" ]] || fail "transient Screen snapshot remains at $path"
  done <"$file"
  [[ "$found" -eq 1 ]] || fail "$file contains no Screen snapshot paths"
}

assert_hardcopy_modes() {
  local file="$1" dir_mode file_mode path found=0
  while IFS=$'\t' read -r dir_mode file_mode path; do
    [[ -n "$path" ]] || continue
    found=1
    [[ "$dir_mode" == "700" ]] || \
      fail "Screen snapshot directory for $path had mode $dir_mode at capture time, expected 700"
    [[ "$file_mode" == "600" ]] || \
      fail "Screen snapshot $path had mode $file_mode at capture time, expected 600"
  done <"$file"
  [[ "$found" -eq 1 ]] || fail "$file contains no Screen snapshot mode observations"
}

test_api_helpers() {
  local dir="$tmp_root/api" bin="$tmp_root/api/bin"
  local auth="$dir/auth.json" args="$dir/curl.args" config="$dir/curl.config"
  local usage_out="$dir/usage.json" credits_out="$dir/credits.json" error_out="$dir/error.txt"
  mkdir -p "$bin"
  printf '%s\n' '{"tokens":{"access_token":"sentinel-access-token","account_id":"sentinel-account-id"}}' >"$auth"

  cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$MOCK_CURL_ARGS"
cat >"$MOCK_CURL_CONFIG"
printf '%s\n' "$MOCK_CURL_RESPONSE"
EOF
  chmod +x "$bin/curl"

  (
    export PATH="$bin:$PATH"
    export CODEX_AUTH_FILE="$auth"
    export MOCK_CURL_ARGS="$args"
    export MOCK_CURL_CONFIG="$config"
    export MOCK_CURL_RESPONSE='{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_at":1900000000},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1900000100}},"additional_rate_limits":[],"credits":{"balance":10},"rate_limit_reset_credits":{"available_count":2}}'
    "$repo_root/skills/codex-usage/scripts/show-codex-usage.sh" --json >"$usage_out"
  )
  assert_jq "$usage_out" '.plan_type == "plus" and .rate_limit.primary_window.used_percent == 20'
  assert_not_contains "$args" sentinel-access-token
  assert_not_contains "$args" sentinel-account-id
  assert_contains "$config" 'Authorization: Bearer sentinel-access-token'
  assert_contains "$config" 'ChatGPT-Account-ID: sentinel-account-id'

  (
    export PATH="$bin:$PATH"
    export CODEX_AUTH_FILE="$auth"
    export MOCK_CURL_ARGS="$args"
    export MOCK_CURL_CONFIG="$config"
    export MOCK_CURL_RESPONSE='{"available_count":1,"total_earned_count":2,"credits":[]}'
    "$repo_root/skills/codex-credits/scripts/show-reset-credits.sh" --json >"$credits_out"
  )
  assert_jq "$credits_out" '.available_count == 1'
  assert_not_contains "$args" sentinel-access-token

  printf '%s\n' '{}' >"$auth"
  if CODEX_AUTH_FILE="$auth" "$repo_root/skills/codex-usage/scripts/show-codex-usage.sh" --json >"$dir/missing.out" 2>"$error_out"; then
    fail "usage helper accepted an auth file without credentials"
  fi
  assert_contains "$error_out" 'missing a non-empty access token'

  if CODEX_AUTH_FILE="$auth" CODEX_USAGE_URL='http://example.invalid/usage' \
      "$repo_root/skills/codex-usage/scripts/show-codex-usage.sh" --json >"$dir/unsafe.out" 2>"$error_out"; then
    fail "usage helper accepted an unsafe endpoint without explicit opt-in"
  fi
  assert_contains "$error_out" 'must use https://chatgpt.com'
  pass "API helpers protect credentials and report auth/endpoint errors"
}

test_forecast() {
  local dir="$tmp_root/forecast"
  local bin="$dir/bin" state="$dir/state" units="$dir/units"
  local helper="$dir/usage-helper" forecast="$state/codex-usage-forecast.json"
  local forecast_script="$repo_root/skills/codex-forecast/scripts/usage-monitor.sh"
  mkdir -p "$bin"

  cat >"$helper" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--json" ]]
count=0
if [[ -f "$MOCK_HELPER_COUNT" ]]; then
  count="$(<"$MOCK_HELPER_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_HELPER_COUNT"
used=$((count * 10))
printf '{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":%s,"reset_at":null},"secondary_window":{"used_percent":%s,"reset_at":null}},"additional_rate_limits":[],"credits":{"balance":null},"rate_limit_reset_credits":{"available_count":0}}\n' "$used" "$used"
EOF
  chmod +x "$helper"

  cat >"$bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == '-u +%s' ]]; then
  count=0
  if [[ -f "$MOCK_DATE_COUNT" ]]; then
    count="$(<"$MOCK_DATE_COUNT")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" >"$MOCK_DATE_COUNT"
  echo $((1700000000 + count * 60))
else
  /usr/bin/date "$@"
fi
EOF
  cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_SYSTEMCTL_LOG"
EOF
  chmod +x "$bin/date" "$bin/systemctl"

  for _ in 1 2; do
    PATH="$bin:$PATH" \
      CODEX_USAGE_HELPER="$helper" \
      CODEX_USAGE_STATE_DIR="$state" \
      CODEX_USAGE_FORECAST_MIN_ELAPSED=1 \
      MOCK_HELPER_COUNT="$dir/helper.count" \
      MOCK_DATE_COUNT="$dir/date.count" \
      "$forecast_script" once >/dev/null
  done

  assert_jq "$forecast" '.predictions.primary_window.status == "exhaustion_predicted_reset_unknown"'
  assert_jq "$forecast" '.predictions.primary_window.will_run_out_before_reset == null'
  assert_mode "$state" 700
  assert_mode "$forecast" 600
  assert_mode "$state/codex-usage-samples.jsonl" 600

  PATH="$bin:$PATH" \
    CODEX_USAGE_HELPER="$helper" \
    CODEX_USAGE_STATE_DIR="$state" \
    CODEX_SYSTEMD_USER_DIR="$units" \
    MOCK_SYSTEMCTL_LOG="$dir/systemctl.log" \
    "$forecast_script" start >/dev/null
  assert_contains "$units/codex-usage-forecast.service" "ExecStart=:\"$forecast_script\" once"
  assert_contains "$units/codex-usage-forecast.service" 'UMask=0077'
  assert_mode "$units/codex-usage-forecast.service" 600

  PATH="$bin:$PATH" \
    CODEX_SYSTEMD_USER_DIR="$units" \
    MOCK_SYSTEMCTL_LOG="$dir/systemctl.log" \
    "$forecast_script" uninstall >/dev/null
  [[ ! -e "$units/codex-usage-forecast.service" ]] || fail "forecast service survived uninstall"
  pass "forecast handles unknown resets, private state, locking, and unit lifecycle"
}

write_keepalive_forecast() {
  local path="$1" allowed="$2" limit_reached="$3" primary="$4" secondary="$5" now
  now="$(date -u +%s)"
  jq -n \
    --argjson now "$now" \
    --argjson allowed "$allowed" \
    --argjson limit_reached "$limit_reached" \
    --argjson primary "$primary" \
    --argjson secondary "$secondary" '{
      updated_at_epoch: $now,
      updated_at_utc: ($now | todateiso8601),
      current: {
        allowed: $allowed,
        limit_reached: $limit_reached,
        primary_window: {remaining_percent: $primary, reset_at: ($now + 3600), reset_at_utc: (($now + 3600) | todateiso8601)},
        secondary_window: {remaining_percent: $secondary, reset_at: ($now + 86400), reset_at_utc: (($now + 86400) | todateiso8601)}
      },
      predictions: {
        primary_window: {will_run_out_before_reset: false, eta_exhaustion_epoch: null, eta_exhaustion_utc: null},
        secondary_window: {will_run_out_before_reset: false, eta_exhaustion_epoch: null, eta_exhaustion_utc: null}
      }
    }' >"$path"
}

test_keepalive() {
  local dir="$tmp_root/keepalive"
  local bin="$dir/bin" state="$dir/state" units="$dir/units"
  local forecast="$dir/forecast.json" ready_forecast="$dir/ready-forecast.json" screen_log="$dir/screen.log"
  local keepalive_script="$repo_root/skills/codex-keepalive/scripts/keepalive.sh"
  local first_pid second_pid resume_count sent_json
  local storage_state storage_forecast storage_screen_log
  local failure_call failure_state failure_forecast failure_log failure_count expected_resumes before_resumes after_resumes failure_sent_json
  mkdir -p "$bin"
  export _CODEX_KEEPALIVE_SNAPSHOT_DIR="$dir/snapshots"

  cat >"$bin/screen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_SCREEN_LOG"

is_hardcopy=0
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-X" && "$argument" == "hardcopy" ]]; then
    is_hardcopy=1
    break
  fi
  previous="$argument"
done
if [[ "$is_hardcopy" -eq 1 ]]; then
  hardcopy_count=0
  if [[ -n "${MOCK_SCREEN_HARDCOPY_COUNT:-}" && -f "$MOCK_SCREEN_HARDCOPY_COUNT" ]]; then
    hardcopy_count="$(<"$MOCK_SCREEN_HARDCOPY_COUNT")"
  fi
  hardcopy_count=$((hardcopy_count + 1))
  if [[ -n "${MOCK_SCREEN_HARDCOPY_COUNT:-}" ]]; then
    printf '%s\n' "$hardcopy_count" >"$MOCK_SCREEN_HARDCOPY_COUNT"
  fi
  hardcopy_path="${!#}"
  if [[ -n "${MOCK_SCREEN_HARDCOPY_PATH_LOG:-}" ]]; then
    printf '%s\n' "$hardcopy_path" >>"$MOCK_SCREEN_HARDCOPY_PATH_LOG"
  fi
  if [[ -n "${MOCK_SCREEN_HARDCOPY_MODE_LOG:-}" ]]; then
    printf '%s\t%s\t%s\n' \
      "$(stat -c '%a' "$(dirname -- "$hardcopy_path")")" \
      "$(stat -c '%a' "$hardcopy_path")" \
      "$hardcopy_path" >>"$MOCK_SCREEN_HARDCOPY_MODE_LOG"
  fi
  if [[ "${MOCK_SCREEN_FAIL_HARDCOPY_CALL:-0}" == "$hardcopy_count" ]]; then
    exit 1
  fi
  if [[ -n "${MOCK_SCREEN_VIEWPORT:-}" ]]; then
    cp -- "$MOCK_SCREEN_VIEWPORT" "$hardcopy_path"
  else
    : >"$hardcopy_path"
  fi
  exit 0
fi

# Count terminal delivery operations independently from hardcopy calls so the
# existing stage-failure assertions remain stable when capture is enabled.
if [[ -n "${MOCK_SCREEN_EVENT_LOG:-}" ]]; then
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "stuff" ]]; then
      if [[ "$argument" == $'\015' ]]; then
        printf '%s\n' 'ENTER' >>"$MOCK_SCREEN_EVENT_LOG"
      else
        printf 'TEXT %s\n' "$argument" >>"$MOCK_SCREEN_EVENT_LOG"
      fi
      break
    fi
    previous="$argument"
  done
fi
count=0
if [[ -f "$MOCK_SCREEN_COUNT" ]]; then
  count="$(<"$MOCK_SCREEN_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_SCREEN_COUNT"
if [[ "${MOCK_SCREEN_FAIL_CALL:-0}" == "$count" ]]; then
  exit 1
fi
EOF
  cat >"$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MOCK_SYSTEMCTL_LOG"
exit 0
EOF
  cat >"$bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_MV_FAIL_PATTERN:-}" && "$*" == *"$MOCK_MV_FAIL_PATTERN"* ]]; then
  exit 73
fi
exec /usr/bin/mv "$@"
EOF
  cat >"$bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
swap_after_observation=0
if [[ -n "${MOCK_JQ_SWAP_FORECAST:-}" && -n "${MOCK_JQ_READY_FORECAST:-}" ]]; then
  for argument in "$@"; do
    if [[ "$argument" == *'decision:'* && "$argument" == *'observed_stop_windows:'* ]]; then
      swap_after_observation=1
      break
    fi
  done
fi
if [[ "$swap_after_observation" -eq 1 ]]; then
  status=0
  /usr/bin/jq "$@" || status="$?"
  if [[ "$status" -eq 0 ]]; then
    /usr/bin/cp "$MOCK_JQ_READY_FORECAST" "$MOCK_JQ_SWAP_FORECAST"
  fi
  exit "$status"
fi
exec /usr/bin/jq "$@"
EOF
  chmod +x "$bin/screen" "$bin/systemctl" "$bin/mv" "$bin/jq"

  if CODEX_KEEPALIVE_STATE_DIR="$state" "$keepalive_script" configure-screen .. session 0 >"$dir/dotdot.out" 2>"$dir/dotdot.err"; then
    fail "keepalive accepted '..' as a target"
  fi
  assert_contains "$dir/dotdot.err" "'.' and '..' are not allowed"

  local duplicate_state="$dir/duplicate-screen-state"
  CODEX_KEEPALIVE_STATE_DIR="$duplicate_state" \
    "$keepalive_script" configure-screen mapone shared-screen 0 >/dev/null
  if CODEX_KEEPALIVE_STATE_DIR="$duplicate_state" \
      "$keepalive_script" configure-screen maptwo shared-screen 0 \
        >"$dir/duplicate-screen.out" 2>"$dir/duplicate-screen.err"; then
    fail "keepalive accepted duplicate Screen session/window mapping"
  fi
  [[ ! -f "$duplicate_state/targets/maptwo/screen.env" ]] || \
    fail "duplicate Screen mapping was committed before rejection"
  CODEX_KEEPALIVE_STATE_DIR="$duplicate_state" \
    "$keepalive_script" configure-screen maptwo shared-screen 1 >/dev/null
  assert_contains "$duplicate_state/targets/maptwo/screen.env" 'SCREEN_SESSION=shared-screen'
  assert_contains "$duplicate_state/targets/maptwo/screen.env" 'SCREEN_WINDOW=1'

  write_keepalive_forecast "$forecast" false true 5 5
  write_keepalive_forecast "$ready_forecast" true false 80 80
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$state" CODEX_USAGE_FORECAST_JSON="$forecast" \
    "$keepalive_script" configure-screen demo codex-demo 0 >/dev/null
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$state" CODEX_USAGE_FORECAST_JSON="$forecast" \
    "$keepalive_script" register demo 'Resume fixture goal.' >/dev/null
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$state" \
    CODEX_USAGE_FORECAST_JSON="$forecast" \
    MOCK_JQ_SWAP_FORECAST="$forecast" \
    MOCK_JQ_READY_FORECAST="$ready_forecast" \
    "$keepalive_script" queue-if-needed demo 'Resume fixture goal.' >/dev/null
  assert_jq "$state/targets/demo/resume-request.json" \
    '.stop_seen == true and ((.stop_windows // []) | index("backend usage gate") != null)'

  export MOCK_SCREEN_COUNT="$dir/screen.count"
  export MOCK_SCREEN_LOG="$screen_log"
  export MOCK_SCREEN_FAIL_CALL=4
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$state" CODEX_USAGE_FORECAST_JSON="$forecast" \
    "$keepalive_script" send-if-ready demo >"$dir/send-one.out" &
  first_pid="$!"
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$state" CODEX_USAGE_FORECAST_JSON="$forecast" \
    "$keepalive_script" send-if-ready demo >"$dir/send-two.out" &
  second_pid="$!"
  wait "$first_pid"
  wait "$second_pid"
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$state" CODEX_USAGE_FORECAST_JSON="$forecast" \
    "$keepalive_script" send-if-ready demo >/dev/null

  resume_count="$(grep -Fc '/goal resume' "$screen_log")"
  [[ "$resume_count" == "1" ]] || fail "keepalive injected /goal resume $resume_count times"
  assert_jq "$state/targets/demo/keepalive.json" \
    '.stop_seen == false and .resume_count == 0 and (.last_delivery_state // null) == null'
  sent_json="$(find "$state/targets/demo" -maxdepth 1 -name 'resume-sent-*.json' -print -quit)"
  [[ -n "$sent_json" ]] || fail "keepalive did not retain sent one-shot metadata"
  assert_jq "$sent_json" '.automatic_retry == false and .delivery_state == "submitted" and .reminder_delivery_state == "failed"'
  assert_mode "$state/targets/demo/keepalive.json" 600

  storage_state="$dir/storage-state"
  storage_forecast="$dir/storage-forecast.json"
  storage_screen_log="$dir/storage-screen.log"
  write_keepalive_forecast "$storage_forecast" false true 5 5
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$storage_state" CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
    "$keepalive_script" configure-screen storage codex-storage 0 >/dev/null
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$storage_state" CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
    "$keepalive_script" register storage 'Resume storage fixture.' >/dev/null
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$storage_state" CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
    "$keepalive_script" queue-if-needed storage 'Resume storage fixture.' >/dev/null
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$storage_state" \
    CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
    MOCK_SCREEN_COUNT="$dir/storage-screen.count" \
    MOCK_SCREEN_LOG="$storage_screen_log" \
    "$keepalive_script" send-if-ready storage >/dev/null
  write_keepalive_forecast "$storage_forecast" true false 80 80
  if PATH="$bin:$PATH" \
      CODEX_KEEPALIVE_STATE_DIR="$storage_state" \
      CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
      MOCK_MV_FAIL_PATTERN='.keepalive.json.tmp.' \
      MOCK_SCREEN_COUNT="$dir/storage-screen.count" \
      MOCK_SCREEN_LOG="$storage_screen_log" \
      "$keepalive_script" send-if-ready storage >"$dir/storage-failure.out" 2>"$dir/storage-failure.err"; then
    fail "keepalive ignored a failed pre-send state commit"
  fi
  [[ -f "$storage_state/targets/storage/resume-request.md" ]] || fail "storage failure retired the pending request"
  assert_not_contains "$storage_screen_log" '-X stuff'
  assert_contains "$dir/storage-failure.err" 'Screen was not touched'

  for failure_call in 1 2 3; do
    failure_state="$dir/screen-failure-$failure_call-state"
    failure_forecast="$dir/screen-failure-$failure_call-forecast.json"
    failure_log="$dir/screen-failure-$failure_call.log"
    failure_count="$dir/screen-failure-$failure_call.count"
    write_keepalive_forecast "$failure_forecast" false true 5 5
    PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$failure_state" CODEX_USAGE_FORECAST_JSON="$failure_forecast" \
      "$keepalive_script" configure-screen failure codex-failure 0 >/dev/null
    PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$failure_state" CODEX_USAGE_FORECAST_JSON="$failure_forecast" \
      "$keepalive_script" queue-if-needed failure 'Resume Screen failure fixture.' >/dev/null
    write_keepalive_forecast "$failure_forecast" true false 80 80

    if PATH="$bin:$PATH" \
        CODEX_KEEPALIVE_STATE_DIR="$failure_state" \
        CODEX_USAGE_FORECAST_JSON="$failure_forecast" \
        MOCK_SCREEN_COUNT="$failure_count" \
        MOCK_SCREEN_LOG="$failure_log" \
        MOCK_SCREEN_FAIL_CALL="$failure_call" \
        "$keepalive_script" send-if-ready >"$dir/screen-failure-$failure_call.out" 2>"$dir/screen-failure-$failure_call.err"; then
      fail "all-target keepalive scan hid Screen failure on call $failure_call"
    fi

    expected_resumes=1
    if [[ "$failure_call" -eq 1 ]]; then
      expected_resumes=0
    fi
    before_resumes="$(grep -Fc '/goal resume' "$failure_log" || true)"
    [[ "$before_resumes" == "$expected_resumes" ]] || \
      fail "Screen failure call $failure_call logged $before_resumes resume injections, expected $expected_resumes"
    [[ ! -f "$failure_state/targets/failure/resume-request.md" ]] || \
      fail "Screen failure call $failure_call left an automatically retryable request"
    failure_sent_json="$(find "$failure_state/targets/failure" -maxdepth 1 -name 'resume-sent-*.json' -print -quit)"
    [[ -n "$failure_sent_json" ]] || fail "Screen failure call $failure_call did not retain retired metadata"
    assert_jq "$failure_sent_json" '.automatic_retry == false'

    PATH="$bin:$PATH" \
      CODEX_KEEPALIVE_STATE_DIR="$failure_state" \
      CODEX_USAGE_FORECAST_JSON="$failure_forecast" \
      MOCK_SCREEN_COUNT="$failure_count" \
      MOCK_SCREEN_LOG="$failure_log" \
      MOCK_SCREEN_FAIL_CALL=0 \
      "$keepalive_script" send-if-ready >/dev/null
    after_resumes="$(grep -Fc '/goal resume' "$failure_log" || true)"
    [[ "$after_resumes" == "$before_resumes" ]] || \
      fail "Screen failure call $failure_call was retried automatically"
  done

  local capacity_banner='⚠ Selected model is at capacity. Please try a different model.'
  local capacity_fixture capacity_viewport

  capacity_register() {
    local fixture="$1" target="$2" mode="$3"
    local fixture_forecast="${4:-$fixture/missing-forecast.json}"
    mkdir -p "$fixture"
    : >"$fixture/screen.log"
    : >"$fixture/events.log"
    : >"$fixture/hardcopy-paths.log"
    : >"$fixture/hardcopy-modes.log"
    PATH="$bin:$PATH" \
      CODEX_KEEPALIVE_STATE_DIR="$fixture/state" \
      CODEX_USAGE_FORECAST_JSON="$fixture_forecast" \
      _CODEX_KEEPALIVE_SNAPSHOT_DIR="$fixture/snapshots" \
      "$keepalive_script" configure-screen "$target" "codex-$target" 0 >/dev/null
    PATH="$bin:$PATH" \
      CODEX_KEEPALIVE_STATE_DIR="$fixture/state" \
      CODEX_USAGE_FORECAST_JSON="$fixture_forecast" \
      _CODEX_KEEPALIVE_SNAPSHOT_DIR="$fixture/snapshots" \
      "$keepalive_script" register "$target" --mode "$mode" "Recover $mode capacity fixture." >/dev/null
  }

  capacity_scan() {
    local fixture="$1" target="$2" viewport="$3"
    local fixture_forecast="${4:-$fixture/missing-forecast.json}"
    PATH="$bin:$PATH" \
      CODEX_KEEPALIVE_STATE_DIR="$fixture/state" \
      CODEX_USAGE_FORECAST_JSON="$fixture_forecast" \
      _CODEX_KEEPALIVE_SNAPSHOT_DIR="$fixture/snapshots" \
      MOCK_SCREEN_COUNT="$fixture/delivery.count" \
      MOCK_SCREEN_LOG="$fixture/screen.log" \
      MOCK_SCREEN_EVENT_LOG="$fixture/events.log" \
      MOCK_SCREEN_HARDCOPY_COUNT="$fixture/hardcopy.count" \
      MOCK_SCREEN_HARDCOPY_PATH_LOG="$fixture/hardcopy-paths.log" \
      MOCK_SCREEN_HARDCOPY_MODE_LOG="$fixture/hardcopy-modes.log" \
      MOCK_SCREEN_VIEWPORT="$viewport" \
      MOCK_SCREEN_FAIL_CALL="${CAPACITY_FAIL_DELIVERY_CALL:-0}" \
      MOCK_SCREEN_FAIL_HARDCOPY_CALL="${CAPACITY_FAIL_HARDCOPY_CALL:-0}" \
      MOCK_MV_FAIL_PATTERN="${CAPACITY_MV_FAIL_PATTERN:-}" \
      "$keepalive_script" send-if-ready "$target"
  }

  capacity_fixture="$dir/capacity-continue"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capcontinue continue
  printf 'Working output\n%s\nReady for input\n' "$capacity_banner" >"$capacity_viewport"

  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log"
  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1

  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  printf '%s\n' 'Capacity warning cleared.' >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  capacity_scan "$capacity_fixture" capcontinue "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 2
  assert_not_contains "$capacity_fixture/screen.log" ' -h '
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"
  assert_hardcopy_modes "$capacity_fixture/hardcopy-modes.log"
  [[ ! -e "$capacity_fixture/missing-forecast.json" ]] || \
    fail "capacity fixture unexpectedly gained usable forecast telemetry"

  capacity_fixture="$dir/capacity-goal"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capgoal goal
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capgoal "$capacity_viewport" >/dev/null
  capacity_scan "$capacity_fixture" capgoal "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" '/goal resume'
  assert_message_submitted "$capacity_fixture/events.log" '/goal resume' 1
  assert_line_count "$capacity_fixture/events.log" 'TEXT Continue' 0
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/capacity-both"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capboth both
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capboth "$capacity_viewport" >/dev/null
  capacity_scan "$capacity_fixture" capboth "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" '/goal resume' Continue
  assert_message_submitted "$capacity_fixture/events.log" '/goal resume' 1
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/capacity-one-shot-coalesce"
  capacity_viewport="$capacity_fixture/viewport.txt"
  local coalesce_forecast="$capacity_fixture/forecast.json"
  capacity_register "$capacity_fixture" capcoalesce continue "$coalesce_forecast"
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capcoalesce "$capacity_viewport" "$coalesce_forecast" >/dev/null
  write_keepalive_forecast "$coalesce_forecast" true false 80 80
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$capacity_fixture/state" \
    CODEX_USAGE_FORECAST_JSON="$coalesce_forecast" \
    _CODEX_KEEPALIVE_SNAPSHOT_DIR="$capacity_fixture/snapshots" \
    "$keepalive_script" queue capcoalesce 'Coalesce this ready one-shot request.' >/dev/null
  capacity_scan "$capacity_fixture" capcoalesce "$capacity_viewport" "$coalesce_forecast" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  [[ ! -f "$capacity_fixture/state/targets/capcoalesce/resume-request.md" ]] || \
    fail "coalesced one-shot request remained pending"
  [[ ! -f "$capacity_fixture/state/targets/capcoalesce/resume-request.json" ]] || \
    fail "coalesced one-shot JSON remained pending"
  assert_jq "$capacity_fixture/state/targets/capcoalesce/keepalive.json" '
    .stop_seen == false
    and .capacity_stop_seen == false
    and .capacity_warning_latched == true
    and .last_delivery_trigger == "one-shot-usage"
    and .last_delivery_mode == "continue"
    and .recovery_count == 1
    and .continue_count == 1
  '
  capacity_scan "$capacity_fixture" capcoalesce "$capacity_viewport" "$coalesce_forecast" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/capacity-pending-clean"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" cappending continue
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" cappending "$capacity_viewport" >/dev/null
  local pending_state="$capacity_fixture/state/targets/cappending/keepalive.json"
  jq '.delivery_mode = "invalid"' "$pending_state" >"$capacity_fixture/pending-state.tmp"
  mv -f "$capacity_fixture/pending-state.tmp" "$pending_state"
  if capacity_scan "$capacity_fixture" cappending "$capacity_viewport" \
      >"$capacity_fixture/presend-failure.out" 2>"$capacity_fixture/presend-failure.err"; then
    fail "invalid delivery mode did not block the pre-Screen capacity recovery"
  fi
  assert_recovery_sequence "$capacity_fixture/events.log"
  assert_jq "$pending_state" '
    .capacity_state == "ready"
    and .capacity_stop_seen == true
    and .capacity_warning_latched == true
  '
  jq '.delivery_mode = "continue"' "$pending_state" >"$capacity_fixture/pending-state.tmp"
  mv -f "$capacity_fixture/pending-state.tmp" "$pending_state"
  printf '%s\n' 'Capacity warning was redrawn away.' >"$capacity_viewport"
  capacity_scan "$capacity_fixture" cappending "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_jq "$pending_state" '
    .capacity_state == "latched"
    and .capacity_stop_seen == false
    and .capacity_warning_latched == true
    and .last_delivery_trigger == "model-capacity"
  '
  capacity_scan "$capacity_fixture" cappending "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_jq "$pending_state" '
    .capacity_state == "armed"
    and .capacity_stop_seen == false
    and .capacity_warning_latched == false
  '
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/usage-both"
  capacity_viewport="$capacity_fixture/viewport.txt"
  local usage_both_forecast="$capacity_fixture/forecast.json"
  mkdir -p "$capacity_fixture"
  write_keepalive_forecast "$usage_both_forecast" false true 5 5
  capacity_register "$capacity_fixture" usageboth both "$usage_both_forecast"
  printf '%s\n' 'No model-capacity warning is visible.' >"$capacity_viewport"
  capacity_scan "$capacity_fixture" usageboth "$capacity_viewport" "$usage_both_forecast" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log"
  write_keepalive_forecast "$usage_both_forecast" true false 80 80
  capacity_scan "$capacity_fixture" usageboth "$capacity_viewport" "$usage_both_forecast" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" '/goal resume' Continue
  assert_message_submitted "$capacity_fixture/events.log" '/goal resume' 1
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/usage-degraded-capacity"
  capacity_viewport="$capacity_fixture/viewport.txt"
  local degraded_forecast="$capacity_fixture/forecast.json" degraded_status
  mkdir -p "$capacity_fixture"
  write_keepalive_forecast "$degraded_forecast" false true 5 5
  capacity_register "$capacity_fixture" usagedegraded continue "$degraded_forecast"
  printf '%s\n' 'No capacity warning.' >"$capacity_viewport"
  capacity_scan "$capacity_fixture" usagedegraded "$capacity_viewport" "$degraded_forecast" >/dev/null
  write_keepalive_forecast "$degraded_forecast" true false 80 80
  if CAPACITY_FAIL_HARDCOPY_CALL=2 \
      capacity_scan "$capacity_fixture" usagedegraded "$capacity_viewport" "$degraded_forecast" \
        >"$capacity_fixture/degraded.out" 2>"$capacity_fixture/degraded.err"; then
    fail "usage recovery hid degraded model-capacity monitoring"
  else
    degraded_status="$?"
  fi
  [[ "$degraded_status" == "70" ]] || \
    fail "usage recovery with degraded capacity monitoring exited $degraded_status, expected 70"
  assert_contains "$capacity_fixture/degraded.err" 'Model-capacity monitoring is degraded'
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"
  assert_hardcopy_modes "$capacity_fixture/hardcopy-modes.log"

  capacity_scan "$capacity_fixture" usagedegraded "$capacity_viewport" "$degraded_forecast" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1

  capacity_fixture="$dir/capacity-nonmatches"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capnonmatches continue
  local -a capacity_nonmatches=(
    "Notice: $capacity_banner"
    "$capacity_banner Additional detail."
    '⚠ Selected model is near capacity. Please try a different model.'
    'Selected model is at capacity. Please try a different model.'
  )
  local nonmatch
  for nonmatch in "${capacity_nonmatches[@]}"; do
    printf '%s\n' "$nonmatch" >"$capacity_viewport"
    capacity_scan "$capacity_fixture" capnonmatches "$capacity_viewport" >/dev/null
    capacity_scan "$capacity_fixture" capnonmatches "$capacity_viewport" >/dev/null
  done
  assert_recovery_sequence "$capacity_fixture/events.log"
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/capacity-snapshot-cleanup"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capcleanup continue
  install -d -m 700 "$capacity_fixture/snapshots"
  local stale_snapshot="$capacity_fixture/snapshots/capcleanup.screen-viewport.tmp.stale"
  printf '%s\n' "$capacity_banner" >"$stale_snapshot"
  chmod 600 "$stale_snapshot"
  printf '%s\n' 'Clean viewport.' >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capcleanup "$capacity_viewport" >/dev/null
  [[ ! -e "$stale_snapshot" ]] || fail "stale Screen snapshot survived the next capture"
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"
  assert_hardcopy_modes "$capacity_fixture/hardcopy-modes.log"

  stale_snapshot="$capacity_fixture/snapshots/capcleanup.screen-viewport.tmp.unregister"
  printf '%s\n' "$capacity_banner" >"$stale_snapshot"
  chmod 600 "$stale_snapshot"
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$capacity_fixture/state" \
    CODEX_USAGE_FORECAST_JSON="$capacity_fixture/missing-forecast.json" \
    _CODEX_KEEPALIVE_SNAPSHOT_DIR="$capacity_fixture/snapshots" \
    "$keepalive_script" unregister capcleanup >/dev/null
  [[ ! -e "$stale_snapshot" ]] || fail "target Screen snapshot survived unregister"
  [[ -f "$capacity_fixture/state/targets/capcleanup/screen.env" ]] || \
    fail "unregister removed the target's Screen configuration"

  capacity_fixture="$dir/capacity-capture-failure"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capcapture continue
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  if CAPACITY_FAIL_HARDCOPY_CALL=1 \
      capacity_scan "$capacity_fixture" capcapture "$capacity_viewport" \
        >"$capacity_fixture/failure.out" 2>"$capacity_fixture/failure.err"; then
    fail "capacity monitor ignored a failed Screen snapshot"
  fi
  assert_recovery_sequence "$capacity_fixture/events.log"
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_scan "$capacity_fixture" capcapture "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log"
  capacity_scan "$capacity_fixture" capcapture "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_fixture="$dir/capacity-state-failure"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capstate continue
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capstate "$capacity_viewport" >/dev/null
  if CAPACITY_MV_FAIL_PATTERN='.keepalive.json.tmp.' \
      capacity_scan "$capacity_fixture" capstate "$capacity_viewport" \
        >"$capacity_fixture/failure.out" 2>"$capacity_fixture/failure.err"; then
    fail "capacity monitor ignored a failed pre-send state commit"
  fi
  assert_recovery_sequence "$capacity_fixture/events.log"
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  capacity_scan "$capacity_fixture" capstate "$capacity_viewport" >/dev/null
  assert_recovery_sequence "$capacity_fixture/events.log" Continue
  assert_message_submitted "$capacity_fixture/events.log" Continue 1
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  local continue_failure_call expected_enters before_event_lines after_event_lines
  for continue_failure_call in 1 2; do
    capacity_fixture="$dir/capacity-continue-failure-$continue_failure_call"
    capacity_viewport="$capacity_fixture/viewport.txt"
    capacity_register "$capacity_fixture" "capcontinuefail$continue_failure_call" continue
    printf '%s\n' "$capacity_banner" >"$capacity_viewport"
    capacity_scan "$capacity_fixture" "capcontinuefail$continue_failure_call" "$capacity_viewport" >/dev/null
    if CAPACITY_FAIL_DELIVERY_CALL="$continue_failure_call" \
        capacity_scan "$capacity_fixture" "capcontinuefail$continue_failure_call" "$capacity_viewport" \
          >"$capacity_fixture/failure.out" 2>"$capacity_fixture/failure.err"; then
      fail "capacity Continue failure on delivery call $continue_failure_call was hidden"
    fi

    expected_enters=$((continue_failure_call - 1))
    assert_recovery_sequence "$capacity_fixture/events.log" Continue
    assert_line_count "$capacity_fixture/events.log" 'TEXT Continue' 1
    assert_line_count "$capacity_fixture/events.log" 'ENTER' "$expected_enters"
    assert_jq "$capacity_fixture/state/targets/capcontinuefail$continue_failure_call/keepalive.json" '
      .last_delivery_mode == "continue"
      and .last_delivery_trigger == "model-capacity"
      and .last_delivery_state == "uncertain"
      and .last_goal_delivery_state == "not-attempted"
      and .last_continue_delivery_state == "uncertain"
      and .last_reminder_delivery_state == "not-attempted"
      and .capacity_warning_latched == true
      and .capacity_stop_seen == false
      and .recovery_attempt_count == 1
      and .continue_attempt_count == 1
      and (.resume_attempt_count // 0) == 0
      and (.recovery_count // 0) == 0
      and (.continue_count // 0) == 0
    '
    before_event_lines="$(wc -l <"$capacity_fixture/events.log")"
    capacity_scan "$capacity_fixture" "capcontinuefail$continue_failure_call" "$capacity_viewport" >/dev/null
    after_event_lines="$(wc -l <"$capacity_fixture/events.log")"
    [[ "$after_event_lines" == "$before_event_lines" ]] || \
      fail "capacity Continue failure on call $continue_failure_call was retried automatically"
    assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"
  done

  capacity_fixture="$dir/capacity-both-continue-failure"
  capacity_viewport="$capacity_fixture/viewport.txt"
  capacity_register "$capacity_fixture" capbothfail both
  printf '%s\n' "$capacity_banner" >"$capacity_viewport"
  capacity_scan "$capacity_fixture" capbothfail "$capacity_viewport" >/dev/null
  if CAPACITY_FAIL_DELIVERY_CALL=4 \
      capacity_scan "$capacity_fixture" capbothfail "$capacity_viewport" \
        >"$capacity_fixture/failure.out" 2>"$capacity_fixture/failure.err"; then
    fail "both-mode Continue failure after /goal resume was hidden"
  fi
  assert_recovery_sequence "$capacity_fixture/events.log" '/goal resume' Continue
  assert_message_submitted "$capacity_fixture/events.log" '/goal resume' 1
  assert_message_submitted "$capacity_fixture/events.log" Continue 0
  assert_line_count "$capacity_fixture/events.log" 'ENTER' 2
  assert_not_contains "$capacity_fixture/events.log" 'TEXT Keepalive reminder:'
  assert_jq "$capacity_fixture/state/targets/capbothfail/keepalive.json" '
    .last_delivery_mode == "both"
    and .last_delivery_trigger == "model-capacity"
    and .last_delivery_state == "uncertain"
    and .last_goal_delivery_state == "submitted"
    and .last_continue_delivery_state == "uncertain"
    and .last_reminder_delivery_state == "not-attempted"
    and .capacity_warning_latched == true
    and .capacity_stop_seen == false
    and .recovery_attempt_count == 1
    and .resume_attempt_count == 1
    and .continue_attempt_count == 1
    and (.recovery_count // 0) == 0
    and .resume_count == 1
    and (.continue_count // 0) == 0
  '
  before_event_lines="$(wc -l <"$capacity_fixture/events.log")"
  capacity_scan "$capacity_fixture" capbothfail "$capacity_viewport" >/dev/null
  after_event_lines="$(wc -l <"$capacity_fixture/events.log")"
  [[ "$after_event_lines" == "$before_event_lines" ]] || \
    fail "both-mode partial delivery was retried automatically"
  assert_logged_paths_absent "$capacity_fixture/hardcopy-paths.log"

  export MOCK_SYSTEMCTL_LOG="$dir/systemctl.log"
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$state" \
    CODEX_USAGE_FORECAST_JSON="$forecast" \
    CODEX_KEEPALIVE_SYSTEMD_USER_DIR="$units" \
    "$keepalive_script" start >/dev/null
  assert_contains "$units/codex-keepalive.service" 'Wants=codex-usage-forecast.service'
  assert_not_contains "$units/codex-keepalive.service" 'Requires=codex-usage-forecast.service'
  assert_contains "$units/codex-keepalive.service" "ExecStart=:\"$keepalive_script\" send-if-ready"
  assert_mode "$units/codex-keepalive.service" 600
  PATH="$bin:$PATH" CODEX_KEEPALIVE_SYSTEMD_USER_DIR="$units" \
    MOCK_SYSTEMCTL_LOG="$dir/systemctl.log" "$keepalive_script" uninstall >/dev/null
  [[ ! -e "$units/codex-keepalive.service" ]] || fail "keepalive service survived uninstall"
  pass "keepalive recovers usage and stable capacity warnings, fails closed, and installs safely"
}

for command in bash curl jq flock stat grep find awk sha256sum install timeout; do
  command -v "$command" >/dev/null 2>&1 || fail "missing test dependency: $command"
done

echo "1..3"
test_api_helpers
test_forecast
test_keepalive
echo "All $tests_run isolated behavior tests passed."
