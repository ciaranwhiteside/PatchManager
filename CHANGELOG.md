# Changelog

All notable changes to PatchManager are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

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
