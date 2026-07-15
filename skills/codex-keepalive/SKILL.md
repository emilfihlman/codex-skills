---
name: codex-keepalive
description: Manage explicit GNU Screen targets that recover registered Codex work after usage exhaustion clears or the exact model-capacity warning appears. Supports goal resume, literal Continue, or both. Use only when the user explicitly requests this screen-based automation or asks to inspect, configure, register, unregister, start, stop, or remove its state. Do not use for generic process keepalive or unrelated long-running work.
---

# Codex Keepalive

Manage GNU Screen-based recovery delivery. Use `$codex-forecast` for usage
polling and prediction; model-capacity monitoring is independent of forecast
readiness.

## Route the request

- For inspection, run only `status`, `list`, `targets`, `threshold`, or
  `current-target`. Do not register, queue, configure, start, stop, or remove
  anything during a read-only request.
- For mutation, run only the operation the user explicitly requested.
- For an explicitly requested recovery guard, resolve the current target,
  configure it if necessary, then register once with terse, non-sensitive
  objective and checkpoint context.

## Active-goal workflow

1. Resolve the target with `scripts/keepalive.sh current-target` inside GNU
   Screen. Otherwise use only a target the user explicitly supplied.
2. Register with
   `scripts/keepalive.sh register <target> [--mode goal|continue|both] "objective and checkpoint"`.
3. Continue work normally without usage-conservation behavior.
4. Unregister before the final response when the work finishes or automatic
   continuation is no longer wanted:
   `scripts/keepalive.sh unregister <target>`.

The registration mode controls recovery for both usage and model-capacity
events:

- `goal` (default) sends `/goal resume`.
- `continue` sends the literal message `Continue`.
- `both` sends `/goal resume` and then `Continue`.

Choose `continue` for capacity-focused work without a registered goal. Choose
`both` when an active goal and the interrupted turn should both be resumed.
Existing and mode-less registrations retain the legacy `goal` behavior, so
re-register a target when its mode needs to change.

For usage recovery, every mode still waits until fresh telemetry reports both
windows above 0% remaining and backend usage available. Model-capacity recovery
instead watches for the stable exact warning
`⚠ Selected model is at capacity. Please try a different model.` and does not
depend on forecast state. It never redeems reset credits.

## Setup and commands

Start `$codex-forecast` first when usage-exhaustion recovery is wanted. It is
not required for capacity-only recovery. Then use:

- Configure Screen: `scripts/keepalive.sh configure-screen <target> <session> [window]`
- Register/unregister:
  `scripts/keepalive.sh register <target> [--mode goal|continue|both] [objective]`
  and `scripts/keepalive.sh unregister <target>`
- Inspect: `scripts/keepalive.sh status [target]` or `scripts/keepalive.sh list`
- Install and enable timer: `scripts/keepalive.sh start`
- Disable timer: `scripts/keepalive.sh stop`
- Disable timer and remove units: `scripts/keepalive.sh uninstall`

Use `scripts/keepalive.sh --help` for one-shot queue and threshold commands.

Keep a dedicated Screen window running Codex. Capacity detection is a terminal
text heuristic: the helper scans only a private transient snapshot of the
current viewport, never Screen scrollback. It recognizes the exact warning only
within the last eight nonblank lines and confirms a stop only after two
successful passes have the same normalized full-viewport fingerprint. Timer-
driven passes are normally one minute apart. Raw snapshots are removed after
inspection; task-owned remnants from forced termination or power loss are
removed on a later capture or target cleanup. The exact warning can still be
missed after a redraw or mistaken for identical text shown as ordinary content.
Delivery is at-most-once; ambiguous attempts are not retried, and capacity
detection re-arms only after a later successful snapshot where the warning is
absent.

Store no secrets in objectives or state. `start` installs private user units
from the resolved script path, so run it again after moving or reinstalling the
skill.

For logged-out operation, explain that user lingering is a separate
system-level change and obtain confirmation before running
`loginctl enable-linger`.
