# Contributing to PatchManager

Thanks for your interest in improving PatchManager. This project deliberately
stays a **single deployable script** (`Invoke-PatchManager.ps1`) plus optional
companion tools — please keep that constraint in mind when proposing changes.

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

# Lint (install once: Install-Module PSScriptAnalyzer)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Safe end-to-end run (elevated PowerShell)
.\Invoke-PatchManager.ps1 -DryRun -Force
```

CI runs the same three steps on `windows-latest` for pushes and pull requests.

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
