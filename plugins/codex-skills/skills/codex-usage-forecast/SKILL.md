---
name: codex-usage-forecast
description: Forecast when Codex ChatGPT-plan usage may run out by polling backend usage from the codex-usage helper and writing readable forecast files. Use when the user asks to predict 5-hour or weekly Codex exhaustion, run a minute-by-minute usage monitor, read usage forecast state, or inspect forecast telemetry for other automation.
---

# Codex Usage Forecast

Use this skill for forecasting and telemetry only. Keep simple current usage checks in `$codex-usage`; use this skill when prediction, polling, or forecast files are needed. Do not use this skill to add slowdown behavior, work-style policy, mandatory waits, subagent limits, or conservation instructions unless the user explicitly asks for that separate judgment.

## Files

The monitor writes these files under `~/.codex/usage/` by default:

- `codex-usage-forecast.md`: human-readable status for Codex sessions.
- `codex-usage-forecast.json`: structured status for scripts.
- `codex-usage-samples.jsonl`: one backend usage sample per line.

## Commands

- Query once and update forecast files:
  `scripts/usage-monitor.sh once`
- Start one-minute background polling through a user systemd timer:
  `scripts/usage-monitor.sh start`
- Check poller status:
  `scripts/usage-monitor.sh status`
- Stop the poller:
  `scripts/usage-monitor.sh stop`

If network or `~/.codex` writes are blocked by sandboxing, rerun the same command with approval. The poller uses the existing `~/.codex/skills/codex-usage/scripts/show-codex-usage.sh --json` helper, so it does not print access tokens or account identifiers.

The systemd files live at:

- `~/.config/systemd/user/codex-usage-forecast.service`
- `~/.config/systemd/user/codex-usage-forecast.timer`

For logged-out polling, user lingering must be enabled with `loginctl enable-linger <user>`.

## Forecast Method

The forecast is intentionally simple:

1. Query backend usage.
2. Append a redacted sample to JSONL history.
3. Compare recent samples in the same reset window.
4. Estimate burn rate as percent per hour.
5. Estimate exhaustion time if usage is rising.
6. Mark whether exhaustion is predicted before the reset time.

Treat predictions as rough telemetry. If there are fewer than two samples in the current reset window, report that more samples are needed. When another skill such as `$codex-keepalive` consumes the forecast, let that skill decide its own action policy.
