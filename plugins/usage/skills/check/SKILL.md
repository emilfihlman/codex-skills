---
name: check
description: Query and summarize current Codex ChatGPT-plan usage windows, including used and remaining percentages, reset times, limit status, plan type, and usage-credit balance. Use when the user asks how much 5-hour or weekly Codex usage remains, whether a usage limit is near, or when a usage window resets. Use $usage:credits instead for banked reset-credit grants and expiry details.
---

# Usage Check

Inspect current Codex rate-limit windows without redeeming reset credits.

## Workflow

1. Run `scripts/show-codex-usage.sh`.
2. If the sandbox blocks network access, rerun the same command with approval.
3. Report the primary 5-hour and secondary weekly windows, including used and
   remaining percentages, reset time, limit status, plan type, and usage-credit
   balance.
4. Route questions about banked reset-credit grants or expiry to
   `$usage:credits`.
5. Never print access tokens, account IDs, user IDs, or email addresses.

## Script modes

- Default: print a human-readable redacted summary.
- `--json`: print redacted structured usage fields.
- `--raw`: print the exact endpoint response. Use only when necessary and do
  not repeat identifiers or other sensitive fields in the response.

The helper accepts `CODEX_AUTH_FILE` and `CODEX_USAGE_URL`. It sends Codex
credentials only to the default ChatGPT HTTPS host unless
`CODEX_ALLOW_UNSAFE_ENDPOINT=1` is explicitly set for controlled testing.

Treat failures as possible internal-endpoint, authentication, account, or
rollout changes rather than user error.
