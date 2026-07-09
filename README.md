# Codex Usage Skills

Personal Codex skills for usage inspection, usage forecasting, reset-credit inspection, and goal keepalive automation.

## Plugin Install

Install the bundled plugin when you want short names:

```bash
codex plugin marketplace add emilfihlman/codex-skills --ref main
codex plugin add usage@emilfihlman
```

Local checkout install:

```bash
codex plugin marketplace add /path/to/codex-skills
codex plugin add usage@emilfihlman
```

Plugin skills:

- `$usage:check`: Query current Codex ChatGPT-plan usage windows.
- `$usage:forecast`: Poll usage and write forecast telemetry files.
- `$usage:credits`: Inspect available banked rate-limit reset credits.
- `$usage:keepalive`: Keep GNU Screen-based Codex goals resumable across usage exhaustion.

## Standalone Skill Install

Install or copy the top-level `skills/` directories when you want normal standalone skill names:

- `skills/codex-usage` -> `$codex-usage`
- `skills/codex-forecast` -> `$codex-forecast`
- `skills/codex-credits` -> `$codex-credits`
- `skills/codex-keepalive` -> `$codex-keepalive`

## Skills

- `codex-usage` / `usage:check`: Query current Codex ChatGPT-plan usage windows.
- `codex-forecast` / `usage:forecast`: Poll usage and write forecast telemetry files.
- `codex-credits` / `usage:credits`: Inspect available banked rate-limit reset credits.
- `codex-keepalive` / `usage:keepalive`: Keep GNU Screen-based Codex goals resumable across usage exhaustion.

## Layout

This repository is a Codex plugin marketplace:

- `.agents/plugins/marketplace.json`: marketplace entry for the plugin.
- `plugins/usage/.codex-plugin/plugin.json`: plugin manifest.
- `plugins/usage/skills/<skill-name>/`: plugin-bundled skills.
- `skills/<skill-name>/`: standalone skill copies.

These skills call internal ChatGPT/Codex backend endpoints through the local Codex ChatGPT login. Treat endpoint failures as possible auth, rollout, or endpoint changes.
