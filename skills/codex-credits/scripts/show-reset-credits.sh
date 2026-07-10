#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: show-reset-credits.sh [--json|--raw]

Queries ChatGPT/Codex banked rate-limit reset credits using the local Codex
ChatGPT login at ~/.codex/auth.json. Does not redeem any reset credits.

Options:
  --json   Pretty-print the full JSON response with jq.
  --raw    Print the raw endpoint response.
  -h, --help
          Show this help.

Environment:
  CODEX_AUTH_FILE              Override auth file path.
  CODEX_RESET_CREDITS_URL      Override endpoint URL. HTTPS requests to
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

request_credits() {
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
endpoint="${CODEX_RESET_CREDITS_URL:-https://chatgpt.com/backend-api/wham/rate-limit-reset-credits}"

validate_endpoint CODEX_RESET_CREDITS_URL "$endpoint"

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

response="$(request_credits)"

case "$mode" in
  raw)
    printf '%s\n' "$response"
    ;;
  json)
    jq . <<<"$response"
    ;;
  summary)
    jq -r '
      def epoch:
        sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
      def days_left:
        if .expires_at then
          (((.expires_at | epoch) - now) / 86400 | floor | tostring)
        else
          "unknown"
        end;

      "Available reset credits: \(.available_count // ((.credits // []) | map(select(.status == "available")) | length))",
      "Total earned count: \(.total_earned_count // "unknown")",
      "",
      (
        if ((.credits // []) | length) == 0 then
          "No reset credits returned."
        else
          "Credits sorted by expiry (UTC):",
          ((.credits // []) | sort_by(.expires_at // "")[] |
            [
              ("status=" + (.status // "unknown")),
              ("title=" + (.title // "untitled")),
              ("reset_type=" + (.reset_type // "unknown")),
              ("granted=" + (.granted_at // "unknown")),
              ("expires=" + (.expires_at // "unknown")),
              ("days_left=" + days_left),
              ("redeemed_at=" + (.redeemed_at // "null"))
            ] | @tsv
          ),
          "",
          ("Earliest available expiry: " + (
            [(.credits // [])[] | select(.status == "available") | .expires_at]
            | sort
            | first
            // "none"
          ))
        end
      )
    ' <<<"$response"
    ;;
esac
