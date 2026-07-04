## What this PR does

<!-- One or two sentences. Link the issue if there is one. -->

## Risk surface

<!-- What runs elevated, what machine state is touched, how failures are handled. -->

## Checklist

- [ ] `.\Tests\Invoke-PatchManager.Static.Tests.ps1` passes locally
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1` reports no errors
- [ ] Works on Windows PowerShell 5.1
- [ ] Any machine-wide state change is reverted on exit (including crash paths)
- [ ] `CHANGELOG.md` updated
- [ ] README configuration reference updated (if config keys changed)
- [ ] No personal paths, hostnames, or generated report data included
