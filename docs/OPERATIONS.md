# Operations runbook

## Normal operating loop

```powershell
# Validate after every configuration change
.\Invoke-PatchManager.ps1 -ValidateConfig

# Preview without changing software or SLA state
.\Invoke-PatchManager.ps1 -DryRun -Force

# Run now, preserving all pre-flight safeguards
.\Invoke-PatchManager.ps1 -Force

# Audit providers; advances WinGet SLA evidence only when SLA.Enabled resolves true
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
disposition under Report note in the fleet Next step column. For an invalid configuration, fix the local file
and rerun `-ValidateConfig`; configuration cannot be trusted enough to select a
report destination.

## Investigating a host

1. Open the newest `PatchReport_<HOST>_*.html`.
2. Read the verdict and prioritized exception queue; in fleet view, follow the Next step column.
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

## Report recovery and interpretation

- **Evidence unavailable:** no valid JSON evidence was read. Check the device
  task, its local report, and share permissions; collect a valid report. Unknown
  counts are not zero, and unknown reboot state does not mean a restart is clear.
- **Stale:** investigate the scheduled task and report-copy path. Age uses the
  newest JSON file's modification time. Preserve timestamps when restoring
  archived evidence; a fresh copy is not necessarily a fresh device check.
- **No filter matches:** use Show all hosts / Show all report rows. Screen
  filters do not remove evidence from print or CSV output.
- **Host missing entirely:** check whether its folder exists on the central
  share. Fleet reporting cannot count devices that have never created a folder.
- **HTML report unavailable:** JSON can still be counted. Copy the matching HTML
  beside its JSON to enable the device-report link.

For packaging, upgrade, rollback, and publication steps, use the
[release guide](RELEASING.md). A prepared ZIP is not evidence that live provider
integration tests or a production rollout have completed.