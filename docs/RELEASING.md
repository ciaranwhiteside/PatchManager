# Release, upgrade, and rollback

## Scope

A release bundles the main patch script, fleet companion, public configuration
example/schema, documentation, tests, and packaging tool. Runtime configuration,
logs, reports, caches, state, local design files, and internal decks are excluded.
Release preparation does not publish a GitHub release or tag.

## Upgrade an installation

1. Download the versioned ZIP and its .sha256 sidecar from the chosen release.
   Compare the archive hash before extraction:

   ```powershell
   $archive = '.\PatchManager-v1.8.1.zip'
   $expected = ((Get-Content -LiteralPath "$archive.sha256" -Raw).Trim() -split '\s+')[0]
   if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $expected) {
       throw 'Release archive checksum mismatch.'
   }
   Expand-Archive -LiteralPath $archive -DestinationPath .\PatchManager-staged
   ```

   A matching checksum detects corruption; it is not an independent signature
   or proof of publisher identity. Obtain the checksum from the intended release.
2. Pause the relevant scheduled task and allow an active run to finish. Back up
   the installed scripts and configuration to an administrator-controlled path.
3. Copy the public release files into the installation. Keep the existing
   PatchManager.config.json and runtime directories; do not substitute the
   example config. Refresh Get-FleetReport.ps1 wherever fleet aggregation runs.
4. Unblock the downloaded scripts after reviewing them, validate configuration,
   and preview from an elevated shell in the installation directory:

   ```powershell
   .\Invoke-PatchManager.ps1 -ValidateConfig
   .\Invoke-PatchManager.ps1 -DryRun -Force
   ```

5. Review the resulting evidence, perform an approved live Pilot run, then resume
   scheduling and promote through your rollout rings.

Self-update refreshes only Invoke-PatchManager.ps1, including for ZIP installs.
It does not deliver fleet fixes, docs, or schemas. Git installs may have a local
main-script modification after self-update: review git status before updating
the checkout, and do not discard configuration or local work to make a pull pass.
SelfUpdate.ExpectedSha256 must use the main-script hash from SHA256SUMS.txt,
not the archive hash. A previous hash pin deliberately blocks a new version.

## Rollback

Pause scheduling and allow an active run to finish. Restore the previous trusted
scripts and their compatible configuration, then validate and preview before
resuming. Disable automatic self-update or pin SelfUpdate.Ref to the previous
release tag so a rollback is not replaced on the next run. Keep audit logs and
reports. Restoring PatchManager does not uninstall software updates already
applied; use the relevant Windows/vendor recovery process for those changes.

## Prepare a release

1. Choose the next version. Update the runtime VERSION literal, help header,
   README beta label, and changelog together. Keep an Unreleased section above
   versioned entries. Add docs/releases/<version>.md with compatibility, upgrade,
   verification, and remaining checks.
2. From the repository root, run the automated gates:

   ```powershell
   powershell -NoProfile -File .\Tests\Invoke-PatchManager.Static.Tests.ps1
   pwsh -NoProfile -File .\Tests\Invoke-PatchManager.Static.Tests.ps1
   .\Tests\Test-Documentation.ps1
   .\Invoke-PatchManager.ps1 -ValidateConfig -ConfigPath .\PatchManager.config.example.json
   $findings = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1)
   $findings | Format-Table RuleName, Severity, ScriptName, Line, Message
   if (@($findings | Where-Object Severity -eq 'Error').Count) { throw 'Lint failed.' }
   ```

3. For reporting changes, run the [browser checks](../README.md#tests). Review
   generated desktop/mobile examples as well as automatic results. Fixtures are
   synthetic evidence; never publish operational reports as samples.
4. Build into a new output location:

   ```powershell
   .\Build-Release.ps1
   ```

   The builder reads the runtime version and public source files. It refuses to
   overwrite an existing package. It writes the ZIP, .sha256 sidecar, and release
   notes under release/. The ZIP has no enclosing directory and contains a
   SHA256SUMS.txt manifest. Every archived payload hash is verified before the
   package is returned. Fixed ZIP entry timestamps and sorted paths make repeated
   builds reproducible under the same runtime. The manifest detects corruption,
   not trust or code-signing provenance. The builder is not a substitute for tests.
5. Inspect package contents and record the source commit and ZIP checksum. Build
   again from the final reviewed commit if sources changed after verification.

## Machine and publication gates

Run elevated dry-run smoke checks on supported Windows 10 and Windows 11 pilot
hosts using both supported PowerShell engines. Record actual OS/build, engine,
configuration profile, exit code, and evidence location. Check pending-reboot and
maintenance deferrals as well as a successful discovery path. Obtain live
provider evidence through an approved Pilot update; fixtures do not validate
Windows Update, Store, Office, or vendor integrations.

After review and successful machine checks, commit the exact release sources,
tag that commit v<version>, and prepare the GitHub release with its matching ZIP,
checksum, and notes. Review draft/pre-release settings deliberately: the default
self-updater resolves GitHub's latest published non-prerelease tag and downloads
the main script from that tag. Publishing can therefore distribute elevated code
to installations with automatic self-update enabled. Publish only the reviewed
commit and package; do not reuse a tag for different code.

Keep a release record of the commit/tag, artifacts and hashes, automated results,
machine checks, known limitations, and approval to publish. Local package creation
alone does not establish any of those external gates.