# Operations runbook

## Normal operating loop

```powershell
# Validate after every configuration change
.\Invoke-PatchManager.ps1 -ValidateConfig

# Preview without changing software or SLA state
.\Invoke-PatchManager.ps1 -DryRun -Force

# Run now, preserving all pre-flight safeguards
.\Invoke-PatchManager.ps1 -Force

# Audit providers and advance WinGet SLA evidence without patching
.\Invoke-PatchManager.ps1 -ReportOnly -Force
```

Use `Get-FleetReport.ps1` against the configured central report share after
Pilot runs and on an operator schedule.

## Terminal outcomes

| Outcome | Exit | Changes | Evidence |
|---|---:|---|---|
| Successful | `0` | Applicable updates may be installed | Full report and completion event `1010`. |
| Successful, reboot needed | `3010` | Updates installed; reboot never forced | Full report and event `3010`. |
| Provider errors | `1` | Some providers may have completed | Full report and completion event `1011`. |
| Pre-flight/config failure | `2` | No providers run | Config errors print before logging; pre-flight failures write a terminal report and event `1011`. |
| Fatal exception | `99` | Depends on failure location | Fatal console/log/event evidence; machine-state restoration runs in `finally`. |
| Maintenance/user/lock deferral | `0` | No patch providers run | A `Skipped` terminal report records the reason. |

The fleet dashboard therefore shows the latest attempted run, not merely the
last successful provider run. Terminal deferrals carry
`Metadata.ProvidersExecuted=false`, appear as attention, and show their
disposition in the fleet Notes column. For an invalid configuration, fix the local file
and rerun `-ValidateConfig`; configuration cannot be trusted enough to select a
report destination.

## Investigating a host

1. Open the newest `PatchReport_<HOST>_*.html`.
2. Read the headline attention rows.
3. Check provider/source rows for discovery failures.
4. Review `Evidence` and `Remediation` before retrying.
5. Check the daily log under `Logging.LocalLogPath` for process output.
6. If central reporting is stale, verify share permissions from the task's run
   identity and compare the newest local JSON timestamp.

Treat `Failed`, `Blocked`, and `Verifying` as unresolved. `Completed` is a
provider/source check, not proof that a package version changed.

## Recovery rules

- PatchManager never reboots automatically.
- A pending reboot blocks a later run by default; reboot through normal change
  control and retry.
- Temporary BITS policy values are restored in the script's `finally` block.
- Self-update runs only after pre-flight and maintenance-window approval. It
  backs up the current script and takes effect on the next run.
- If a native update has no observable version, investigate its vendor logs;
  PatchManager records `Verifying` instead of assuming success.

## Release checklist

```powershell
.\Tests\Invoke-PatchManager.Static.Tests.ps1
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
.\Invoke-PatchManager.ps1 -ValidateConfig -ConfigPath .\PatchManager.config.example.json
```

Then run an elevated dry run on supported Windows 10 and Windows 11 test hosts,
covering both Windows PowerShell 5.1 and PowerShell 7. CI validates parsing and
fixture behavior; it does not replace provider integration testing against the
real Windows servicing stack.
