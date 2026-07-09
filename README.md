# Codex Usage Skills

Personal Codex skills for usage inspection, usage forecasting, reset-credit inspection, and goal keepalive automation.

## Warning

These skills call internal ChatGPT/Codex backend endpoints through the local Codex ChatGPT login. They may stop working if those internal endpoints, response shapes, or local authentication files change. The scripts avoid printing access tokens, but treat `~/.codex/auth.json` and raw endpoint responses as sensitive.

## Plugin Install

Install the bundled plugin when you want short names:

```bash
codex plugin marketplace add emilfihlman/codex-skills
codex plugin add usage@emilfihlman
```

Both commands are needed the first time. `codex plugin marketplace add` registers this repository as a marketplace source, and `codex plugin add` installs the `usage` plugin from that marketplace. The marketplace command also accepts an optional `--ref <branch-or-tag>` if you want to pin a specific branch, tag, or commit; omit it to use the repository default branch.

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

## Checks

Run the package check before publishing or tagging:

```bash
scripts/check-package.sh
```
