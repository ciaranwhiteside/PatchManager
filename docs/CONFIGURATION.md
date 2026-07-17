# Configuration guide

PatchManager works without a configuration file. Built-in defaults use the
`Personal` profile. Create `PatchManager.config.json` only for values you need
to override:

```powershell
Copy-Item .\PatchManager.config.example.json .\PatchManager.config.json
.\Invoke-PatchManager.ps1 -ValidateConfig
.\Invoke-PatchManager.ps1 -DryRun -Force
```

`-ValidateConfig` is read-only and does not require elevation. Live and dry-run
provider execution still requires an Administrator session.

Configuration is fail-closed. If an override file exists but contains invalid
JSON, an unknown key, a wrong value type, an invalid regular expression, or an
unknown profile, PatchManager exits with code `2` without running self-update
or a patch provider. A missing override file is valid and uses built-in
defaults.

[`PatchManager.config.schema.json`](../PatchManager.config.schema.json) is the
machine-readable schema for editor completion and deployment-pipeline
validation. Keys beginning with `_` are comments and are ignored by the
runtime.

## Choose a profile

| Profile | Patching ownership |
|---|---|
| `Personal` | PatchManager owns all enabled providers; no fleet jitter or BITS throttle by default. |
| `Commercial` | Full provider coverage plus fleet jitter and temporary BITS throttling. |
| `CommercialManaged` | Intune/SCCM/RMM owns Windows, Office, browsers, Scoop, Python, and native vendor flows; PatchManager covers the remaining third-party gap. |

PatchManager never guesses when a profile is misspelled. Correct the config
and validate again.

## Safe rollout

1. Validate the configuration.
2. Run `-DryRun -Force` on one Pilot device.
3. Review the HTML and JSON evidence, especially `Descoped` rows.
4. Run a live Pilot update.
5. Promote to Early and Broad only after the central fleet report is healthy.

The complete key-by-key reference remains in the
[README configuration reference](../README.md#configuration-reference). The
example file contains every commonly changed key.

## Provider verification contract

| Provider | Discovery | Success evidence |
|---|---|---|
| WinGet | Structured module, or CLI table fallback | Real process exit code plus result status; later runs rediscover remaining offers. |
| Windows Update | Windows Update Agent COM | Per-update result code and reboot flag. |
| Microsoft Store | Store CLI or MDM bridge | AppX version delta or follow-up offer disappearance; otherwise `Blocked`/`Verifying`. |
| Microsoft 365 | Click-to-Run registry/client | Client exit code, scenario state, and version delta where available. |
| Chrome/Edge/native vendors | Vendor updater executable | Zero exit code and before/after version; unobservable versions remain `Verifying`. |
| Chocolatey | Machine-readable `outdated` output | Zero discovery/upgrade exit code; reboot success codes handled explicitly. |
| Scoop | Bucket refresh and update commands | Both commands must return zero. |
| Python Install Manager | JSON runtime inventory | Runtime version is re-read after update; the exit code alone is insufficient. |

## SLA scope

SLA state tracks eligible WinGet upgrade offers because WinGet supplies a
stable package ID and target version before patching. Report-only runs advance
this evidence; dry runs remain non-mutating. Windows Update, Store-client,
Office, browser, Chocolatey, Scoop, Python, firmware, and vendor-summary rows
are visible in each report but are not currently included in the availability
SLA clock.

If an exact WinGet offer disappears after a healthy discovery, its open record
is closed as resolved rather than breached forever. This covers external
installation, supersedence, removal, and later descoping. A failed source
discovery never closes records.
