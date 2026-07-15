# Changelog

All notable changes to PatchManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [1.6.0] - 2026-07-15

### Added

- **NVD inventory vulnerability scan** (`NVDInventoryScan`, opt-in). The reverse
  of the KEV lookup: instead of confirming a known-exploited CVE against a
  version, it maps **all installed software** to NVD CPEs and lists the
  High/Critical CVEs the installed version is affected by — surfacing
  vulnerabilities that are *not* necessarily in the CISA KEV catalogue.

  - **Report-only.** A generic NVD CVE is known and version-matched but not
    confirmed *actively exploited* (that is what KEV means), so it never sets the
    emergency flag or bypasses the maintenance window. It runs after the
    maintenance-window gate and before patching, and is deferred entirely on an
    emergency run so it can never delay a KEV patch.
  - **Soft queue priority** (`PrioritiseUpdates`): a matched product that has an
    available update this run is patched below confirmed-KEV but above normal.
  - **Dynamic CPE mapping** via NVD's CPE dictionary, scored by product/vendor
    token overlap; an ambiguous match resolves to *no match* rather than a guess
    (mirroring the KEV `Unknown` philosophy). Server-side `isVulnerable` +
    `cvssV3Severity` filtering keeps responses small and version-accurate.
  - Budgeted (`MaxProductsPerRun` / `MaxLookupsPerRun`), cached (name→CPE for 30
    days, CVEs for 48 h), and degrades gracefully — it resumes across runs.
  - New report surfaces: an HTML "Known vulnerabilities (NVD)" section, a
    `NVDVulnFindings` JSON key, a `*.nvd.csv` export, `Statistics.NvdHigh` /
    `NvdCritical`, and per-host `NVD` columns in the fleet dashboard (Critical
    drives the attention posture).

- **NVD data source abstraction** (`NVD.DataSource` / `NVD.MirrorBaseUrl`),
  shared by the KEV lookup and the inventory scan. `Mirror` points at an internal
  endpoint speaking the NVD 2.0 REST shape — **unthrottled, keyless, and works
  air-gapped** — instead of every host hitting the public NVD API. The right
  choice for estates. Scoped to NVD-2.0-compatible endpoints; third-party DB
  formats (Trivy/Grype/OSV) and filesystem datasets are out of scope for now.

### Changed

- The NVD fetch/pacing core is extracted into a shared `Invoke-NVDPacedRequest`,
  so the KEV path and the inventory scan honour **one** global rate-limit clock
  and the `DataSource` setting together.

## [1.5.1] - 2026-07-08

### Fixed

- **The report had three different definitions of "needs attention", and they
  disagreed.** The JSON export flagged any row with `Success=$false` and a status
  other than `Skipped`; the HTML headline count summed blocked + verifying +
  failed + script errors; and the HTML row classes also counted reboot-required
  and KEV rows. Consequences, both visible in a real report:

  - A run could headline **"1 item(s) need review"** over an **empty** attention
    list — the "1" was a script error, which the list never included.
  - Every **`Descoped`** row was reported as an attention item in the JSON,
    because descoped rows carry `Success=$false` by default. Worst under
    `CommercialManaged`, the profile that descopes the most: rows explicitly
    recorded as *"another platform owns this"* were surfaced as problems.
  - A **reboot-required** row was excluded from the headline count entirely,
    despite the panel copy promising it was included.

  All three now delegate to one pure `Get-PatchRowKind` predicate. `Skipped` and
  `Descoped` are deliberate outcomes and never attention; a KEV or
  reboot-required row *is* attention, including when it was skipped by the
  per-run update cap (deferred exposure is still exposure). The panel copy now
  states the count it actually shows, and says descoped rows are excluded.

- Removed five report tone variables (`slaTone`, `failTone`, `blockedTone`,
  `verifyingTone`, `errorTone`) that were computed and never used.

## [1.5.0] - 2026-07-08

### Fixed

- **CISA KEV matches were name-only, and reported as if they were version-
  specific exposures.** The KEV catalogue carries **no version data** — its
  entries name a vendor and a product, nothing more. `Find-KEVMatches` matched
  on vendor + product name and then presented the installed version next to the
  CVE, implying the two had been compared. They never were. Google Chrome
  150.0.7871.47 was reported as an *actionable KEV match* for CVE-2020-16017,
  a use-after-free fixed in Chrome **86.0.4240.198** back in November 2020 — and
  because a KEV match unconditionally set the emergency flag, that false match
  **bypassed the maintenance window**. Chrome will always match a Chrome KEV
  entry, so this fired on every run. The same defect surfaced
  `Microsoft.Edge.GameAssist` 1.0.4019.0 against two 2016 legacy-EdgeHTML CVEs.

  KEV matching is now a two-stage pipeline:

  - `Find-KEVCandidates` performs the name match and labels the result for what
    it is — *this product has known-exploited history*.
  - `Add-KEVExposure` resolves each candidate against **NVD's CPE version
    ranges** (`versionStartIncluding` / `versionEndExcluding` / exact-version
    CPEs), yielding `Affected`, `NotAffected`, or `Unknown`.

  Only `Affected` counts as a KEV match, prioritises a package, sets `IsKEV` on
  a row, or triggers the emergency maintenance-window bypass. `Unknown` — no
  NVD data, an unbounded wildcard range, or a version that is not plain
  dotted-numeric — is surfaced for review and **never** escalates. An unbounded
  wildcard CPE is deliberately treated as undecidable rather than "all versions
  affected", because honouring it literally would reintroduce exactly the
  false-positive emergencies this gate exists to prevent.

  Both KEV report sections now carry an **Exposure** and **Fixed in** column,
  state plainly that the catalogue holds no version data, and only take the
  danger tone when something is actually confirmed affected.

- **Patch-level drift inside a supported release line was computed, then
  discarded.** `New-EolFindingFromRelease` graded severity purely on the
  end-of-life date, so Python 3.14.5 with 3.14.6 available was recorded as
  `Supported` / `info` with an empty recommendation — despite the finding
  already carrying `LatestSupported: 3.14.6`. Such findings now resolve to a new
  `PatchBehind` status: a `review` finding, with a concrete recommendation, and
  a "Behind latest" badge in the report. Windows is exempt (`-SkipPatchDrift`),
  since it reports a bare build number against a `10.0.<build>` latest.

- **Store/pymanager-installed Python could never be updated.** Python installed
  through the Python Install Manager is invisible to WinGet: the `msstore` source
  reports the channel tag (`3.14-64`) where a version belongs, so a 3.14.5 →
  3.14.6 patch was never discovered by any provider. The new
  `Invoke-PythonManagerProvider` closes that gap.

### Added

- **Python Install Manager provider** (`PackageManagers.PythonManagerEnabled`),
  driving the `py` command. Discovers runtimes via `py list -f json`, pairs them
  against `py list --online -f json` by **exact install id** (so a 32-bit or
  arm64 build of the same tag is never mistaken for the installed 64-bit one),
  and applies updates with `py install --update --by-id <id>`.

  Runtimes pymanager does not own — uv/Astral, python.org MSI — are reported as
  `Skipped` with a remediation pointer and **never** updated. Like Scoop, the
  provider is per-user and stays silent in a SYSTEM-context run. It also
  distinguishes the real Python Install Manager from the legacy PEP 397 `py`
  launcher by probing for the manager's JSON listing protocol.

  Update success is decided by **re-reading the installed version**, not by the
  exit code. This is not theoretical: a real 3.14.5 → 3.14.6 update installed
  the runtime, restored `site-packages` and `Scripts`, and *then* exited 1 from
  its shortcut-refresh step with `INTERNAL ERROR: AttributeError: 'str' object
  has no attribute 'satisfied_by'`. Gating on the exit code would have reported
  an applied update as `Failed` and retried it on every subsequent run. The
  observed version is ground truth; the exit code is recorded as evidence, and
  the anomaly is called out in the row. Conversely — mirroring the v1.4.2
  defects — exit code 0 with an unchanged version is `Failed`, never success.

- **NVD provider** (`NVD` config section) supplying CPE version ranges for KEV
  candidate resolution. Cached on disk for 30 days, memoised per run, rate
  limited (NVD allows ~5 requests / 30s unkeyed; set `ApiKey` for 50), and
  capped by `MaxLookupsPerRun`. Setting `Enabled: false` leaves every candidate
  `Unknown`: still reported, never escalated.
- `Statistics.KEVCandidates` in the JSON report — the name-match count before
  version resolution, alongside `Statistics.KEVMatches`, which now means
  *confirmed affected*.
- Pure, unit-tested helpers: `Compare-SoftwareVersion`, `ConvertTo-VersionParts`,
  `ConvertFrom-CpeCriteria`, `ConvertTo-CpeToken`, `Test-CpeProductAlignment`,
  `Test-VersionInCpeRange`, `Resolve-KEVExposure`, `ConvertFrom-PyManagerList`,
  `Find-PyManagerUpgrades`, `Resolve-PyUpdateOutcome`.

### Changed

- **`PatchBehind` applies to Python and Node.js only.** Windows and .NET are
  exempt, because neither reports a version on the same scale as its
  endoflife.date `latest`: Windows gives a bare build (`26200`) against
  `10.0.26200`, and `dotnet --version` gives the **SDK** version — whose third
  component is a feature band (`9.0.100`, `9.0.305`) — against a **runtime**
  `latest` of `9.0.17`. An SDK version always compares above the runtime, so the
  check could never fire, and would have become a false positive the day a
  runtime patch reached `.100`. Both are now suppressed explicitly rather than
  relying on the comparison happening not to trip.
- **`CommercialManaged` descopes the Python Install Manager**, matching the
  existing rule for Scoop and native vendor updaters: a per-user patching
  provider is assumed to be owned by the management platform. It is a no-op in
  the SYSTEM-context runs typical of a managed estate anyway; descoping makes
  that explicit rather than leaving a provider that silently never fires.
- `Get-EndOfLifeCached` now delegates to a shared `Get-CachedApiJson` helper
  (same TTL / offline / stale-fallback semantics), reused by the NVD provider.
- `Get-FleetReport.ps1` no longer counts `NotAffected` inventory KEV candidates
  as host exposure. Reports written before this release have no `ExposureState`
  and are still counted, preserving the previous conservative behaviour.

## [1.4.2] - 2026-07-07

### Fixed
Soundness review of every update-source implementation. Five defects:

- **WinGet: a null exit code was treated as success.** On Windows PowerShell
  5.1, `Start-Process` with redirected streams leaves `.ExitCode` `$null`, and
  the WinGet path defaulted that to `0` — so a failed installer whose output
  matched none of the text patterns was recorded as **SUCCESS** in the audit
  trail. The upgrade call now runs through the reliable process helper and a
  missing exit code is reported as a failure.
- **Microsoft Store: the same null exit code slipped past the failure gate**,
  which disabled the documented "Store CLI exit code 5 → MDM bridge fallback"
  and logged every successful Store apply as "command failed" (the AppX-diff
  verification masked it). The Store CLI wrapper now returns real exit codes
  (with stdin support for its y/n prompt).
- **Microsoft 365: in-flight updates were reported as "AlreadyCurrent".**
  `OfficeC2RClient.exe` hands the work to the Click-to-Run service and can exit
  immediately, so the instant before/after version compare judged too early.
  The provider now polls the C2R `ExecutingScenario` state until the service is
  idle (within the timeout), then uses `LastScenarioResult` + the version delta —
  reporting `Verifying` honestly if the update is still applying.
- **Chrome/Edge/Brave: updates were under-reported as "AlreadyCurrent".**
  Version verification read the `BLBeacon` registry beacon, which browsers only
  rewrite on next launch. Verification now reads the installed binary's product
  version first (beacon as fallback), so a just-applied update shows as
  `Updated` with real before/after evidence.
- **Firmware: Dell's fatal-error exit code was classified as success.** A
  shared reboot-code list `(1, 2, 5)` treated `dcu-cli` exit `2` (fatal error)
  as "success + reboot required". Reboot codes are now declared per OEM —
  Dell `1/5`, HP `3010`, Lenovo none (only `0` trusted) — and everything else
  is a failure with the tool output as evidence.

## [1.4.1] - 2026-07-07

### Fixed
- **Searching/filtering the report now expands the audit appendix** when it is
  collapsed, so matched rows in it are actually shown. Previously the result
  count could claim rows were "visible" while they sat inside the collapsed
  Audit detail section.
- **The software inventory is no longer enumerated twice per run.** The
  end-of-life scan now reuses the inventory built at the start of the run
  instead of re-walking every registry hive and AppX package.

### Added
- **Webhook notifications now carry lifecycle exposure**: `stalenessReview` and
  `eolExposure` counts join the structured payload and the summary text. They
  deliberately do not trigger `OnlyOnProblems` (a long-standing EOL app should
  not ping the channel on every run).
- **Fleet dashboard: per-host Staleness column** (and `StalenessReview` in the
  CSV) alongside the EOL column. Advisory only — staleness does not change a
  host's healthy/attention posture, unlike vendor-declared end-of-life.

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
