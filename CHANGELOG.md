# Changelog

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
