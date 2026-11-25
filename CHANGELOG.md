# Changelog

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
