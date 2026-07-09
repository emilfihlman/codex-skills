---
name: credits
description: Query and summarize ChatGPT/Codex banked rate-limit reset credits from the local Codex ChatGPT login. Use when the user asks to check Codex usage reset tokens, reset-credit expiry times, available Codex rate-limit resets, or the internal reset-credit metadata without redeeming a token.
---

# Usage Credits

Use this skill to inspect banked Codex rate-limit reset credits without redeeming them. The bundled script reads the local Codex auth cache, calls the ChatGPT reset-credit endpoint, and summarizes availability and expiry.

## Workflow

1. Run `scripts/show-reset-credits.sh` from this skill directory.
2. If network access is blocked by sandboxing, rerun the same script with approval for network access.
3. Report the available count, title/reset type, status, grant time, expiry time, and earliest expiry. Do not print or expose access tokens.
4. If the user needs the complete endpoint response, run the script with `--json`. Use `--raw` only when exact unformatted JSON is needed.

## Script

- `scripts/show-reset-credits.sh`: uses `curl` and `jq` to query `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits`.
- Optional environment variables:
  - `CODEX_AUTH_FILE`: path to the Codex auth JSON file. Defaults to `~/.codex/auth.json`.
  - `CODEX_RESET_CREDITS_URL`: override endpoint URL if the internal endpoint changes.

This endpoint is internal and undocumented; treat failures as possible endpoint, auth, account, or rollout changes rather than user error.
