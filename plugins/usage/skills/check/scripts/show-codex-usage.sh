#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: show-codex-usage.sh [--json|--raw]

Queries current Codex usage windows using the local Codex ChatGPT login at
~/.codex/auth.json. Does not redeem reset credits.

Options:
  --json   Print redacted structured usage JSON.
  --raw    Print the raw endpoint response. May include account identifiers.
  -h, --help
          Show this help.

Environment:
  CODEX_AUTH_FILE   Override auth file path.
  CODEX_USAGE_URL   Override usage endpoint URL.
EOF
}

mode="summary"
case "${1:-}" in
  "" ) ;;
  --json ) mode="json" ;;
  --raw ) mode="raw" ;;
  -h|--help ) usage; exit 0 ;;
  * ) usage >&2; exit 2 ;;
esac

for dep in curl jq; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    echo "Missing required command: $dep" >&2
    exit 127
  fi
done

auth_file="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
endpoint="${CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"

if [[ ! -r "$auth_file" ]]; then
  echo "Cannot read Codex auth file: $auth_file" >&2
  exit 1
fi

access_token="$(jq -er '.tokens.access_token // .access_token // empty' "$auth_file")"
account_id="$(jq -er '.tokens.account_id // .account_id // empty' "$auth_file")"

if [[ -z "$access_token" || -z "$account_id" ]]; then
  echo "Codex auth file does not contain tokens.access_token and tokens.account_id." >&2
  exit 1
fi

response="$(
  curl -fsS "$endpoint" \
    -H "Authorization: Bearer $access_token" \
    -H "ChatGPT-Account-ID: $account_id" \
    -H "originator: Codex Desktop" \
    -H "Accept: application/json"
)"

redacted_filter='
  {
    plan_type,
    rate_limit_reached_type,
    rate_limit,
    additional_rate_limits,
    credits: (
      if .credits == null then null else {
        has_credits: .credits.has_credits,
        unlimited: .credits.unlimited,
        overage_limit_reached: .credits.overage_limit_reached,
        balance: .credits.balance,
        approx_local_messages: .credits.approx_local_messages,
        approx_cloud_messages: .credits.approx_cloud_messages
      } end
    ),
    rate_limit_reset_credits,
    code_review_rate_limit
  }
'

summary_filter='
  def duration:
    if . == null then
      "unknown"
    else
      (. | tonumber | floor) as $n |
      ($n / 86400 | floor) as $d |
      (($n % 86400) / 3600 | floor) as $h |
      (($n % 3600) / 60 | floor) as $m |
      if $d > 0 then "\($d)d \($h)h \($m)m"
      elif $h > 0 then "\($h)h \($m)m"
      else "\($m)m"
      end
    end;

  def epoch:
    if . == null then "unknown" else (. | tonumber | todateiso8601) end;

  def remaining($used):
    if $used == null then "unknown" else "\((100 - ($used | tonumber)))%" end;

  def value:
    if . == null then "unknown" else tostring end;

  def window($label; $w):
    "\($label): used=\($w.used_percent // "unknown")% remaining=\(remaining($w.used_percent)) window=\(($w.limit_window_seconds // null) | duration) resets_at=\(($w.reset_at // null) | epoch) reset_after=\(($w.reset_after_seconds // null) | duration)";

  "Plan: \(.plan_type // "unknown")",
  "Allowed: \(.rate_limit.allowed | value)",
  "Limit reached: \(.rate_limit.limit_reached | value)",
  "Rate-limit reached type: \(.rate_limit_reached_type // "none")",
  window("5h window"; .rate_limit.primary_window // {}),
  window("Weekly window"; .rate_limit.secondary_window // {}),
  "Reset credits available: \(.rate_limit_reset_credits.available_count // "unknown")",
  "Usage credits balance: \(.credits.balance // "unknown")",
  (
    if ((.additional_rate_limits // []) | length) > 0 then
      "",
      "Additional rate limits:",
      (.additional_rate_limits[] |
        "  \(.limit_name // .metered_feature // "unnamed"): " +
        window("primary"; .rate_limit.primary_window // {}) + "; " +
        window("secondary"; .rate_limit.secondary_window // {})
      )
    else
      empty
    end
  )
'

case "$mode" in
  raw)
    printf '%s\n' "$response"
    ;;
  json)
    jq "$redacted_filter" <<<"$response"
    ;;
  summary)
    jq -r "$summary_filter" <<<"$response"
    ;;
esac
