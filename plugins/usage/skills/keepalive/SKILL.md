---
name: keepalive
description: Manage explicit GNU Screen targets that resume registered Codex goals after usage exhaustion is observed and fresh telemetry later shows capacity available. Use only when the user explicitly requests this screen-based automation or asks to inspect, configure, register, unregister, start, stop, or remove its state. Do not use for generic process keepalive or unrelated long-running work.
---

# Usage Keepalive

Manage GNU Screen-based `/goal resume` delivery. Use `$usage:forecast` for usage
polling and prediction.

## Route the request

- For inspection, run only `status`, `list`, `targets`, `threshold`, or
  `current-target`. Do not register, queue, configure, start, stop, or remove
  anything during a read-only request.
- For mutation, run only the operation the user explicitly requested.
- For an explicitly requested active-goal guard, resolve the current target,
  configure it if necessary, then register once with terse, non-sensitive
  objective and checkpoint context.

## Active-goal workflow

1. Resolve the target with `scripts/keepalive.sh current-target` inside GNU
   Screen. Otherwise use only a target the user explicitly supplied.
2. Register with
   `scripts/keepalive.sh register <target> "objective and checkpoint"`.
3. Continue work normally without usage-conservation behavior.
4. Unregister before the final response when the goal finishes or automatic
   continuation is no longer wanted:
   `scripts/keepalive.sh unregister <target>`.

The persistent sender arms after a usage window is observed with 0% remaining
capacity or the backend reports usage blocked. It sends once after fresh
telemetry reports both windows above 0% remaining and backend usage available,
then re-arms for a later exhaustion event. It never redeems reset credits.

## Setup and commands

Start `$usage:forecast` first, then use:

- Configure Screen: `scripts/keepalive.sh configure-screen <target> <session> [window]`
- Register/unregister: `scripts/keepalive.sh register <target> [objective]` and
  `scripts/keepalive.sh unregister <target>`
- Inspect: `scripts/keepalive.sh status [target]` or `scripts/keepalive.sh list`
- Install and enable timer: `scripts/keepalive.sh start`
- Disable timer: `scripts/keepalive.sh stop`
- Disable timer and remove units: `scripts/keepalive.sh uninstall`

Use `scripts/keepalive.sh --help` for one-shot queue and threshold commands.

Keep a dedicated Screen window running Codex. Terminal injection cannot be
perfectly transactional; the helper prefers an uncertain at-most-once outcome
over automatically sending a duplicate command. Store no secrets in objectives
or state. `start` installs private user units from the resolved script path, so
run it again after moving or reinstalling the skill.

For logged-out operation, explain that user lingering is a separate
system-level change and obtain confirmation before running
`loginctl enable-linger`.
