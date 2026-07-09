---
name: codex-keepalive
description: Keep active Codex goals resumable across usage limits by persistently registering named GNU Screen targets and sending /goal resume after usage exhaustion clears, with one-shot resume queues as an explicit manual option. Use when the user asks to configure screen-based Codex resume targets, keep a goal alive until completion, inspect or clear keepalive registrations, tune one-shot queue thresholds, or run the keepalive systemd timer.
---

# Codex Keepalive

Use this skill only for screen-based `/goal resume` sending. Usage polling and prediction live in `$codex-forecast`; this skill reads that forecast and wakes existing interactive Codex sessions.

When this skill is used for an active Codex goal:

- Resolve the current target with `scripts/keepalive.sh current-target` when running inside GNU Screen. If that fails, use only a named target the user configured or explicitly provided.
- Register the goal once with `scripts/keepalive.sh register <target> "<objective and checkpoint context>"`.
- When the goal is reached, abandoned, or no longer needs automatic continuation, unregister it with `scripts/keepalive.sh unregister <target>`.
- Do not manually monitor usage for this skill. The systemd timer scans registrations once per minute.
- Do not add slowdown behavior, mandatory waits, fewer subagents, or other usage-conservation instructions. This skill only keeps the goal resumable after Codex usage exhaustion.
- Do not redeem reset credits. This skill queues `/goal resume`; reset-credit inspection/redemption belongs elsewhere.

## Files

The keepalive sender writes files under `~/.codex/keepalive/` by default:

- `targets/<name>/screen.env`: configured GNU Screen session/window for a named target.
- `targets/<name>/keepalive.json`: persistent keepalive registration for an active goal.
- `targets/<name>/keepalive.md`: readable registration summary.
- `targets/<name>/resume-request.md`: queued resume intent for that target.
- `targets/<name>/resume-sent-<timestamp>.md`: request moved here after a successful send.
- `targets/<name>/resume-<timestamp>.log`: send attempt log.

It reads forecast readiness from `~/.codex/usage/codex-usage-forecast.json`.

## Commands

- Configure a named target screen session:
  `scripts/keepalive.sh configure-screen <target> "screen-session-name" 0`
- Register or unregister an active goal:
  `scripts/keepalive.sh register <target> "objective and checkpoint context"`
  `scripts/keepalive.sh unregister <target>`
- Set or show target-specific one-shot queue thresholds:
  `scripts/keepalive.sh set-threshold <target> <percent>`
  `scripts/keepalive.sh set-weekly-threshold <target> <percent>`
  `scripts/keepalive.sh threshold [target]`
- Queue a one-shot resume for a target:
  `scripts/keepalive.sh queue <target> "objective or reminder"`
- Queue a one-shot resume from an active goal when usage is low:
  `scripts/keepalive.sh queue-if-needed <target> "objective and resume context"`
- Send if queued and forecast says usage is ready:
  `scripts/keepalive.sh send-if-ready [target]`
- Check state:
  `scripts/keepalive.sh status [target]`
- Resolve this session's target from GNU Screen:
  `scripts/keepalive.sh current-target`
- List targets:
  `scripts/keepalive.sh targets`
- Show queued requests:
  `scripts/keepalive.sh list`
- Clear a queued request:
  `scripts/keepalive.sh clear <target>`
- Remove a target:
  `scripts/keepalive.sh remove-target <target>`
- Start/stop the user systemd timer:
  `scripts/keepalive.sh start`
  `scripts/keepalive.sh stop`

## Behavior

The sender never infers a target. It requires an explicit screen configuration for each named target.

Persistent registrations are the normal path for active goals. The timer observes usage from `~/.codex/usage/codex-usage-forecast.json`. For each registered target it:

1. Stays armed while both windows have usable capacity.
2. Latches `stop_seen=true` after either the 5-hour or weekly window reaches `0%`, meaning Codex stopped because usage was exhausted.
3. Sends one `/goal resume` after both the 5-hour and weekly windows are above `0%` and the backend reports usage available.
4. Sends a short reminder prompt telling the resumed agent to unregister this target and mark the goal complete if the goal is already finished, or to do that when it later finishes.
5. Re-arms after sending, so the next exhaustion event can trigger another single resume.

Manual one-shot queue requests are still available. They are separate from persistent registrations and are useful for explicit one-time resume requests.

When ready, the helper sends terminal Enter, then:

```text

/goal resume
```

Then terminal Enter again. The implementation sends these as separate GNU Screen `stuff` calls using carriage return (`\015`) because Codex's TUI did not submit reliably when the whole sequence was stuffed as one payload. If no registration or request exists for a target, no screen target is configured, or usage is not available, it exits without sending. The timer scans all named targets once per minute.

After `/goal resume`, the helper also sends a reminder prompt with the exact `scripts/keepalive.sh unregister <target>` command. This is intentional recovery behavior: if Codex forgot to unregister before usage exhaustion, the next resume should refresh that obligation in context.

For logged-out operation, user lingering must be enabled with `loginctl enable-linger <user>`.

## Goal Guard Workflow

For long-running work where the user wants automatic continuation:

1. Identify the configured target, for example `authentication` or `tunnel`.
   Prefer `scripts/keepalive.sh current-target`, which matches `$STY` to the configured screen sessions.
2. Register the active goal:
   `scripts/keepalive.sh register <target> "Resume this goal: <objective>. Current state: <brief checkpoint>"`
3. Continue the work normally. Do not add usage-management behavior.
4. If the goal finishes, unregister before the final response:
   `scripts/keepalive.sh unregister <target>`
5. If the goal is still unfinished after being resumed, continue normally; the registration remains active until unregistered.
