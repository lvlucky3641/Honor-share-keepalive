# Changelog

## 1.3.8 - 2026-11-26

- Dismisses only the `SuperNotificationToastDlg` window owned by `HnTrustCircleService` after a real discovery close event.
- Leaves HONOR notification settings and registry values unchanged.
- Uses an independent hidden launcher and exact process/class matching.
- Adds tests that close events request dismissal while intentional stop does not.

## 1.3.7 - 2026-11-26

- Changed recovery to enable discovery directly without relaunching the HONOR share UI.
- Added a guarded fallback to the previous publish-service restart only when direct discovery fails.
- Reduced the chance that the ten-minute HONOR timer triggers its own `honorshareRouter` popup.
- Added regression coverage for the no-UI recovery path and fallback path.

## 1.3.6 - 2026-11-26

- Reduced recurring HONOR close-popup notifications triggered by the ten-minute discovery event.
- Close notifications now query the real switch state before reopening it.
- When the switch is still ON, only the timer is refreshed and the HONOR share UI is not relaunched.
- Added tests for both spurious and confirmed-off close notifications.

## 1.3.5 - 2026-11-25

- Fixed repeated PowerShell terminal windows caused by the Windows 11 default terminal host.
- Launches the watchdog through a VBScript wrapper with window style `0`, matching the existing hidden worker launcher.
- Added a launch-mode regression test that requires `wscript.exe` and `watchdog-hidden.vbs`.

## 1.3.4 - 2026-11-25

- Fixed a watchdog restart loop when an older installation reclaimed the shared scheduled task.
- Detects keepalive workers and task actions from other installation paths and migrates them once to the current version.
- Self-check now reports when the scheduled task points to a different installation.
- Added regression coverage for cross-version task actions and worker migration.

## 1.3.3 - 2026-11-25

- Added an independent watchdog scheduled task that checks the main task and worker every minute.
- Automatically restarts the worker after HONOR WorkStation updates or unexpected process termination.
- Recreates a missing main task and repairs a stale `Running` task with no live worker.
- Added PowerShell tests for stopped, stale-running, healthy, duplicate, and missing-task states.
- Validated the existing IPC protocol against HONOR WorkStation `5.5.1.104(C233)`.

## 1.3.2 - 2026-11-25

- Added a reproducible Windows release-package build with an explicit file manifest and SHA-256 checksum.
- Added automated checks that keep the package version, changelog, launcher, source, and build script in sync.
- Added release packaging to the GitHub Actions verification workflow.

## 1.3.1 - 2026-11-25

- Moved the four direct command launchers into the `commands` subdirectory.
- Kept `Control.cmd` as the only user-facing launcher in the project root.

## 1.3.0 - 2026-11-25

- Added `Control.cmd`, a unified interactive control panel.
- The panel shows current status before prompting for actions 1-4.
- Each action reports success or failure and closes automatically after three seconds.
- Kept direct command entries for scripting and automation.

## 1.2.0 - 2026-11-25

- Added event-driven recovery for unexpected close, close-confirmation, and stop-publish notifications.
- Kept steady-state work at two lightweight IPC messages per minute.
- Added a sub-second recovery path without high-frequency polling.

## 1.1.0 - 2026-11-25

- Changed the recurring keepalive action to reset the temporary discoverability timer without turning discovery off.
- Removed the close/open behavior that could trigger a reminder popup or briefly hide the device.
- Reduced steady-state work to two lightweight IPC messages per minute.

## 1.0.0 - 2026-11-25

- Added minute-by-minute discoverability monitoring through native IPC.
- Added one-click start, stop, check, and uninstall scripts.
- Added scheduled-task login startup and single-instance protection.
- Added live health heartbeat and end-to-end self-check output.
- Added automated tests for protocol parsing, retry behavior, and health output.
