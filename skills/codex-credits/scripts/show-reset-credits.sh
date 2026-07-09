#!/usr/bin/env bash
set -euo pipefail

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
  CODEX_AUTH_FILE           Override auth file path.
  CODEX_RESET_CREDITS_URL   Override endpoint URL.
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
endpoint="${CODEX_RESET_CREDITS_URL:-https://chatgpt.com/backend-api/wham/rate-limit-reset-credits}"

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
