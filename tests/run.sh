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

  cat >"$bin/screen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [[ -f "$MOCK_SCREEN_COUNT" ]]; then
  count="$(<"$MOCK_SCREEN_COUNT")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$MOCK_SCREEN_COUNT"
printf '%s\n' "$*" >>"$MOCK_SCREEN_LOG"
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
  PATH="$bin:$PATH" CODEX_KEEPALIVE_STATE_DIR="$storage_state" CODEX_USAGE_FORECAST_JSON="$storage_forecast" \
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
  [[ ! -e "$storage_screen_log" ]] || fail "storage failure touched Screen"
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

  export MOCK_SYSTEMCTL_LOG="$dir/systemctl.log"
  PATH="$bin:$PATH" \
    CODEX_KEEPALIVE_STATE_DIR="$state" \
    CODEX_USAGE_FORECAST_JSON="$forecast" \
    CODEX_KEEPALIVE_SYSTEMD_USER_DIR="$units" \
    "$keepalive_script" start >/dev/null
  assert_contains "$units/codex-keepalive.service" 'Requires=codex-usage-forecast.service'
  assert_contains "$units/codex-keepalive.service" "ExecStart=:\"$keepalive_script\" send-if-ready"
  assert_mode "$units/codex-keepalive.service" 600
  PATH="$bin:$PATH" CODEX_KEEPALIVE_SYSTEMD_USER_DIR="$units" \
    MOCK_SYSTEMCTL_LOG="$dir/systemctl.log" "$keepalive_script" uninstall >/dev/null
  [[ ! -e "$units/codex-keepalive.service" ]] || fail "keepalive service survived uninstall"
  pass "keepalive fails closed, reports delivery errors, remains at-most-once, and installs safely"
}

for command in bash curl jq flock stat grep find; do
  command -v "$command" >/dev/null 2>&1 || fail "missing test dependency: $command"
done

echo "1..3"
test_api_helpers
test_forecast
test_keepalive
echo "All $tests_run isolated behavior tests passed."
