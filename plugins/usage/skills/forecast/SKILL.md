---
name: forecast
description: Forecast when Codex ChatGPT-plan usage may run out by polling redacted usage data and writing readable telemetry files. Use when the user asks for usage-exhaustion predictions, a foreground poller, background forecast timer setup, or existing forecast state. Use $usage:check for a one-time current-usage check.
---

# Usage Forecast

Use this skill for prediction and telemetry. Do not add slowdown policies,
mandatory waits, subagent limits, or reset-credit redemption behavior unless
the user separately requests that judgment.

Require `$usage:check` alongside this skill unless `CODEX_USAGE_HELPER` points
to another compatible redacted JSON helper.

## Commands

- Update once: `scripts/usage-monitor.sh once`
- Poll in the foreground: `scripts/usage-monitor.sh watch`
- Install and enable the user-systemd timer: `scripts/usage-monitor.sh start`
- Show timer and file status: `scripts/usage-monitor.sh status`
- Disable the timer: `scripts/usage-monitor.sh stop`
- Disable the timer and remove its units: `scripts/usage-monitor.sh uninstall`

If network or state-directory writes are blocked, rerun the same command with
the required approval. `start` writes private unit files using the resolved
installed script path; run it again after moving or reinstalling the skill.

## Files and method

Write these private files under `~/.codex/usage/` by default:

- `codex-usage-forecast.md`: readable status.
- `codex-usage-forecast.json`: structured status for automation.
- `codex-usage-samples.jsonl`: bounded redacted sample history.

Compare recent samples from the same reset window and estimate a linear burn
rate. Report unknown rather than claiming an outcome when reset timing or
enough history is unavailable. Treat every prediction as rough telemetry.

For logged-out polling, explain that user lingering is a separate system-level
change and obtain confirmation before running `loginctl enable-linger`.
