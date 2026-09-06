# Contributing to PatchManager

Thanks for your interest in improving PatchManager. This project deliberately
stays a **single deployable script** (`Invoke-PatchManager.ps1`) plus optional
companion tools — please keep that constraint in mind when proposing changes.

By participating you agree to our [Code of Conduct](CODE_OF_CONDUCT.md).

## Ground rules

- **Target Windows PowerShell 5.1.** Everything must run on a stock Windows
  10/11 install. PowerShell 7 compatibility is welcome but 5.1 is the floor.
- **No new runtime dependencies.** Optional integrations (e.g.
  `Microsoft.WinGet.Client`) must degrade gracefully when absent.
- **Never force a reboot.** PatchManager flags reboot-required and exits 3010;
  it never restarts a machine itself.
- **Leave the machine as you found it.** Any machine-wide state change (policy
  keys, services) must be reverted before exit, including on crash paths.
- **Every result must be evidenced.** Provider outcomes carry an `Evidence`
  string; keep reports auditable.
- **No personal data in the repo.** Do not commit `PatchManager.config.json`,
  logs, reports, state, hostnames, or local user paths. The test suite scans
  public files for common leaks.

## Developing

```powershell
# Run the test suite (no dependencies needed)
.\Tests\Invoke-PatchManager.Static.Tests.ps1

# Validate the public configuration example with the runtime validator
.\Invoke-PatchManager.ps1 -ValidateConfig -ConfigPath .\PatchManager.config.example.json

# Lint (install once: Install-Module PSScriptAnalyzer)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Safe end-to-end run (elevated PowerShell)
.\Invoke-PatchManager.ps1 -DryRun -Force
```

CI validates JSON and the example configuration, runs PSScriptAnalyzer, and runs static/fixture tests on Windows PowerShell 5.1 and PowerShell 7. It also checks documentation and builds a release package. Browser checks are a separate local gate; CI never runs patch providers.
Provider integrations still require an elevated Windows test host; fixture and
AST tests cannot prove Windows Update, Store, Office, or vendor behavior.

## Pull requests

1. Fork, branch from `main`, and keep changes focused — one topic per PR.
2. Add or update tests when you change parsing, config handling, scoping, or
   state logic. Fixture-based tests live in `Tests/Fixtures/`.
3. Make sure `.\Tests\Invoke-PatchManager.Static.Tests.ps1` passes and
   PSScriptAnalyzer reports no errors.
4. Update `CHANGELOG.md` under an *Unreleased* heading and, where relevant, the
   configuration reference in `README.md`.
5. Describe the risk surface in the PR: what runs elevated, what state is
   touched, how failures are handled.

## Reporting bugs and requesting features

Use the GitHub issue templates. For anything security-sensitive, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

## Release preparation

Follow [RELEASING.md](../docs/RELEASING.md). Keep release notes in
`docs/releases/`, run browser checks for report changes, and package only
public files with `Build-Release.ps1`. Generated fixtures stay under `Reports/`.
