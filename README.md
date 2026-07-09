# Codex Skills Plugin

Personal Codex plugin containing skills for usage inspection, usage forecasting, reset-credit inspection, and goal keepalive automation.

## Install

From this private GitHub repo:

```bash
codex plugin marketplace add emilfihlman/codex-skills --ref main
codex plugin add codex-skills@emil-codex-skills
```

From a local checkout:

```bash
codex plugin marketplace add /path/to/codex-skills
codex plugin add codex-skills@emil-codex-skills
```

## Skills

- `codex-usage`: Query current Codex ChatGPT-plan usage windows.
- `codex-reset-credits`: Inspect available banked rate-limit reset credits.
- `codex-usage-forecast`: Poll usage and write forecast telemetry files.
- `codex-keepalive`: Keep GNU Screen-based Codex goals resumable across usage exhaustion.

## Layout

This repository is a Codex plugin marketplace:

- `.agents/plugins/marketplace.json`: marketplace entry for the plugin.
- `plugins/codex-skills/.codex-plugin/plugin.json`: plugin manifest.
- `plugins/codex-skills/skills/<skill-name>/`: bundled skills.

These skills call internal ChatGPT/Codex backend endpoints through the local Codex ChatGPT login. Treat endpoint failures as possible auth, rollout, or endpoint changes.
