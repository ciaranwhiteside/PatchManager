# PatchManager

PatchManager is a beta PowerShell patching script for personal Windows 10/11
devices. It discovers and applies updates across Windows Update, WinGet,
Microsoft Store, Microsoft 365 Click-to-Run, Chrome, and Edge, then writes JSON
and HTML reports.

This project is intentionally still a single deployable script:

```powershell
.\Invoke-PatchManager.ps1 -DryRun -Force
.\Invoke-PatchManager.ps1 -Force
```

## Beta Warning

PatchManager runs elevated and can change installed software. Read the script,
review the configuration, and run a dry run before using it live. It is provided
as-is under the MIT license.

## What It Updates

- Windows Update software updates by default, excluding drivers, optional
  updates, and feature upgrades unless explicitly enabled.
- WinGet packages from the `winget` source.
- Microsoft Store packages discoverable through WinGet `msstore` and Store
  client update discovery.
- Microsoft 365 Click-to-Run when detected.
- Chrome and Edge via native updaters when not represented by an actionable
  WinGet candidate.

Commercial/provider-managed environments can use `ScopeProfile` and `Descope`
settings to mark packages, providers, sources, or name patterns as out of scope.

## Configuration

Copy the example config and edit it locally:

```powershell
Copy-Item .\PatchManager.config.example.json .\PatchManager.config.json
notepad .\PatchManager.config.json
```

`PatchManager.config.json` is intentionally ignored by Git. Keep local paths,
central share paths, hostnames, and generated report data out of the public
repository.

## Common Commands

Dry run without waiting for a maintenance window:

```powershell
.\Invoke-PatchManager.ps1 -DryRun -Force
```

Live run without waiting for a maintenance window:

```powershell
.\Invoke-PatchManager.ps1 -Force
```

Generate a report without patching:

```powershell
.\Invoke-PatchManager.ps1 -ReportOnly -Force
```

Install a startup/logon scheduled task:

```powershell
.\Invoke-PatchManager.ps1 -InstallStartupTask -TaskName "PatchManager Personal" -TaskDelayMinutes 2
```

## Report Statuses

- `Planned`: dry-run action that would be attempted.
- `Succeeded`: update was applied and verified.
- `Updated`: version changed after an update action.
- `AlreadyCurrent`: provider checked and found the item current.
- `Skipped`: intentionally not patched in this run.
- `Descoped`: excluded by profile or `Descope` configuration.
- `Blocked`: update could not proceed, commonly because the app was open.
- `Failed`: provider or update action failed.
- `Verifying`: update command completed, but final state needs confirmation.
- `Completed`: source/provider check completed; this is audit evidence, not an
  applied package update.

The HTML report separates actionable package updates from source/provider
checks so audit rows such as `WinGet source: msstore` or
`Microsoft.Store.ClientUpdates` do not look like package updates.

## Tests

Run the lightweight static and fixture tests:

```powershell
.\Tests\Invoke-PatchManager.Static.Tests.ps1
```

The test script validates parser health, config JSON, report grouping, applied
update counters, and absence of obvious personal paths in public files.

## Data Hygiene

Do not commit these generated directories:

- `Cache/`
- `Logs/`
- `Reports/`
- `State/`

They may contain hostnames, local user paths, package inventories, update
history, and report data.
