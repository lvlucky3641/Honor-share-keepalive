# Security

## Scope

This project uses undocumented local IPC methods exposed by HONOR WorkStation. It does not send data over the network and does not contain HONOR proprietary binaries.

The background worker keeps the local device discoverable to nearby sending devices. This naturally increases local discovery exposure. Use `Stop.cmd` or `Uninstall.cmd` when this behavior is not wanted.

## Reporting

Please report vulnerabilities privately to the repository maintainers before opening a public issue. Include the Windows version, HONOR PC Manager version, HONOR WorkStation version, reproduction steps, and relevant sanitized log lines.
