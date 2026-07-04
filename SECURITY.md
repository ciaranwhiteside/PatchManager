# Security Policy

PatchManager is a beta personal-device patching script. It runs elevated and
can install operating system, browser, Microsoft 365, WinGet, and Microsoft
Store updates. Review the script and run `-DryRun` before live use.

## Reporting a Vulnerability

Please open a private security advisory on GitHub if available. If not, open an
issue with enough detail to reproduce the problem, but do not include secrets,
hostnames, report files, logs, or other sensitive device data.

## Supported Versions

Only the latest `main` branch is supported during the beta period.

## Operational Guidance

- Do not publish generated `Logs`, `Reports`, `State`, or `Cache` directories.
- Do not publish a personal `PatchManager.config.json`.
- Use `PatchManager.config.example.json` as the public template.
- Run from an elevated PowerShell session.
- Start with `.\Invoke-PatchManager.ps1 -DryRun -Force`.
