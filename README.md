# Codex Usage Skills

Codex skills for inspecting ChatGPT-plan usage, forecasting usage exhaustion,
checking banked reset credits, and recovering GNU Screen-backed work after
usage becomes available again or Codex reports model capacity.

## Important warning

These skills call undocumented ChatGPT/Codex backend endpoints with the local
Codex ChatGPT login. They can stop working when endpoint paths, response shapes,
or local authentication files change. The normal commands redact responses, but
`~/.codex/auth.json`, raw endpoint responses, forecast files, and keepalive goal
context are sensitive. Do not store secrets in keepalive objectives.

This is an unofficial Linux-oriented tool. It does not redeem reset credits.

## Requirements

| Capability | Requirements |
| --- | --- |
| Usage and reset-credit checks | Bash, `curl`, and `jq` |
| Forecast `once`/`watch` | Above plus GNU coreutils and `flock` |
| Forecast background timer | Linux user systemd |
| Keepalive | Bash, `jq`, GNU coreutils, `flock`, and GNU Screen; usage recovery also needs forecast telemetry |

Keepalive requires a dedicated GNU Screen window that continues to run Codex.
For timers that must run while logged out, enable user lingering separately with
`loginctl enable-linger "$USER"` after reviewing that system-level change.

## Plugin installation

The plugin is the recommended distribution. It provides the short names
`$usage:check`, `$usage:forecast`, `$usage:credits`, and `$usage:keepalive`.

```bash
codex plugin marketplace add emilfihlman/codex-skills
codex plugin add usage@emilfihlman
```

Both commands are required the first time. To pin a reviewed release or commit:

```bash
codex plugin marketplace add emilfihlman/codex-skills --ref <tag-or-commit>
codex plugin add usage@emilfihlman
```

For a local checkout:

```bash
codex plugin marketplace add /path/to/codex-skills
codex plugin add usage@emilfihlman
```

Start a new Codex thread after installation so the new skills are discovered.
Verify installation with `codex plugin list`, then try `$usage:check`.

### Plugin updates and removal

Before updating, explicitly ask the installed skills to remove any units that
point into the current plugin cache:

```text
$usage:keepalive stop and uninstall its generated timer units.
$usage:forecast stop and uninstall its generated timer units.
```

Then refresh the marketplace snapshot and reinstall the plugin:

```bash
codex plugin marketplace upgrade emilfihlman
codex plugin add usage@emilfihlman
```

Start a new thread, verify the updated plugin, and explicitly ask the new skill
versions to start forecast and keepalive again if wanted.

`marketplace upgrade` preserves a pinned tag or commit. To move a pinned
installation, remove the installed plugin and marketplace after uninstalling
its timer units, then add the marketplace again with the new `--ref` and
reinstall the plugin.

For removal, uninstall timer units through the skills first as above, then run:

```bash
codex plugin remove usage@emilfihlman
```

Forecast and keepalive state under `~/.codex/usage/` and
`~/.codex/keepalive/` is retained intentionally.

## Standalone installation

Use standalone skills only when you specifically want the names `$codex-usage`,
`$codex-forecast`, `$codex-credits`, and `$codex-keepalive`. Do not install the
standalone and plugin variants together; their implicit triggers overlap.

Codex discovers user skills under `~/.agents/skills`:

```bash
install -d "$HOME/.agents/skills"
cp -R skills/codex-usage skills/codex-forecast \
  skills/codex-credits skills/codex-keepalive \
  "$HOME/.agents/skills/"
```

Start a new thread and try `$codex-usage`. Install `codex-usage` alongside
`codex-forecast`, because the forecast monitor uses its redacted JSON helper.
Forecast helper discovery also honors `CODEX_HOME`; every script documents its
supported path override variables in `--help`.

To uninstall, first run the forecast and keepalive `uninstall` commands from
their installed script directories, then remove only these four skill folders:

```bash
"$HOME/.agents/skills/codex-keepalive/scripts/keepalive.sh" uninstall
"$HOME/.agents/skills/codex-forecast/scripts/usage-monitor.sh" uninstall
```

## Background automation

When usage-exhaustion recovery is wanted, run forecast setup before keepalive
setup. Capacity-only recovery does not require forecast telemetry:

```bash
skills/codex-forecast/scripts/usage-monitor.sh once
skills/codex-forecast/scripts/usage-monitor.sh start
skills/codex-keepalive/scripts/keepalive.sh start
```

For a plugin installation with usage recovery, ask `$usage:forecast` to run
`once` and `start`, then explicitly ask `$usage:keepalive` to run `start`.

`start` installs private user-systemd unit files from the running script's
resolved path and enables the timer. `stop` disables the timer but leaves its
unit files and state. `uninstall` disables the timer and removes its unit files,
while retaining telemetry and keepalive state.

The keepalive sender only targets explicitly configured GNU Screen sessions.
Register with `register <target> [--mode goal|continue|both] [objective]`;
`goal` is the default, `continue` sends the literal message `Continue`, and
`both` sends `/goal resume` followed by `Continue`. The selected mode applies
to both usage recovery and the exact stable warning
`⚠ Selected model is at capacity. Please try a different model.` Continue-only
registrations still use forecast telemetry for usage recovery, while model-
capacity monitoring is independent of forecast state.

Choose `--mode continue` for capacity-focused work that has no registered goal,
or `--mode both` when an active goal should also be resumed. Existing and
mode-less registrations retain the legacy `goal` behavior; re-register them to
change mode.

Capacity detection scans only private transient snapshots of the current
viewport, never Screen scrollback. It accepts the warning only within the last
eight nonblank viewport lines and only after two successful passes have the
same normalized full-viewport fingerprint; timer-driven passes are normally
one minute apart. Raw snapshots are removed immediately after inspection.
Task-owned remnants left by forced termination or power loss are removed on a
later capture or target cleanup. This text heuristic can miss a redrawn warning
or mistake identical visible content for the warning. Delivery is at-most-once
and re-arms only after a later clean viewport observation. Use a dedicated
Codex window, keep objectives terse and non-sensitive, and inspect generated
state before enabling unattended use.

## Repository layout

- `.agents/plugins/marketplace.json`: marketplace entry.
- `plugins/usage/.codex-plugin/plugin.json`: plugin manifest.
- `plugins/usage/skills/`: generated plugin skill variants.
- `skills/`: canonical standalone skill sources.
- `scripts/sync-variants.sh`: regenerate or verify plugin variants.
- `tests/run.sh`: isolated fixture tests with fake external commands.

## Checks

Run the batched repository checks before publishing or tagging:

```bash
scripts/check-package.sh
tests/run.sh
```
