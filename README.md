# Codex Skills

Personal Codex skills for usage inspection, usage forecasting, reset-credit inspection, and goal keepalive automation.

## Skills

- `codex-usage`: Query current Codex ChatGPT-plan usage windows.
- `codex-reset-credits`: Inspect available banked rate-limit reset credits.
- `codex-usage-forecast`: Poll usage and write forecast telemetry files.
- `codex-keepalive`: Keep GNU Screen-based Codex goals resumable across usage exhaustion.

## Layout

Each skill lives under `skills/<skill-name>/` and is intended to be copied or installed into a Codex skills directory such as `~/.codex/skills/`.

These skills call internal ChatGPT/Codex backend endpoints through the local Codex ChatGPT login. Treat endpoint failures as possible auth, rollout, or endpoint changes.
