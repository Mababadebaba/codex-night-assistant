# Changelog

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
