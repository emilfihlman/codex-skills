#!/usr/bin/env bash
set -euo pipefail
umask 077

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
  CODEX_AUTH_FILE              Override auth file path.
  CODEX_USAGE_URL              Override usage endpoint URL. HTTPS requests to
                               chatgpt.com are allowed by default.
  CODEX_ALLOW_UNSAFE_ENDPOINT  Set to 1 to allow a non-ChatGPT HTTP(S) URL for
                               local testing. Credentials are sent to that URL.
EOF
}

validate_endpoint() {
  local endpoint_name="$1"
  local url="$2"
  local unsafe="${CODEX_ALLOW_UNSAFE_ENDPOINT:-0}"

  case "$unsafe" in
    0|1) ;;
    *)
      echo "CODEX_ALLOW_UNSAFE_ENDPOINT must be 0 or 1." >&2
      exit 2
      ;;
  esac

  if [[ "$url" == "https://chatgpt.com" || "$url" == https://chatgpt.com/* ]]; then
    return
  fi

  if [[ "$unsafe" == "1" && "$url" =~ ^https?://[^/?#[:space:]]+([/?#].*)?$ ]]; then
    echo "Warning: $endpoint_name points outside https://chatgpt.com; credentials will be sent to $url." >&2
    return
  fi

  echo "$endpoint_name must use https://chatgpt.com." >&2
  echo "For an intentional local test endpoint, set CODEX_ALLOW_UNSAFE_ENDPOINT=1 and use an HTTP(S) URL." >&2
  exit 2
}

curl_config_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

request_usage() {
  local token_config account_config
  token_config="$(curl_config_escape "$access_token")"
  account_config="$(curl_config_escape "$account_id")"

  # Read sensitive headers from curl's standard input so they are not exposed
  # in the curl process argument list.
  {
    printf 'header = "Authorization: Bearer %s"\n' "$token_config"
    printf 'header = "ChatGPT-Account-ID: %s"\n' "$account_config"
    printf 'header = "originator: Codex Desktop"\n'
    printf 'header = "Accept: application/json"\n'
  } | curl -fsS \
    --config - \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 2 \
    --retry-delay 1 \
    --retry-max-time 45 \
    -- "$endpoint"
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

validate_endpoint CODEX_USAGE_URL "$endpoint"

if [[ ! -r "$auth_file" ]]; then
  echo "Cannot read Codex auth file: $auth_file" >&2
  exit 1
fi

if ! jq -e 'type == "object"' "$auth_file" >/dev/null 2>&1; then
  echo "Codex auth file is not valid JSON object: $auth_file" >&2
  exit 1
fi

if ! access_token="$(jq -er '(.tokens.access_token // .access_token) | select(type == "string" and length > 0)' "$auth_file")"; then
  echo "Codex auth file is missing a non-empty access token: $auth_file" >&2
  exit 1
fi

if ! account_id="$(jq -er '(.tokens.account_id // .account_id) | select(type == "string" and length > 0)' "$auth_file")"; then
  echo "Codex auth file is missing a non-empty account ID: $auth_file" >&2
  exit 1
fi

if [[ "$access_token" == *$'\n'* || "$access_token" == *$'\r'* ||
      "$account_id" == *$'\n'* || "$account_id" == *$'\r'* ]]; then
  echo "Codex auth credentials must not contain line breaks: $auth_file" >&2
  exit 1
fi

response="$(request_usage)"

redacted_filter='
  def compact_window:
    if . == null then null else {
      used_percent,
      limit_window_seconds,
      reset_after_seconds,
      reset_at
    } end;

  def compact_rate:
    if . == null then null else {
      allowed,
      limit_reached,
      primary_window: (.primary_window | compact_window),
      secondary_window: (.secondary_window | compact_window)
    } end;

  {
    plan_type,
    rate_limit_reached_type,
    rate_limit: (.rate_limit | compact_rate),
    additional_rate_limits: [
      (.additional_rate_limits // [])[] | {
        limit_name,
        metered_feature,
        rate_limit: (.rate_limit | compact_rate)
      }
    ],
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
    rate_limit_reset_credits: (
      if .rate_limit_reset_credits == null then null else {
        available_count: .rate_limit_reset_credits.available_count,
        total_earned_count: .rate_limit_reset_credits.total_earned_count
      } end
    ),
    code_review_rate_limit: (.code_review_rate_limit | compact_rate)
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
