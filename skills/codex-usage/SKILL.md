---
name: codex-usage
description: Query and summarize current Codex ChatGPT-plan usage windows, including the 5-hour primary window, weekly secondary window, reset timestamps, limit-reached status, credits, and available reset credits. Use when the user asks how much Codex usage is left, whether the 5h or weekly window is near the limit, when Codex usage resets, or wants current Codex rate-limit usage from the internal ChatGPT usage endpoint.
---

# Codex Usage

Use this skill to inspect current Codex rate-limit windows without redeeming reset credits. The bundled script reads the local Codex ChatGPT login, calls the internal ChatGPT usage endpoint, and summarizes the active primary and secondary windows.

## Workflow

1. Run `scripts/show-codex-usage.sh`.
2. If network access is blocked by sandboxing, rerun the same command with approval for network access.
3. Report the primary window as the 5-hour window and the secondary window as the weekly window.
4. Include used percent, approximate remaining percent, reset time, reset-after duration, limit-reached status, plan type, and available reset-credit count.
5. Do not print or expose access tokens, account IDs, user IDs, or email addresses.

## Script

- `scripts/show-codex-usage.sh`: queries `https://chatgpt.com/backend-api/wham/usage`.
- Safe modes:
  - default: human-readable summary
  - `--json`: redacted structured JSON containing only usage/credit fields
- Sensitive mode:
  - `--raw`: exact endpoint response. Use only when needed, because it may include account identifiers.

Optional environment variables:

- `CODEX_AUTH_FILE`: path to the Codex auth JSON file. Defaults to `~/.codex/auth.json`.
- `CODEX_USAGE_URL`: override endpoint URL if the internal endpoint changes.

This endpoint is internal and undocumented; treat failures as possible endpoint, auth, account, or rollout changes rather than user error.
