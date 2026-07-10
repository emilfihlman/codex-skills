---
name: credits
description: Query and summarize banked ChatGPT/Codex rate-limit reset credits, including available count, grant status, reset type, and expiry. Use when the user asks how many reset credits exist or when they expire. Use $usage:check instead for current 5-hour or weekly usage windows. Never redeem a credit.
---

# Usage Credits

Inspect banked reset credits without redeeming them.

## Workflow

1. Run `scripts/show-reset-credits.sh`.
2. If the sandbox blocks network access, rerun the same command with approval.
3. Report available count, reset type, status, grant time, expiry time, and
   earliest expiry.
4. Use the default summary whenever possible. Treat `--json` and `--raw` as
   sensitive full-response modes; do not repeat access tokens, account IDs,
   user IDs, email addresses, or unrelated response fields.
5. Never redeem a reset credit.

The helper accepts `CODEX_AUTH_FILE` and `CODEX_RESET_CREDITS_URL`. It sends
Codex credentials only to the default ChatGPT HTTPS host unless
`CODEX_ALLOW_UNSAFE_ENDPOINT=1` is explicitly set for controlled testing.

Treat failures as possible internal-endpoint, authentication, account, or
rollout changes rather than user error.
