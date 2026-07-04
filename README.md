# PatchManager

[![CI](https://github.com/ciaranwhiteside/PatchManager/actions/workflows/ci.yml/badge.svg)](https://github.com/ciaranwhiteside/PatchManager/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6.svg)

**Keep every application on a Windows 10/11 device up to date — and prove it.**

PatchManager is a single-file PowerShell tool that discovers and applies
updates across **Windows Update, WinGet, the Microsoft Store, Microsoft 365
Click-to-Run, Chrome, and Edge**, then writes evidence-backed HTML, JSON, and
CSV compliance reports. It works equally well as a set-and-forget updater on a
personal machine and as a fleet patching agent across a commercial estate,
with rings, maintenance windows, SLA tracking, CISA KEV emergency handling,
and SIEM-ready event logging built in.

> **Public beta (v1.1.1).** PatchManager runs elevated and changes installed
> software. Read the script, review the configuration, and always start with a
> dry run.

---

## Contents

- [Why PatchManager](#why-patchmanager)
- [Feature overview](#feature-overview)
- [What it updates](#what-it-updates)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Personal machine setup](#personal-machine-setup)
- [Scheduled runs](#scheduled-runs)
- [Configuration reference](#configuration-reference)
- [Scope profiles: Personal vs Commercial](#scope-profiles-personal-vs-commercial)
- [Reports](#reports)
- [Fleet reporting](#fleet-reporting)
- [Security features](#security-features)
- [Commercial deployment](#commercial-deployment)
- [Exit codes](#exit-codes)
- [Windows Event Log IDs](#windows-event-log-ids)
- [Security considerations](#security-considerations)
- [Data hygiene](#data-hygiene)
- [Troubleshooting & FAQ](#troubleshooting--faq)
- [Tests](#tests)
- [Contributing](#contributing)
- [License](#license)

---

## Why PatchManager

Most compromised endpoints are running software with a fix already published.
Windows Update handles the OS, but third-party applications — browsers,
archivers, runtimes, dev tools — are where updates quietly lapse. PatchManager
closes that gap with one auditable script:

- **One run covers everything** — OS, store apps, desktop apps, Office, and
  browsers in a single pass with one consolidated report.
- **Evidence, not vibes** — every row in the report records what was checked,
  what changed, the before/after versions, and *why* anything was skipped.
- **Safe by default** — dry-run mode, maintenance windows, pre-flight checks,
  system restore points, reboot flagging (never forcing), and machine state
  restored on exit.
- **Threat-aware** — the [CISA Known Exploited Vulnerabilities
  catalogue](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) is
  checked every run; actively exploited software bypasses the maintenance
  window, and KEV-listed software with no available update is flagged for
  manual follow-up.
- **No agent, no service, no dependency** — a single `.ps1` file plus a JSON
  config. Deploy it with anything that can run PowerShell.

## Feature overview

| Area | What you get |
|---|---|
| Update engines | Windows Update (COM), WinGet (`winget` + `msstore` sources), Microsoft Store client, Microsoft 365 Click-to-Run, Chrome/Edge native updaters |
| Reporting | Interactive HTML report, JSON for automation, CSV for SIEM/Excel/Power BI, optional central share copy, fleet dashboard |
| Rollout control | Pilot → Early → Broad rings (registry-driven), maintenance windows, hostname-seeded jitter, per-run update caps |
| Security | CISA KEV emergency bypass, inventory-wide KEV scan, SLA tracking with breach events, Windows Event Log IDs for SIEM |
| Safety | Dry-run mode, pre-flight checks (disk/battery/reboot/network/winget health), system restore point, single-instance mutex, atomic state writes, BITS throttle restored on exit |
| User experience | Optional close-app prompts with retry/defer, completion popup with one-click report open, quiet unattended operation |
| Notifications | Optional webhook run summaries (Teams/Slack/generic JSON), optionally only when something needs attention |

## What it updates

| Source | Default | Notes |
|---|---|---|
| Windows Update | ✅ On | Software/quality updates only. Drivers, optional updates, and feature upgrades are **off** unless explicitly enabled. |
| WinGet (`winget` source) | ✅ On | All upgradable packages, minus a safety exclusion list (App Installer, VCLibs, UI.Xaml, WindowsAppRuntime) and anything you descope. |
| Microsoft Store (`msstore` + Store client) | ✅ On | Store CLI bulk updates when available, Windows MDM bridge fallback, verified against before/after AppX snapshots. |
| Microsoft 365 Apps | ✅ On | Click-to-Run updater, detected automatically; never force-closes Office apps unless configured. |
| Chrome / Edge | ✅ On | Native updaters, used only when the browser is not already covered by an actionable WinGet candidate. |

What it deliberately does **not** do:

- **Never reboots a machine.** Reboot-required is flagged in the report, the
  event log, and exit code `3010` — the restart decision stays with you.
- **No feature upgrades by default.** Moving from one Windows version to
  another is a project, not a patch.
- **No publisher-managed packages.** Apps that update through their own
  channel (e.g. JetBrains IDEs, Android Studio) are skipped with evidence
  rather than broken.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- [App Installer / WinGet](https://learn.microsoft.com/windows/package-manager/winget/) 1.4+
- An elevated (Administrator) PowerShell session
- Optional: [`Microsoft.WinGet.Client`](https://www.powershellgallery.com/packages/Microsoft.WinGet.Client)
  module — when installed, upgrade discovery uses structured objects instead
  of parsing winget's text output (recommended on non-English systems)

## Quick start

```powershell
# 1. Get the code
git clone https://github.com/ciaranwhiteside/PatchManager.git
cd PatchManager

# 2. Create your local config (optional - sensible defaults apply without it)
Copy-Item .\PatchManager.config.example.json .\PatchManager.config.json
notepad .\PatchManager.config.json

# 3. See what would happen - no changes are made
.\Invoke-PatchManager.ps1 -DryRun -Force

# 4. Patch for real (bypassing the maintenance window with -Force)
.\Invoke-PatchManager.ps1 -Force

# 5. Or just generate a compliance report without patching
.\Invoke-PatchManager.ps1 -ReportOnly -Force
```

`-Force` only bypasses the **maintenance window** check — every other safety
(pre-flight checks, dry-run semantics, restore point) still applies.

### Parameters

| Parameter | Purpose |
|---|---|
| `-DryRun` | Simulate everything; report what *would* be updated. |
| `-ReportOnly` | Discovery and compliance report only, no patching. |
| `-Force` | Ignore the maintenance window for this run. |
| `-ConfigPath <path>` | Use a specific config file (default: `PatchManager.config.json` next to the script). |
| `-ForceRing Pilot\|Early\|Broad` | Override ring detection for this run. |
| `-InstallStartupTask` | Register a scheduled task (startup + logon triggers). |
| `-UninstallStartupTask` | Remove that scheduled task. |
| `-TaskName <name>` / `-TaskDelayMinutes <n>` | Customise the scheduled task. |

## Personal machine setup

Use an elevated PowerShell window for these steps. Stage the script somewhere
admin-only-writable before creating the scheduled task; `C:\ProgramData` is a
good default for a personal Windows 10/11 machine.

```powershell
# From the folder where you cloned or extracted PatchManager
$installDir = 'C:\ProgramData\PatchManager'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

Copy-Item .\Invoke-PatchManager.ps1, .\PatchManager.config.example.json -Destination $installDir -Force
Copy-Item "$installDir\PatchManager.config.example.json" "$installDir\PatchManager.config.json" -Force

# If the script came from a browser download or zip, unblock it once.
Unblock-File "$installDir\Invoke-PatchManager.ps1" -ErrorAction SilentlyContinue

# Optional: review the config. The defaults are already suitable for Personal.
notepad "$installDir\PatchManager.config.json"

# First run: see what would happen without changing installed software.
& "$installDir\Invoke-PatchManager.ps1" -DryRun -Force

# Second run: patch for real when you are ready.
& "$installDir\Invoke-PatchManager.ps1" -Force

# Install the startup/logon task so PatchManager keeps checking automatically.
& "$installDir\Invoke-PatchManager.ps1" -InstallStartupTask -TaskName 'PatchManager Personal' -TaskDelayMinutes 2
```

Reports land in `C:\ProgramData\PatchManager\Reports`. To open the latest HTML
report:

```powershell
Get-ChildItem 'C:\ProgramData\PatchManager\Reports\PatchReport_*.html' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Invoke-Item
```

For a personal device, leave `ScopeProfile` as `"Personal"`. Consider enabling
`PreFlight.RequireUserIdle` if you do not want scheduled runs to patch while
you are actively using the machine.

## Scheduled runs

For a personal device, install the built-in startup/logon task from an
elevated prompt:

```powershell
.\Invoke-PatchManager.ps1 -InstallStartupTask -TaskName 'PatchManager Personal' -TaskDelayMinutes 2
```

The task runs elevated with a startup trigger and a logon trigger, respects
the maintenance window and pre-flight checks (enable
`PreFlight.RequireUserIdle` if you don't want it patching while you type), and
never overlaps itself thanks to the single-instance mutex.

> **Place the script somewhere admin-only-writable first** (e.g.
> `C:\ProgramData\PatchManager\`). The task runs elevated with
> `-ExecutionPolicy Bypass`; if the script sits in your user profile, anything
> running as your user could swap the file and gain admin at next logon. The
> installer warns you if the path looks wrong.

To remove the task:

```powershell
.\Invoke-PatchManager.ps1 -UninstallStartupTask -TaskName 'PatchManager Personal'
```

## Configuration reference

Copy `PatchManager.config.example.json` to `PatchManager.config.json` and
override only the keys you care about — unspecified keys keep their defaults,
sections merge key-by-key, and `_comment` keys are ignored.
`PatchManager.config.json` is git-ignored on purpose: it may contain local
paths and share names.

### `ScopeProfile`

| Key | Default | Purpose |
|---|---|---|
| `ScopeProfile` | `"Personal"` | `Personal` or `Commercial`. See [Scope profiles](#scope-profiles-personal-vs-commercial). |

### `Descope`

Everything descoped still appears in the report — as `Descoped`, with a reason
— so auditors can see it was a decision, not a miss.

| Key | Default | Purpose |
|---|---|---|
| `PackageIds` | `[]` | Package-ID prefixes to exclude (e.g. `"Google.Chrome"`). |
| `PackageNamePatterns` | `[]` | Regex patterns matched against package names. |
| `Providers` | `[]` | Whole providers to exclude (e.g. `"edge-update"`). |
| `Sources` | `[]` | Whole sources to exclude (e.g. `"msstore"`). |
| `Reasons` | `{}` | Map of descope key → human-readable reason shown in reports. |

### `Ring`

| Key | Default | Purpose |
|---|---|---|
| `RegistryPath` / `RegistryKey` | `HKLM:\SOFTWARE\Company\PatchManager` / `DeploymentRing` | Where the device's ring is read from. Set per device via GPO/Intune/imaging. |
| `Default` | `"Pilot"` | Ring used when the registry value is absent. |
| `Delays` | `Pilot 0 / Early 3 / Broad 7` | Suggested stagger (days) — advisory; enforce via your deployment tooling. |

### `MaintenanceWindow`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `true` | Enforce the window (bypassed by `-Force` and KEV emergencies). |
| `StartHour` / `EndHour` | `22` / `6` | Window in local time; overnight windows (start > end) are supported. |
| `AllowedDays` | all days | Days on which patching may run. |
| `JitterMaxMinutes` | `120` | Hostname-seeded random delay so a fleet doesn't hit the network at once. Rings scale it: Pilot 30%, Early 65%, Broad 100%. |

### `Network`

| Key | Default | Purpose |
|---|---|---|
| `BITSThrottleEnabled` | `null` | `null` = decide by profile (Personal **off**, Commercial **on**). The BITS policy is applied for the run only and **restored afterwards**, even on crash. |
| `BITSMaxBandwidthKbps` | `4096` | Per-machine BITS cap while patching. |
| `TestConnectivityUrl` | `https://www.cloudflare.com` | Pre-flight connectivity probe (HEAD, GET fallback). |
| `ConnectivityTimeoutSec` | `10` | Probe timeout. |

### `WinGet`

| Key | Default | Purpose |
|---|---|---|
| `ExcludePackagePrefixes` | App Installer, VCLibs, UI.Xaml, WindowsAppRuntime | Component packages that should not be swapped mid-run. |
| `ApprovedPackages` | `[]` | Allow-list mode: when non-empty, **only** these IDs are updated. |
| `PublisherManagedPackageIds` | `["Google.AndroidStudio"]` | Packages that must update through their own vendor flow. |
| `IncludeMSStore` | `true` | Also query the `msstore` source. |
| `Scope` | `"machine"` | winget install scope. |
| `AcceptAgreements` | `true` | Non-interactive agreement acceptance. |
| `PackageTimeoutSeconds` | `300` | Per-package timeout. |
| `MaxUpdatesPerRun` | `0` | Cap updates per run (`0` = unlimited); KEV matches are prioritised first. |
| `SuppressReboot` | `true` | Appends `/norestart` via `--custom` (winget 1.4+) so installers don't reboot mid-run. |
| `MaxRetries` | `2` | Attempts per package for transient failures (linear backoff). |

### `WindowsUpdate`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `true` (Personal) / `false` (Commercial) | Windows Update provider on/off. |
| `IncludeDrivers` / `IncludeOptionalUpdates` / `IncludeFeatureUpdates` | `false` | Opt-in expansions of scope. |
| `SearchCriteria` | `IsInstalled=0 and IsHidden=0 and Type='Software'` | WUA search criteria. |
| `TimeoutSeconds` | `3600` | **Enforced** watchdog over the whole search/download/install flow. |

### `Microsoft365`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `true` (Personal) / `false` (Commercial) | Click-to-Run updates on/off. |
| `ForceAppShutdown` | `false` | Whether the C2R updater may close running Office apps. |
| `TimeoutSeconds` | `1800` | Updater timeout. |

### `Browsers`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` / `ChromeEnabled` / `EdgeEnabled` | `true` (Personal; Chrome/Edge `false` on Commercial) | Native browser updaters, used only when WinGet has no actionable candidate. |
| `NativeTimeoutSeconds` | `900` | Native updater timeout. |

### `UserExperience`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `true` | Master switch for all dialogs (auto-disabled in non-interactive sessions). |
| `PromptOnAppInUse` | `true` | Ask the user to close a blocking app, with Retry/Defer. |
| `CompletionPopup` | `true` | Show a summary popup when the run finishes. |
| `OpenReportPrompt` | `true` | Offer a one-click "Open report" button. |
| `PromptTimeoutSeconds` | `900` | Auto-defer if the user doesn't respond. |
| `ShowOnDryRun` | `true` | Also show the popup for dry runs. |

### `MicrosoftStore`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `true` | Store client updates on/off. |
| `Provider` | `"Auto"` | `Auto` (Store CLI, then MDM bridge), `StoreCli`, or `Cim`. |
| `TimeoutSeconds` | `180` | Per-command timeout. |
| `UseCimFallback` | `true` | Fall back to the Windows MDM bridge update scan. |
| `CaptureAppxDiff` | `true` | Verify results with before/after AppX snapshots. |
| `PostUpdateSettleSeconds` | `20` | Wait before the post-update snapshot. |

### `SLA`

| Key | Default | Purpose |
|---|---|---|
| `Critical` / `High` / `Medium` / `Low` | `14` | Days from *update available* to *update applied* before a breach is reported. The clock starts when PatchManager first sees the update, not at CVE publication. |

### `Logging`

| Key | Default | Purpose |
|---|---|---|
| `LocalLogPath` | `C:\ProgramData\PatchManager\Logs` | Daily log files. |
| `CentralLogPath` | `""` | Optional UNC share; logs are copied per-host with retries. |
| `EventLogSource` | `PatchManager` | Application event log source for SIEM. |
| `RetentionDays` | `90` | Local log/report retention. |
| `LogLevel` | `Info` | `Debug`, `Info`, `Warning`, or `Error`. |

### `Reporting`

| Key | Default | Purpose |
|---|---|---|
| `LocalReportPath` | `C:\ProgramData\PatchManager\Reports` | Where per-run reports are written. |
| `CentralReportPath` | `""` | Optional UNC share; reports are copied to `<share>\<HOSTNAME>\`. Feeds [Get-FleetReport.ps1](Get-FleetReport.ps1). |
| `GenerateHTML` / `GenerateJSON` / `GenerateCSV` | `true` | Which report formats to produce. |

### `Notifications`

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `false` | Post a run summary to a webhook. |
| `WebhookUrl` | `""` | Teams/Slack incoming webhook or any JSON endpoint. Payload includes a plain `text` field plus structured counters. |
| `OnlyOnProblems` | `true` | Only post when a run has failures, KEV matches, SLA breaches, or errors. |
| `TimeoutSec` | `15` | Webhook post timeout. A webhook failure never fails the run. |

### `SelfUpdate`

Self-update is **off by default**. When enabled, PatchManager checks the
configured GitHub repository for a newer `Invoke-PatchManager.ps1`, validates
that the downloaded script parses as PowerShell, optionally verifies a pinned
SHA256 hash, backs up the current script, and installs the new copy for the
next run. It is skipped when running from a git clone; use `git pull` there.

| Key | Default | Purpose |
|---|---|---|
| `Enabled` | `false` | Enable self-update checks. Leave off unless the script is staged in an admin-only-writable location. |
| `Repository` | `"ciaranwhiteside/PatchManager"` | GitHub `owner/repo` to fetch from. URL values are rejected. |
| `Ref` | `"main"` | Branch or tag to read from. Path traversal and URL metacharacters are rejected. |
| `AutoApply` | `true` | `true` installs a validated newer script; `false` only reports that an update is available. |
| `ExpectedSha256` | `""` | Optional exact SHA256 hash pin for locked-down deployments. |
| `TimeoutSec` | `30` | Download timeout. A self-update failure never fails the patch run. |

### `State`, `PreFlight`, `SystemRestore`, `CISAKEV`

| Key | Default | Purpose |
|---|---|---|
| `State.StatePath` / `StateFile` | `C:\ProgramData\PatchManager\State` / `patch_state.json` | SLA tracking state (written atomically). |
| `PreFlight.MinFreeSpaceGB` | `5` | Abort if the system drive is below this. |
| `PreFlight.CheckBattery` / `MinBatteryPercent` / `RequireACPower` | `true` / `20` / `false` | Laptop protections. |
| `PreFlight.AbortOnPendingReboot` | `true` | Don't patch on top of a half-applied state. |
| `PreFlight.RequireUserIdle` / `MinIdleMinutes` | `false` / `5` | Defer gracefully while the user is active (great for scheduled tasks). |
| `SystemRestore.Enabled` | `true` | Create a restore point before patching (throttled to one per 24 h by Windows). |
| `CISAKEV.Enabled` | `true` | Fetch and match the KEV catalogue. |
| `CISAKEV.FeedUrl` / `CacheHours` / `CachePath` | CISA feed / `24` / `C:\ProgramData\PatchManager\Cache` | Feed caching; a stale cache is used if the fetch fails. |

## Scope profiles: Personal vs Commercial

**Personal** (default) assumes the device owns its own patching: Windows
Update, Microsoft 365, Chrome, and Edge are all in scope.

**Commercial** assumes a management platform (Intune/SCCM/RMM) already owns
OS, Office, and browser patching, so PatchManager stays in its lane and
focuses on the third-party app gap:

```json
{ "ScopeProfile": "Commercial" }
```

automatically:

- disables the Windows Update, Microsoft 365, Chrome, and Edge providers,
- descopes Chrome/Edge/WebView2/Office/Teams/OneDrive WinGet packages (with
  audit-visible reasons),
- enables run-scoped BITS throttling to protect shared office links.

Everything a profile does can be overridden per-key in your config, and
finer-grained exclusions go in `Descope` — for example, if your RMM manages
Zoom:

```json
{
  "Descope": {
    "PackageIds": ["Zoom.Zoom"],
    "Reasons": { "Zoom.Zoom": "Managed by RMM policy 12-B." }
  }
}
```

## Reports

Each run writes up to three artifacts to `Reporting.LocalReportPath` (and the
central share if configured):

- **HTML** — interactive: search, status/source/provider filters, sortable
  columns, print-friendly. Actionable package updates are separated from
  source/provider audit checks and from skipped/descoped rows, so "what
  changed" is never buried under "what was checked".
- **JSON** — full machine-readable results: metadata, statistics, status /
  source / provider summaries, attention items, reboot-required items, every
  update row, KEV matches (actionable + inventory), SLA breaches.
- **CSV** — flat per-row export for SIEM ingestion, Excel, or Power BI.

### Status glossary

| Status | Meaning |
|---|---|
| `Planned` | Dry-run: this action would be attempted. |
| `Succeeded` | Update applied and verified. |
| `Updated` | Version changed after an update action. |
| `AlreadyCurrent` | Provider checked; item was already up to date. |
| `Skipped` | Intentionally not patched this run (reason in Evidence). |
| `Descoped` | Excluded by profile or `Descope` config (reason in Evidence). |
| `Blocked` | Could not proceed — usually the app was open; remediation included. |
| `Failed` | Provider or update action failed (evidence included). |
| `Verifying` | Update command completed; final state pending confirmation. |
| `Completed` | Source/provider check finished — audit evidence, not a package update. |

## Fleet reporting

Point every device's `Reporting.CentralReportPath` at the same share, then run
the aggregator from anywhere that can read it (read-only, no elevation):

```powershell
.\Get-FleetReport.ps1 -CentralReportPath '\\fileserver\PatchManager\Reports' -StaleDays 7 -OpenReport
```

You get one HTML dashboard and CSV covering every host's most recent run:
last-seen time with **stale-host flagging**, ring, profile, applied/failed
counts, KEV matches (actionable and inventory), SLA breaches, script errors,
and pending reboots — the "is my estate actually patched?" view.

## Security features

- **CISA KEV emergency handling** — every run downloads (and caches) the Known
  Exploited Vulnerabilities catalogue. If an available upgrade matches a KEV
  entry, PatchManager declares an emergency: the maintenance window is
  bypassed, jitter is capped at 5 minutes, the matching packages are patched
  first, and event `9001` is raised for your SIEM.
- **Inventory-wide KEV visibility** — installed software that matches the KEV
  catalogue but has *no* available update through PatchManager's sources is
  reported in its own section, so exposure isn't invisible just because
  there's nothing to click. Verify the installed version against the CVE and
  update through the vendor if affected.
- **SLA tracking** — the moment an update becomes available it is tracked in
  local state; if it is still unapplied after the configured window (default
  14 days) the run reports a breach and raises event `1020`.
- **Word-boundary KEV matching** with vendor+product agreement, minimum-length
  guards, and Microsoft-Windows exclusions to keep false positives out of your
  emergency path.

## Commercial deployment

1. **Stage the script** at an admin-only-writable path on each device, e.g.
   `C:\ProgramData\PatchManager\` (Intune Win32 app, SCCM package, GPO file
   copy, or your RMM).
2. **Drop a config** next to it with `"ScopeProfile": "Commercial"`, your
   central share paths, and any descoping.
3. **Assign rings** by writing `DeploymentRing` (`Pilot`/`Early`/`Broad`) to
   `HKLM:\SOFTWARE\Company\PatchManager` via GPO/Intune — pilot a small group,
   then let `Early` and `Broad` follow.
4. **Schedule it** — either `-InstallStartupTask`, or your own scheduled
   task/Intune remediation running
   `powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\PatchManager\Invoke-PatchManager.ps1`
   nightly. The maintenance window, jitter, idle checks, and the
   single-instance mutex make dense schedules safe.
5. **Collect evidence** — set `Reporting.CentralReportPath` and
   `Logging.CentralLogPath` to per-purpose UNC shares, run
   `Get-FleetReport.ps1` on a schedule, and ingest events `1000–9001` and/or
   the CSV into your SIEM.
6. **Get told when it matters** — point `Notifications.WebhookUrl` at a
   Teams/Slack channel with `OnlyOnProblems: true`.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success. |
| `1` | Completed with errors (see report / event log). |
| `2` | Pre-flight failure — no changes made. |
| `3010` | Success — reboot required to finish (standard MSI convention). |
| `99` | Fatal unhandled exception. |

## Windows Event Log IDs

Source `PatchManager`, log `Application` — for SIEM correlation:

| ID | Level | Event |
|---|---|---|
| `1000` | Info | Run started |
| `1001` | Error | Error (general) |
| `1002` | Warning | Warning (general) |
| `1010` | Info | Run completed successfully |
| `1011` | Warning | Run completed with errors |
| `1020` | Error | SLA breach detected |
| `1030` | Info | PatchManager self-updated; new script takes effect on next run |
| `3010` | Warning | Reboot required |
| `9001` | Error | **CISA KEV emergency** — actively exploited vulnerability matched on this host |

## Security considerations

- PatchManager requires and runs with **administrator rights**; it installs
  software. Review the script before first use — it is a single readable file.
- Keep the script in an **admin-only-writable directory** when running it from
  a scheduled task (see [Scheduled runs](#scheduled-runs)).
- If `SelfUpdate.Enabled` is turned on, keep the script in an
  **admin-only-writable directory**, pin `ExpectedSha256` where possible, and
  prefer a release tag in `SelfUpdate.Ref` over a moving branch for broad
  deployments.
- Machine-wide changes are **reverted on exit**: the BITS policy snapshot is
  restored even after a crash. The only persistent artifacts are logs,
  reports, state, cache, and the optional scheduled task.
- TLS 1.2 is enforced for feed downloads on Windows PowerShell 5.1.
- Vulnerability reports: see [SECURITY.md](SECURITY.md).

## Data hygiene

Never publish the generated `Logs/`, `Reports/`, `State/`, or `Cache/`
directories, nor your personal `PatchManager.config.json` — they can contain
hostnames, local user paths, package inventories, and update history. All are
git-ignored, and the test suite scans the public files for common leaks.

## Troubleshooting & FAQ

**Pre-flight fails with "winget.exe not found".**
Install/update *App Installer* from the Microsoft Store, or deploy it via
[winget-cs](https://learn.microsoft.com/windows/package-manager/winget/) for
SYSTEM contexts. PatchManager also looks in `Program Files\WindowsApps` for
SYSTEM-context runs.

**A package is always `Blocked`.**
The app (or one of its components) is running. Close it and rerun, or let the
interactive prompt's *Retry* handle it. Unattended runs defer and try again
next run.

**Why didn't PatchManager update Chrome/Office on my work laptop?**
You're on the Commercial profile: those are descoped on the assumption your
management platform owns them. Check the *Skipped and descoped* section of the
report — the reason is recorded there. Override per-key if the assumption is
wrong for you.

**Does `-Force` skip safety checks?**
No — it only bypasses the maintenance window. Pre-flight checks, restore
points, and reboot flagging all still apply.

**Reports show `Verifying` — is that a failure?**
Not necessarily: the update command completed but the final state couldn't be
confirmed yet (common with Store apps that finish asynchronously). It's
counted under "needs review" so it never silently disappears.

**Can it run as SYSTEM (Intune/SCCM)?**
Yes. WinGet is resolved from `WindowsApps` for SYSTEM contexts, dialogs
auto-disable in non-interactive sessions, and per-user installs are discovered
by enumerating loaded user hives.

**Non-English Windows?**
Install the `Microsoft.WinGet.Client` module — discovery then uses structured
objects instead of parsing winget's localised text table.

## Tests

```powershell
.\Tests\Invoke-PatchManager.Static.Tests.ps1
```

Dependency-free static and fixture tests: parser health, winget table parsing
against captured fixtures, config merge and scope profiles, descoping rules,
maintenance window math, SLA state lifecycle, report grouping and counters,
and a scan for personal data in public files. CI runs the same suite plus
PSScriptAnalyzer on Windows PowerShell 5.1 **and** PowerShell 7.

## Contributing

Issues and pull requests are welcome — see
[CONTRIBUTING.md](CONTRIBUTING.md) for the project constraints (single-file
script, PS 5.1 floor, never reboot, restore machine state) and the local
dev loop.

## License

[MIT](LICENSE). Provided as-is; you are responsible for validating it in your
environment before broad deployment.
