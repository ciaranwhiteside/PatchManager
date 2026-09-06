# Security Policy

PatchManager is a patching tool for personal and commercial Windows 10/11
devices. It runs elevated and can install operating system, browser, Microsoft
365, WinGet, and Microsoft Store updates. Review the script and run `-DryRun`
before live use.

## Supported Versions

| Version | Supported |
|---|---|
| Latest published 1.x release (public beta) | ✅ |
| Pre-1.0 internal builds | ❌ — upgrade to the latest release |

Only the latest published release receives fixes during the beta period. Older 1.x versions should be upgraded; `main` may contain unreleased work.

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
- **Configuration fails closed.** If an override file exists but is malformed,
  contains unknown keys or profiles, or fails runtime validation, PatchManager
  exits with code `2` before self-update or provider execution. Validate staged
  configurations with `-ValidateConfig` and the bundled JSON Schema.
- **Protect the central shares.** `CentralReportPath`/`CentralLogPath` receive
  hostnames, software inventories, and patch posture for every device — treat
  the share as sensitive: write access for devices, read access only for the
  people who need it.
- **Webhook URLs are credentials.** An incoming-webhook URL in
  `PatchManager.config.json` lets anyone who reads it post to your channel.
  Restrict read access to the config file accordingly.
- **Treat self-update as a supply chain.** `SelfUpdate` is on by default for
  Personal/Commercial (off for CommercialManaged) and tracks the latest
  **published release** — never a branch or pre-release. It only installs a
  strictly-newer, parse-valid script, and never executes it in the run that
  fetched it. Enabling it means trusting the repository's release process to run
  code as administrator. Keep the script in an admin-only-writable directory;
  for stricter control pin `ExpectedSha256` or a specific `Ref`, set
  `AutoApply: false` to review first, or disable it and deploy via your own
  tooling.
- **Outbound data services.** Enabled checks contact the CISA catalogue,
  endoflife.date product endpoints, and NVD (or a configured mirror). KEV
  resolution sends CVE IDs. The opt-in NVD inventory scan sends installed
  software names as search terms and version-specific CPE identifiers; these
  can reveal software inventory details to the selected endpoint. Caches reduce
  repeat requests but do not make all runs offline. Review `NVD.DataSource`,
  `NVD.Enabled`, `NVDInventoryScan.Enabled`, `EndOfLife.Offline`, and
  `CISAKEV.Enabled` for your network policy. Update providers, connectivity
  checks, and enabled self-update also make outbound requests. Configured
  webhooks send run summaries to the chosen destination.
- Machine-wide changes (the BITS bandwidth policy) are snapshotted and
  restored on exit, including crash paths.

## Operational Guidance

- Do not publish generated `Logs`, `Reports`, `State`, or `Cache` directories.
- Do not publish a personal `PatchManager.config.json`.
- Use `PatchManager.config.example.json` as the public template.
- Run from an elevated PowerShell session.
- Start with `.\Invoke-PatchManager.ps1 -DryRun -Force`.
