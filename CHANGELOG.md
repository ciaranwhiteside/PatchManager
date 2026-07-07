# Changelog

All notable changes to PatchManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.4.0] - 2026-07-07

### Changed
- **The local HTML report now leads with the payload and is lighter for end
  users.** It opens with Attention + the actionable updates list, then security
  and lifecycle (KEV/SLA, staleness, end-of-life); the granular audit material
  (skipped/descoped rows, source/provider checks, per-status counts, run
  diagnostics) moves into a collapsible **Audit detail** appendix. The summary
  board is slimmed from six cards to four (Updates applied, Needs review,
  Security, Reboot required), and the duplicated navigation row and repeated
  verdict are removed.
- **Progressive disclosure that stays a complete compliance artifact.** The
  audit appendix is collapsed on screen behind a "Show audit detail" toggle, but
  is **always fully expanded in print/PDF and when JavaScript is disabled** — so
  the archived record is never abridged. The appendix renders expanded by
  default and JavaScript collapses it only for the interactive view.

## [1.3.1] - 2026-07-07

### Added
- **Fleet dashboard now surfaces end-of-life exposure estate-wide.**
  `Get-FleetReport.ps1` reads each host's `EndOfLifeFindings` and rolls up the
  count of out-of-(or nearing-)support findings per host: a new **End-of-life**
  summary card, a risk lane, a sortable **EOL** column, a CSV `EolExposure`
  column, and inclusion in the healthy/attention posture and filters. A commercial
  operator can now see which machines run end-of-life software without opening
  individual host reports. (`Get-FleetReport.ps1` is not covered by self-update —
  refresh it with `git pull` or by re-downloading the release.)

## [1.3.0] - 2026-07-07

### Added
- **End-of-life intelligence from [endoflife.date](https://endoflife.date/)**
  (`EndOfLife` config, report-only). Surfaces software whose whole release line
  is out of support — fully patchable, yet no longer receiving fixes — in a new
  dedicated report section (HTML panel + JSON key + `.endoflife.csv`), excluded
  from applied/failed counts. Three sources:
  - **Windows OS** — authoritatively flags an out-of-support Windows feature
    version, mapping the running build + edition to the exact release (so a
    consumer 23H2 shows EOL while enterprise 23H2 shows supported).
  - **Developer runtimes** — .NET / Python / Node.js, upgraded from "verify
    manually" to the release's end-of-support date and latest supported version.
  - **Best-effort inventory scan** — matches the whole software inventory against
    endoflife.date's ~460 products; only actual EOL/near-EOL is surfaced (capped
    by `InventoryMaxLookups`), so uncertain matches never raise false alarms.
  Data is cached (`CacheHours`, default 7 days) and offline-safe: a stale cache
  is used if a fetch fails, and `Offline: true` never touches the network. On for
  all profiles. `WarnWithinDays` (default 90) flags releases nearing end-of-life.

## [1.2.3] - 2026-07-07

### Fixed
- **External-command exit codes are now captured reliably.** In Windows
  PowerShell 5.1, `Start-Process -PassThru` leaves `.ExitCode` `$null` when the
  standard streams are redirected, even on a clean exit. The shared
  `Invoke-CapturedProcess` helper now uses `System.Diagnostics.Process`
  directly. This fixes: Chocolatey discovery falsely reported as "failed to
  run"; **successful Chocolatey upgrades misclassified as `Failed`** (a null
  code matched neither success nor a reboot code); and the same misclassification
  in the OEM firmware apply path. Output streams are read asynchronously so the
  timeout is still honoured and a full pipe buffer cannot deadlock the child.

## [1.2.2] - 2026-07-06

### Fixed
- Self-update now works for the documented git-clone install path. Clone
  installs update only `Invoke-PatchManager.ps1`; use `git pull` when you want
  the full repo, docs, config example, and tests refreshed.
- Existing git-clone installs on v1.2.1 or earlier need one manual `git pull`
  to receive this fix because their local updater exits before checking GitHub.

## [1.2.1] - 2026-07-06

### Fixed
- **Scoop provider could not run when Scoop was on PATH**: PowerShell resolves
  `scoop` to its `.ps1` shim, which `Start-Process` with stream redirection
  cannot execute. The provider now prefers the `.cmd` shim.
- **Chocolatey discovery no longer reports false success**: if `choco outdated`
  fails to launch, the source row is now `Failed` with the error instead of a
  clean "0 outdated package(s)".
- **HP firmware report folder** used a literal `%TEMP%` that nothing in the
  invocation chain expands; it is now resolved via the environment.
- A `VendorUpdaters.ExtraCatalogue` entry with no `UpdaterArgs` no longer
  crashes the vendor updater provider.

## [1.2.0] - 2026-07-06

### Added
- **Chocolatey** and **Scoop** providers, extending coverage to software WinGet
  doesn't track. Chocolatey is licence-gated: the CLI is free, but Chocolatey
  for Business is paid, so it defaults on for Personal and off for commercial
  profiles pending an explicit opt-in (`PackageManagers` config). Scoop is
  per-user and runs only in a user-context session.
- **Native vendor updater** provider (`VendorUpdaters`): a data-driven,
  user-extensible catalogue of headless "apply update now" updaters for apps
  with no actionable WinGet candidate. Built-in: Brave. Reuses the Chrome/Edge
  updater pattern and defers to WinGet when it already covers the app.
- **Opt-in OEM firmware/BIOS** provider (`Firmware`): Dell Command Update, HP
  Image Assistant, and Lenovo System Update. Off by default for every profile,
  skipped on battery, and never reboots on its own.
- **Report-only staleness scanner** (`StalenessReport`): flags stale Microsoft
  Defender signatures, Windows feature-update lag, and installed dev-runtime
  versions in a dedicated report section (HTML panel + JSON + CSV). Never
  patches, and excluded from applied/failed counts.

### Changed
- **Self-update is now on by default for Personal and Commercial** (off for
  CommercialManaged) and tracks the **latest published GitHub release** rather
  than the `main` branch — only cut, non-pre-release builds ship, and downloads
  remain version-gated and parse-validated. A stale patch tool is a liability;
  this keeps the fix-delivery current while never auto-shipping unreviewed
  commits. Pin `ExpectedSha256`/`Ref`, set `AutoApply: false`, or disable it for
  stricter control.
- Scope profiles extended: the new patching providers are on for Personal and
  Commercial and off under `CommercialManaged` (which now also defers Scoop and
  vendor updaters to the management platform). The staleness scanner stays on
  for all profiles as a safety net.

## [1.1.1] - 2026-07-06

### Changed
- Refined generated HTML reports for local compliance and fleet dashboards with
  the PatchManager brand system, audit-first layout, offline-safe assets,
  no-script readability, print-safe content, and updated documentation samples.

## [1.1.0] - 2026-07-05

### Changed
- **The `Commercial` profile now patches everything.** Previously it assumed a
  management platform (Intune/SCCM/RMM) already owned OS, Office, and browser
  patching and silently descoped them — a presumption that left the
  organisations most likely to need this tool with less coverage, not more.
  `Commercial` now means full coverage (identical scope to `Personal`) plus
  fleet behaviours (run-scoped BITS throttling, jitter staggering).
- New **`CommercialManaged`** profile carries the old behaviour for estates
  where a platform genuinely owns OS/Office/browser patching: those providers
  are descoped with audit-visible reasons and PatchManager covers the
  third-party gap. The inventory-wide CISA KEV scan still reports exposure in
  the managed software.
- Unknown `ScopeProfile` values now fail safe: a warning plus full `Personal`
  coverage instead of silently partial behaviour.

### Upgrade note
If you deployed 1.0.0 with `"ScopeProfile": "Commercial"` *because* your
platform already patches OS/Office/browsers, change it to
`"CommercialManaged"` to keep that posture. If you picked `Commercial` just
because you're an organisation, no action needed — you now get more coverage.

## [1.0.0] - 2026-07-05

First public release (beta). PatchManager is a PowerShell-based patch
orchestration tool for Windows 10/11 endpoints, with local and central
reporting, safety guards, and fleet visibility.

### Added
- PatchManager brand system under `docs/brand/` (mark, wordmark, brand board,
  brand guide), with the inline brand mark applied to the local and fleet HTML
  reports, the user prompts, and the README.
- Branded, keyboard-accessible user prompts: Enter activates the primary
  action, Esc defers.
- App and Windows patch orchestration with dry-run, report-only, force, and
  scheduled startup/logon task modes.
- Interactive HTML, JSON, and CSV compliance reports for local evidence,
  automation, SIEM, Excel, and Power BI ingestion.
- Fleet dashboard (`Get-FleetReport.ps1`) that aggregates each host's latest
  JSON report into an estate-wide HTML dashboard and CSV summary, including
  stale-host detection.
- Offline report redesigns for both local and fleet HTML reports: sticky
  controls, cinematic summary areas, gapless bento boards, evidence rails,
  native reveal/scroll motion, searchable/filterable rows, and sortable fleet
  host tables.
- Ring, maintenance-window, jitter, and optional startup-task support for
  staged rollout patterns.
- Scope profiles, app descoping, publisher-managed app handling, and explicit
  evidence for skipped or descoped rows.
- CISA KEV emergency handling, inventory-wide KEV visibility, SLA tracking,
  reboot-required reporting, and Windows Event Log signals for monitoring.
- WinGet discovery through `Microsoft.WinGet.Client` when available, with
  `winget.exe` fallback, plus Microsoft Store and Windows Update coverage.
- Optional webhook notifications for Teams, Slack, or generic incoming webhook
  endpoints.
- Opt-in self-update support from GitHub with version gating, source validation,
  optional SHA256 pinning, backup, and event logging.
- GitHub Actions CI plus static and fixture tests for parser, config, reporting,
  maintenance-window, SLA, self-update, and public-file hygiene behavior.

### Changed
- Default deployment ring is `Pilot`, matching the safest initial rollout
  posture.
- BITS throttling is temporary and profile-aware; machine policy is snapshotted
  before the run and restored afterwards.
- Run jitter is profile-aware: Personal devices patch immediately (a single
  device gains nothing from delaying itself), while the Commercial profile
  staggers runs by up to 120 minutes to protect shared links.
- Report heroes now use static evidence/provenance cards and audit-grid surfaces
  instead of decorative telemetry art.
- Brand iconography is unified across SVG assets, generated reports, README
  screenshots, and native user prompts.
- Windows Update search/download/install has an enforced timeout instead of
  hanging indefinitely.
- Connectivity pre-flight uses HTTP HEAD with GET fallback, and TLS 1.2 is
  enforced for Windows PowerShell 5.1 on older Windows 10 builds.
- Self-update skips git clones, dry-run/report-only apply paths, and unsafe
  repository/ref values.

### Fixed
- WinGet reboot suppression appends `/norestart` safely via `--custom` on
  compatible WinGet versions instead of replacing installer silent switches.
- Microsoft Store CLI discovery treats non-zero `store.exe` exits, including
  exit code `5`, as provider failures that can fall back to the Windows MDM
  bridge instead of being mistaken for "no Store updates".
- User idle detection avoids long-uptime wraparound false positives.
- Runtime config merge ignores section-level `_comment` keys.
- PowerShell automatic-variable and unapproved-verb naming issues were cleaned
  up for analyzer compatibility.

### Security
- PatchManager requires administrator rights and should be staged in an
  admin-only-writable directory.
- Generated logs, reports, state, cache data, hostnames, and local paths are
  excluded from publication.
- Reports remain self-contained and offline: no external fonts, CDN scripts,
  remote images, or third-party JavaScript dependencies are required. They
  print completely, stay readable with JavaScript disabled, and respect
  `prefers-reduced-motion`.
