# Changelog

## 0.1.5

- Fixed unattended shutdown failing after Windows locked the session or entered Modern Standby. Confirmed shutdown now uses the force option required by Windows when the machine is locked.
- Added shutdown exit-code handling in the UI status so command failures are visible instead of looking like a monitor-state issue.
- Updated the shutdown test wording and behavior to exercise the same lock-screen-capable shutdown path.

## 0.1.4

- Fixed stale monitor status being shown after the hidden background monitor process had already stopped.
- Split task progress into task state and task details so active turn/call/process counts are no longer clipped in the UI.
- Normalized the displayed decision against the live active-task counters to avoid contradictory text.

## 0.1.3

- Fixed missed active-task detection when a Codex turn is reasoning or newly restarted before any tool call appears.
- Added active turn tracking from recent incomplete Codex turns, while still clearing immediately on `task_complete`.
- Stabilized quota display by using the newest local `token_count` event instead of letting older session logs overwrite newer values.
- Hardened JSONL tail reading for UTF-8 BOM-prefixed lines.

## 0.1.2

- Fixed false active-task detection after Codex work finished by separating active tool calls/processes from recent session traces.
- Recent session count is now informational and no longer blocks the idle shutdown flow.
- Fixed rate-limit handling so any exhausted quota bucket, or any explicit Codex rate-limit block signal, is treated as quota exhaustion.
- Updated live status wording to show active calls, active processes, recent sessions, quota state, and the current shutdown decision more clearly.
- Cleared stale monitor status when monitoring is stopped so old results are not shown as live progress.

## 0.1.1

- Fixed shutdown gating so rate-limit exhaustion alone no longer triggers shutdown while Codex tasks are still active.
- Added live monitor status for active turns, pending tool calls, active processes, and rate-limit progress.
- Replaced slow log tail reading with a bounded fast tail reader for large Codex session logs.
- Removed all direct shutdown calls from the hidden background monitor; shutdown now requires the main UI confirmation dialog.
- Enforced the configured continuous idle threshold even when a rate limit is detected.
- Added a confirmation countdown: No cancels automatic shutdown, and no response shuts down only after the countdown.

## 0.1.0

- Initial open-source release.
- Windows keep-awake helper for long Codex sessions.
- Global Codex idle monitor based on local session logs and Codex-launched process checks.
- Hidden launcher to avoid visible PowerShell console windows.
- Desktop shortcut installer.
- Manual 60-second shutdown test and cancellation support.
