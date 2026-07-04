# Security Policy

PatchManager is a patching tool for personal and commercial Windows 10/11
devices. It runs elevated and can install operating system, browser, Microsoft
365, WinGet, and Microsoft Store updates. Review the script and run `-DryRun`
before live use.

## Supported Versions

| Version | Supported |
|---|---|
| 1.0.x (public beta) | ✅ |
| Pre-1.0 internal builds | ❌ — upgrade to 1.0.0 |

Only the latest release on `main` receives fixes during the beta period.

## Reporting a Vulnerability

Please open a **private security advisory** on GitHub
(*Security → Advisories → Report a vulnerability*). If that is unavailable,
open an issue with enough detail to reproduce the problem, but **do not**
include secrets, hostnames, report files, logs, or other sensitive device
data.

You can expect an acknowledgement within a week during the beta period.

## Deployment Hardening

- **Script location matters.** The scheduled task runs the script elevated
  with `-ExecutionPolicy Bypass`. Keep `Invoke-PatchManager.ps1` (and its
  config) in an **admin-only-writable** directory such as
  `C:\ProgramData\PatchManager\` — never under a user profile, where any
  process running as that user could replace the file and gain SYSTEM/admin at
  next logon. `-InstallStartupTask` warns when the path looks user-writable.
- **Protect the central shares.** `CentralReportPath`/`CentralLogPath` receive
  hostnames, software inventories, and patch posture for every device — treat
  the share as sensitive: write access for devices, read access only for the
  people who need it.
- **Webhook URLs are credentials.** An incoming-webhook URL in
  `PatchManager.config.json` lets anyone who reads it post to your channel.
  Restrict read access to the config file accordingly.
- Machine-wide changes (the BITS bandwidth policy) are snapshotted and
  restored on exit, including crash paths.

## Operational Guidance

- Do not publish generated `Logs`, `Reports`, `State`, or `Cache` directories.
- Do not publish a personal `PatchManager.config.json`.
- Use `PatchManager.config.example.json` as the public template.
- Run from an elevated PowerShell session.
- Start with `.\Invoke-PatchManager.ps1 -DryRun -Force`.
