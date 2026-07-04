# Changelog

All notable changes to PatchManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.1.1] - 2026-07-04

### Fixed
- Microsoft Store CLI discovery now treats non-zero `store.exe` exits, including
  exit code `5`, as provider failures that can fall back to the Windows MDM
  bridge instead of being mistaken for "no Store updates".
- Store CLI command capture now uses temp-file redirection instead of async
  output event handlers, matching the WinGet wrapper and avoiding fragile
  process behavior from the Store app execution alias.

## [1.1.0] - 2026-07-04

### Added
- **Opt-in self-update** (`SelfUpdate` config section): checks GitHub for a
  newer `Invoke-PatchManager.ps1`, version-gates the result, parse-validates
  the downloaded script, optionally verifies a pinned SHA256 hash, backs up the
  current script, and installs the update for the next run.
- Self-update status is included in JSON report metadata, and successful
  self-updates raise Windows Event Log ID `1030`.
- Static tests for self-update version parsing and GitHub source validation.
- README personal-machine setup instructions with staging, first run, scheduled
  task install, and latest-report commands.

### Changed
- Self-update is skipped in git clones, in `DryRun`/`ReportOnly` apply paths,
  and when `Repository`/`Ref` contains malformed or unsafe values.
- Self-update downloads are staged beside the running script instead of the
  user temp folder, keeping validation and replacement inside the same
  deployment directory boundary.

## [1.0.0] - 2026-07-04

First public beta release. Version restarts at 1.0.0 for the public line
(internal iterations were previously numbered up to 2.2.0).

### Added
- **CSV report export** (`Reporting.GenerateCSV`, on by default): per-run
  results as CSV alongside the JSON and HTML reports, for SIEM/Excel/Power BI
  ingestion. Copied to the central share like the other reports.
- **Webhook notifications** (`Notifications` config section): posts a compact
  JSON run summary to a Teams/Slack/generic incoming webhook, optionally only
  when a run needs attention.
- **Fleet dashboard** (`Get-FleetReport.ps1`): aggregates per-host JSON reports
  from the central share into one estate-wide HTML dashboard and CSV, with
  stale-host detection.
- **Inventory-wide CISA KEV scan**: the full software inventory is now checked
  against the KEV catalogue. Matches with no actionable update appear in a
  dedicated informational report section (they do not trigger emergency runs).
- **`-UninstallStartupTask`** switch to cleanly remove the scheduled task.
- **`Microsoft.WinGet.Client` module support**: upgrade discovery uses the
  official PowerShell module when installed (locale-proof, structured output),
  falling back to `winget.exe` text parsing otherwise.
- **GitHub Actions CI**: PSScriptAnalyzer plus the static/fixture test suite on
  Windows PowerShell 5.1 and PowerShell 7.
- Expanded test suite: winget table parser fixtures, config merge, descoping,
  maintenance window math, and SLA state lifecycle tests.

### Changed
- **BITS throttling is now temporary and profile-aware.** The machine-wide BITS
  policy is snapshotted before the run and restored afterwards (also on crash).
  New `Network.BITSThrottleEnabled` setting: off for the Personal profile, on
  for Commercial, explicit value wins.
- **`WindowsUpdate.TimeoutSeconds` is now enforced.** The Windows Update
  search/download/install flow runs on a watchdog and reports a clear failure
  instead of hanging indefinitely.
- Connectivity pre-flight uses an HTTP HEAD request (GET fallback) instead of
  downloading a full page.
- TLS 1.2 is enforced at startup for PowerShell 5.1 on older Windows 10 builds.
- Default deployment ring is now `Pilot` (was `Broad`), matching the example
  config and giving new installs the safest default.
- `-InstallStartupTask` warns when the script lives under a user profile, since
  the task runs elevated with `-ExecutionPolicy Bypass`.

### Fixed
- **WinGet reboot suppression no longer breaks silent installs.** `--override
  /norestart` replaced each installer's silent switches; PatchManager now uses
  `--custom /norestart` (winget 1.4+) which appends instead, and omits the flag
  on older winget builds.
- User idle detection no longer misreports after ~25 days of uptime
  (`Environment.TickCount` wrap).
- Renamed assignments to PowerShell automatic variables (`$matches`, `$args`,
  `$profile`) and the unapproved-verb function `Apply-ScopeProfileDefaults`
  (now `Set-ScopeProfileDefaults`).
- Section-level `_comment` keys in the config file are no longer merged into
  the runtime configuration.
