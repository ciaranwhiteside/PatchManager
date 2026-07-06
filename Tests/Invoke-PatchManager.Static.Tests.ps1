#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-PatchManager.ps1'
$exampleConfigPath = Join-Path $root 'PatchManager.config.example.json'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-FunctionTextFromScriptAst {
    param(
        [Parameter(Mandatory)] $Ast,
        [Parameter(Mandatory)] [string]$Name
    )
    $functionAst = $Ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true)
    Assert-True ($null -ne $functionAst) "Function '$Name' was not found."
    return $functionAst.Extent.Text
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $scriptPath), [ref]$tokens, [ref]$errors)
Assert-True ($errors.Count -eq 0) "PowerShell parser errors:`n$($errors | Out-String)"

Get-Content -Path $exampleConfigPath -Raw | ConvertFrom-Json | Out-Null

Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-PatchResult')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-PatchResult')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Update-StatsFromResults')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-HTMLReport')

$dialogText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Show-PatchManagerDialog'
$appPromptText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Show-AppInUsePrompt'
$completionPromptText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Show-CompletionPopup'
Assert-True ($dialogText -match 'Patch\. Verify\. Prove it\.') 'User dialogs should include the PatchManager brand tagline.'
Assert-True ($dialogText -match 'Evidence-led Windows patching') 'User dialogs should include brand-aligned provenance copy.'
Assert-True ($dialogText -match 'FromArgb\(17, 21, 19\)') 'User dialogs should use the Charcoal Ink brand color.'
Assert-True ($dialogText -match 'FromArgb\(246, 242, 232\)') 'User dialogs should use the Ivory Paper brand color.'
Assert-True ($dialogText -match 'FromArgb\(24, 50, 74\)') 'User dialogs should use the Audit Blue brand color.'
Assert-True ($dialogText -match 'FromArgb\(36, 116, 79\)') 'User dialogs should use the Verified Green brand color.'
Assert-True ($dialogText -match 'FromArgb\(196, 154, 61\)') 'User dialogs should use the Caution Amber brand color in the mark.'
Assert-True ($dialogText -match 'DrawBeziers') 'User dialogs should draw the PatchManager ledger curve in the brand mark.'
Assert-True ($appPromptText -match 'Close the app to verify the update') 'App-in-use prompts should use evidence-led wording.'
Assert-True ($completionPromptText -match 'Patch evidence is ready') 'Completion popups should use evidence-led wording.'

$script:Stats = [ordered]@{
    UpdatesPlanned = 0
    UpdatesApplied = 0
    UpdatesFailed = 0
    UpdatesSkipped = 0
    KEVMatches = 0
    SLABreaches = 0
    InventoryCount = 116
    Errors = [System.Collections.Generic.List[string]]::new()
}
$script:HOSTNAME = 'TEST-HOST'
$script:RING = 'Pilot'
$script:STARTTIME = Get-Date
$script:VERSION = 'test'
$script:EmergencyPatch = $false
$script:CFG = [pscustomobject]@{ SLA = [pscustomobject]@{ Critical = 14 } }
$DryRun = [System.Management.Automation.SwitchParameter]::new($false)

$sourceRows = @(
    New-PatchResult -Name 'WinGet source: winget' -PackageId 'WinGet.Source.winget' -Source 'winget' -Provider 'winget-discovery' -Status 'Completed' -Success $true -Evidence 'parsed 0 rows'
    New-PatchResult -Name 'WinGet source: msstore' -PackageId 'WinGet.Source.msstore' -Source 'msstore' -Provider 'winget-msstore-discovery' -Status 'Completed' -Success $true -Evidence 'parsed 0 rows'
    New-PatchResult -Name 'Microsoft Store library updates' -PackageId 'Microsoft.Store.ClientUpdates' -Source 'store-client' -Provider 'microsoft-store-client' -Status 'Completed' -Success $true -Evidence 'Store CLI discovery completed; no Store updates were reported.'
)

Update-StatsFromResults -Results $sourceRows
Assert-True ($script:Stats.UpdatesApplied -eq 0) 'Completed source/provider checks must not count as applied updates.'

$updatedRows = @(
    $sourceRows
    New-PatchResult -Name 'NanaZip' -PackageId '40174MouriNaruto.NanaZip_gnj4mf6z9tkrc' -Source 'store-client' -Provider 'microsoft-store-client' -InstalledVersion '1.0.0.0' -AvailableVersion '1.0.1.0' -ConfirmedVersion '1.0.1.0' -Status 'Succeeded' -Success $true -Evidence 'Verified by AppX version change.'
    New-PatchResult -Name 'Example App' -PackageId 'Example.App' -Source 'store-client' -Provider 'microsoft-store-client' -InstalledVersion '2.0.0.0' -AvailableVersion '2.0.1.0' -ConfirmedVersion '2.0.1.0' -Status 'Updated' -Success $true -Evidence 'Version changed.'
)

Update-StatsFromResults -Results $updatedRows
Assert-True ($script:Stats.UpdatesApplied -eq 2) 'Succeeded and Updated app rows must count as applied updates.'

$html = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{
    AvgDaysToApply = 'N/A'
    TotalTracked = 0
    Applied = 0
    Pending = 0
})
Assert-True ($html -match 'Source and provider checks') 'HTML report should include source/provider checks.'
Assert-True ($html -match 'WinGet source: winget') 'HTML report should show winget source check.'
Assert-True ($html -match 'WinGet source: msstore') 'HTML report should show msstore source check.'
Assert-True ($html -match 'Microsoft Store library updates') 'HTML report should show Microsoft Store client check.'
Assert-True ($html -match '0 action row\(s\)') 'Source checks alone should not create actionable update rows.'
Assert-True ($html -match 'class="bento-board') 'HTML report should include the audit summary board.'
Assert-True ($html -match 'class="report-nav') 'HTML report should include the sticky report command navigation.'
Assert-True ($html -match 'class="evidence-rail') 'HTML report should include the pinned evidence trail.'
Assert-True ($html -match 'class="report-lanes') 'HTML report should include horizontal report lanes.'
Assert-True ($html -match 'No package updates required action') 'HTML report should preserve the composed zero-action empty state.'
Assert-True ($html -match 'https://github.com/ciaranwhiteside/PatchManager') 'HTML report footer should link to the PatchManager repository.'
Assert-True ($html -match 'class="brand-mark"') 'HTML report should include the inline PatchManager brand mark.'
Assert-True ($html -match '#c49a3d') 'HTML report brand mark should include the amber ledger curve.'
Assert-True ($html -match 'Patch\. Verify\. Prove it\.') 'HTML report should include the PatchManager brand tagline.'
Assert-True ($html -match '--charcoal:#111513') 'HTML report should use the Charcoal Ink brand token.'
Assert-True ($html -match '--paper:#f6f2e8') 'HTML report should use the Ivory Paper brand token.'
Assert-True ($html -match '--blue:#18324a') 'HTML report should use the Audit Blue brand token.'
Assert-True ($html -match '--green:#24744f') 'HTML report should use the Verified Green brand token.'
Assert-True ($html -match '--red:#a53b35') 'HTML report should use the Exposure Red brand token.'
Assert-True ($html -match '--amber-curve:#c49a3d') 'HTML report should use the Caution Amber ledger token.'
Assert-True ($html -match 'Segoe UI Variable') 'HTML report should use the Windows-safe brand font stack.'
Assert-True ($html -match 'Cascadia Mono') 'HTML report should use Cascadia/Consolas for evidence values.'
Assert-True ($html -match 'Skip to update table') 'HTML report should include keyboard skip navigation.'
Assert-True ($html -match "querySelectorAll\('tr\.data-row'\)") 'HTML report filters should discover options from all report rows.'
Assert-True ($html -match 'report row\(s\) visible') 'HTML report filter count should describe all report rows.'
Assert-True ($html -match 'margin:44px 0 52px') 'HTML report content should leave breathing room below the hero.'
Assert-True ($html -notmatch 'cdnjs|unpkg|fonts\.googleapis|picsum|gsap') 'HTML report should stay offline with no CDN, remote font, image, or GSAP dependency.'
Assert-True ($html -notmatch 'hero-visual|telemetry-strip|pulseBars') 'HTML report should not include decorative animated hero telemetry.'
Assert-True ($html -notmatch '\.hero:before') 'HTML report hero should not include decorative pseudo-art.'
Assert-True ($html -match '<noscript><style>\.reveal\{opacity:1') 'HTML report must stay readable when JavaScript is disabled.'
Assert-True ($html -match '@media print\{[^@]*\.reveal\{opacity:1 !important') 'HTML report reveal sections must always print.'
Assert-True ($html -match 'prefers-reduced-motion') 'HTML report should respect reduced-motion preferences.'

$actionHtml = New-HTMLReport -Results $updatedRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{
    AvgDaysToApply = 'N/A'
    TotalTracked = 0
    Applied = 0
    Pending = 0
})
Assert-True ($actionHtml -match "id=['""]updatesTable['""]") 'HTML report should preserve the interactive updates table when action rows exist.'

$commercialRow = New-PatchResult -Name 'Google Chrome' -PackageId 'Google.Chrome' -Source 'winget' -Provider 'winget' -Status 'Descoped' -Evidence 'Commercial provider-managed browser.'
Update-StatsFromResults -Results @($commercialRow)
Assert-True ($script:Stats.UpdatesSkipped -eq 1) 'Descoped rows should be counted as skipped/descoped, not hidden.'

#-- Stub out logging for functions under test that log ------------------------------
function Write-Log { param([string]$Message, [string]$Level = 'INFO') }

#-- WinGet upgrade table parser (fixtures) ------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertFrom-WinGetUpgradeOutput')

$fixtureDir = Join-Path $PSScriptRoot 'Fixtures'

$sampleLines = Get-Content -Path (Join-Path $fixtureDir 'winget-upgrade-sample.txt')
$sampleParse = ConvertFrom-WinGetUpgradeOutput -Lines $sampleLines -QuerySource 'winget'
Assert-True ($sampleParse.SawHeader) 'Sample fixture: header row should be detected.'
Assert-True ($sampleParse.Upgrades.Count -eq 3) "Sample fixture: expected 3 upgrades, got $($sampleParse.Upgrades.Count)."
$chrome = $sampleParse.Upgrades | Where-Object { $_.PackageId -eq 'Google.Chrome' }
Assert-True ($null -ne $chrome) 'Sample fixture: Google.Chrome row should parse.'
Assert-True ($chrome.Version -eq '125.0.6422.1') "Sample fixture: Chrome installed version mismatch: '$($chrome.Version)'."
Assert-True ($chrome.Available -eq '126.0.6478.5') "Sample fixture: Chrome available version mismatch: '$($chrome.Available)'."
Assert-True ($chrome.Source -eq 'winget') 'Sample fixture: Chrome source should be winget.'

$edgeLines = Get-Content -Path (Join-Path $fixtureDir 'winget-upgrade-edgecases.txt')
$edgeParse = ConvertFrom-WinGetUpgradeOutput -Lines $edgeLines -QuerySource 'winget'
Assert-True ($edgeParse.Upgrades.Count -eq 2) "Edge fixture: expected 2 upgrades (dedupe + short-line skip), got $($edgeParse.Upgrades.Count)."
$noSource = $edgeParse.Upgrades | Where-Object { $_.PackageId -eq 'Vendor.SomeApp' }
Assert-True ($null -ne $noSource -and $noSource.Source -eq 'winget') 'Edge fixture: row without source column should default to the query source.'

$emptyLines = Get-Content -Path (Join-Path $fixtureDir 'winget-upgrade-empty.txt')
$emptyParse = ConvertFrom-WinGetUpgradeOutput -Lines $emptyLines -QuerySource 'msstore'
Assert-True (-not $emptyParse.SawHeader) 'Empty fixture: no header should be detected.'
Assert-True ($emptyParse.Upgrades.Count -eq 0) 'Empty fixture: no upgrades should parse.'

#-- Microsoft Store CLI failure handling --------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ObjectPropertyValue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-StoreCliUpdateCandidates')

function Invoke-StoreCliCommand {
    param([string]$StoreCli, [string[]]$Arguments, [int]$TimeoutSeconds, [string[]]$StandardInputLines = @())
    return [PSCustomObject]@{
        ExitCode = 5
        TimedOut = $false
        Failed   = $false
        Output   = 'Store app execution alias failed.'
    }
}

$storeCandidates = @(Get-StoreCliUpdateCandidates -StoreCli 'store.exe' -TimeoutSeconds 30)
Assert-True ($storeCandidates.Count -eq 0) 'Store CLI: non-zero discovery exit should not return update candidates.'
Assert-True ($script:StoreCliDiscoveryFailed) 'Store CLI: non-zero discovery exit should be marked as provider failure.'
Assert-True ($script:StoreCliDiscoveryReason -match 'code 5') 'Store CLI: discovery failure should preserve the Store exit code.'

#-- Config merge + scope profiles ---------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ObjectPropertyValue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-IsFleetProfile')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Set-ScopeProfileDefaults')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Import-Configuration')

function New-TestDefaultCfg {
    [ordered]@{
        ScopeProfile = 'Personal'
        Descope = [ordered]@{ PackageIds = @(); PackageNamePatterns = @(); Providers = @(); Sources = @(); Reasons = [ordered]@{} }
        MaintenanceWindow = [ordered]@{ Enabled = $true; JitterMaxMinutes = $null }
        Network = [ordered]@{ BITSThrottleEnabled = $null; BITSMaxBandwidthKbps = 4096 }
        WindowsUpdate = [ordered]@{ Enabled = $true }
        Microsoft365 = [ordered]@{ Enabled = $true }
        Browsers = [ordered]@{ Enabled = $true; ChromeEnabled = $true; EdgeEnabled = $true }
        PackageManagers = [ordered]@{ ChocolateyEnabled = $null; ScoopEnabled = $true }
        VendorUpdaters = [ordered]@{ Enabled = $true }
        SLA = [ordered]@{ Critical = 14 }
    }
}

$tempCfgPath = Join-Path ([System.IO.Path]::GetTempPath()) "pm-test-config-$([guid]::NewGuid()).json"
@'
{
  "_comment": "test override",
  "Network": { "_comment": "section comment should be skipped", "BITSMaxBandwidthKbps": 1024 },
  "SLA": { "Critical": 7 },
  "UnknownSection": { "Ignored": true }
}
'@ | Set-Content -Path $tempCfgPath -Encoding UTF8

try {
    $script:DefaultCfg = New-TestDefaultCfg
    $mergedCfg = Import-Configuration -Path $tempCfgPath
    Assert-True ($mergedCfg.Network.BITSMaxBandwidthKbps -eq 1024) 'Config merge: overridden scalar should win.'
    Assert-True ($mergedCfg.SLA.Critical -eq 7) 'Config merge: SLA override should apply.'
    Assert-True ($mergedCfg.Network.Contains('BITSThrottleEnabled')) 'Config merge: unlisted defaults should survive a partial section override.'
    Assert-True (-not $mergedCfg.Network.Contains('_comment')) 'Config merge: section-level _comment keys should be skipped.'
    Assert-True (-not $mergedCfg.Contains('UnknownSection')) 'Config merge: unknown sections should be ignored.'
    Assert-True ($mergedCfg.Network.BITSThrottleEnabled -eq $false) 'Personal profile should resolve BITSThrottleEnabled to false.'
    Assert-True ($mergedCfg.MaintenanceWindow.JitterMaxMinutes -eq 0) 'Personal profile should resolve JitterMaxMinutes to 0 - a single device should not delay itself.'

    # Commercial = FULL coverage + fleet behaviours. It must never silently
    # disable protection - that assumption belongs to CommercialManaged only.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Commercial'
    $commercialCfg = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($commercialCfg.Network.BITSThrottleEnabled -eq $true) 'Commercial profile should resolve BITSThrottleEnabled to true.'
    Assert-True ($commercialCfg.MaintenanceWindow.JitterMaxMinutes -eq 120) 'Commercial profile should resolve JitterMaxMinutes to 120 for fleet staggering.'
    Assert-True ($commercialCfg.WindowsUpdate.Enabled -eq $true) 'Commercial profile must keep Windows Update enabled - full coverage is the safe org default.'
    Assert-True ($commercialCfg.Microsoft365.Enabled -eq $true) 'Commercial profile must keep Microsoft 365 enabled.'
    Assert-True ($commercialCfg.Browsers.ChromeEnabled -eq $true) 'Commercial profile must keep browser patching enabled.'
    Assert-True ('Google.Chrome' -notin $commercialCfg.Descope.PackageIds) 'Commercial profile must not descope Chrome - only CommercialManaged assumes a platform owns it.'
    Assert-True ($commercialCfg.VendorUpdaters.Enabled -eq $true) 'Commercial profile must keep native vendor updaters enabled.'
    Assert-True ($commercialCfg.PackageManagers.ScoopEnabled -eq $true) 'Commercial profile must keep Scoop enabled.'
    Assert-True ($commercialCfg.PackageManagers.ChocolateyEnabled -eq $false) 'Commercial profile must leave Chocolatey off by default - enabling it is an explicit licence decision.'

    # CommercialManaged = the explicit "our platform owns OS/Office/browsers" posture.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'CommercialManaged'
    $managedCfg = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($managedCfg.Network.BITSThrottleEnabled -eq $true) 'CommercialManaged profile should resolve BITSThrottleEnabled to true.'
    Assert-True ($managedCfg.MaintenanceWindow.JitterMaxMinutes -eq 120) 'CommercialManaged profile should resolve JitterMaxMinutes to 120.'
    Assert-True ($managedCfg.WindowsUpdate.Enabled -eq $false) 'CommercialManaged profile should disable Windows Update provider.'
    Assert-True ($managedCfg.Microsoft365.Enabled -eq $false) 'CommercialManaged profile should disable Microsoft 365 provider.'
    Assert-True ($managedCfg.Browsers.ChromeEnabled -eq $false) 'CommercialManaged profile should disable Chrome native updates.'
    Assert-True ('Google.Chrome' -in $managedCfg.Descope.PackageIds) 'CommercialManaged profile should descope Chrome.'
    Assert-True ($managedCfg.VendorUpdaters.Enabled -eq $false) 'CommercialManaged profile should disable native vendor updaters.'
    Assert-True ($managedCfg.PackageManagers.ScoopEnabled -eq $false) 'CommercialManaged profile should disable Scoop.'
    Assert-True ($managedCfg.PackageManagers.ChocolateyEnabled -eq $false) 'CommercialManaged profile should leave Chocolatey off.'

    # Personal resolves the licensing-gated Chocolatey default to on (free use).
    $script:DefaultCfg = New-TestDefaultCfg
    $personalCfg = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($personalCfg.PackageManagers.ChocolateyEnabled -eq $true) 'Personal profile should resolve Chocolatey to on (the CLI is free for personal use).'

    # An explicit Chocolatey value in config must override the profile default.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Commercial'
    $script:DefaultCfg.PackageManagers.ChocolateyEnabled = $true
    $explicitChoco = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($explicitChoco.PackageManagers.ChocolateyEnabled -eq $true) 'An explicit ChocolateyEnabled=true must win over the commercial-off default.'

    # Unknown profile values must fail SAFE: full Personal coverage.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Enterprise'
    $unknownCfg = Import-Configuration -Path 'nonexistent-config.json' 3>$null
    Assert-True ($unknownCfg.ScopeProfile -eq 'Personal') 'Unknown ScopeProfile should fall back to Personal (full coverage).'
    Assert-True ($unknownCfg.WindowsUpdate.Enabled -eq $true) 'Unknown ScopeProfile fallback must keep full coverage.'
} finally {
    Remove-Item $tempCfgPath -Force -EA SilentlyContinue
}

#-- Chocolatey outdated parser ------------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertFrom-ChocoOutdated')
$chocoLines = Get-Content -Path (Join-Path $PSScriptRoot 'Fixtures\choco-outdated.txt')
$chocoParsed = @(ConvertFrom-ChocoOutdated -Lines $chocoLines)
Assert-True ($chocoParsed.Count -eq 5) "Choco parser: expected 5 valid package rows (pinned filtering happens in the provider), got $($chocoParsed.Count)."
$chocoGit = $chocoParsed | Where-Object { $_.Id -eq 'git' }
Assert-True ($null -ne $chocoGit -and $chocoGit.Available -eq '2.44.0.2') 'Choco parser: git available version should parse.'
Assert-True (@($chocoParsed | Where-Object { $_.Id -eq 'notepadplusplus' })[0].Pinned) 'Choco parser: pinned flag should be captured.'
Assert-True (@($chocoParsed | Where-Object { $_.Id -eq 'somebrokenline' }).Count -eq 0) 'Choco parser: malformed lines should be ignored.'
Assert-True (@(ConvertFrom-ChocoOutdated -Lines @()).Count -eq 0) 'Choco parser: empty input should yield no rows.'

#-- Vendor updater provider ---------------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-FirstExistingPath')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-RegistryVersion')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-VendorUpdaterCatalogue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-VendorUpdaterProvider')

# Disabled provider yields nothing.
$script:CFG = [pscustomobject]@{ VendorUpdaters = [pscustomobject]@{ Enabled = $false; NativeTimeoutSeconds = 60; ExtraCatalogue = @() } }
Assert-True (@(Invoke-VendorUpdaterProvider).Count -eq 0) 'Vendor updater provider must return nothing when disabled.'

# Catalogue includes the built-in Brave entry plus any ExtraCatalogue entries.
$script:CFG = [pscustomobject]@{ VendorUpdaters = [pscustomobject]@{ Enabled = $true; NativeTimeoutSeconds = 60; ExtraCatalogue = @([pscustomobject]@{ Name = 'Test App'; Provider = 'test-update' }) } }
$catalogue = @(Get-VendorUpdaterCatalogue)
Assert-True (@($catalogue | Where-Object { $_.Provider -eq 'brave-update' }).Count -eq 1) 'Vendor catalogue should include the built-in Brave entry.'
Assert-True (@($catalogue | Where-Object { $_.Provider -eq 'test-update' }).Count -eq 1) 'Vendor catalogue should include user ExtraCatalogue entries.'

# WinGet overlap: a matching candidate makes the vendor entry defer with a Skipped row.
$DryRun = [System.Management.Automation.SwitchParameter]::new($true)
$braveEntry = @($catalogue | Where-Object { $_.Provider -eq 'brave-update' })[0]
Assert-True ($braveEntry.WinGetOverlapId -eq 'BraveSoftware.BraveBrowser') 'Brave entry should declare its WinGet overlap id for the defer check.'

#-- Staleness report (report-only) --------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-IsStale')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-StalenessFinding')
Assert-True (Test-IsStale -LastUpdated (Get-Date).AddDays(-10) -MaxAgeDays 7) 'Test-IsStale: a 10-day-old date should be stale against a 7-day threshold.'
Assert-True (-not (Test-IsStale -LastUpdated (Get-Date).AddDays(-2) -MaxAgeDays 7)) 'Test-IsStale: a 2-day-old date should not be stale against a 7-day threshold.'
Assert-True (-not (Test-IsStale -LastUpdated ([datetime]::MinValue) -MaxAgeDays 7)) 'Test-IsStale: an unknown date must not be treated as stale.'
$finding = New-StalenessFinding -Category 'Antivirus definitions' -Item 'Microsoft Defender' -Detail 'old' -Severity 'review' -Recommendation 'update'
Assert-True ($finding.Severity -eq 'review' -and $finding.Category -eq 'Antivirus definitions') 'New-StalenessFinding should carry category and severity.'

# HTML report renders the staleness panel and keeps findings out of the update counts.
$stalenessFindings = @(
    (New-StalenessFinding -Category 'Antivirus definitions' -Item 'Microsoft Defender' -Detail 'Signatures 12 days old.' -Severity 'review' -Recommendation 'Run Update-MpSignature.')
    (New-StalenessFinding -Category 'Developer runtime' -Item 'Node.js' -Detail 'Installed: v20.10.0.' -Severity 'info')
)
$stalenessHtml = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @() -StalenessFindings $stalenessFindings
Assert-True ($stalenessHtml -match 'Environment staleness') 'HTML report should render the Environment staleness panel when findings exist.'
Assert-True ($stalenessHtml -match 'Report-only exposure checks') 'Staleness panel should state it is report-only.'
Assert-True ($stalenessHtml -match 'Microsoft Defender') 'Staleness panel should list the Defender finding.'

#-- Firmware provider (opt-in, off by default) --------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-FirmwareCatalogue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-FirmwareProvider')

# Disabled everywhere by default: an absent or Enabled=$false Firmware config yields nothing.
$script:CFG = [pscustomobject]@{ Firmware = [pscustomobject]@{ Enabled = $false; TimeoutSeconds = 60 } }
Assert-True (@(Invoke-FirmwareProvider).Count -eq 0) 'Firmware provider must return nothing when disabled (the default for all profiles).'
$script:CFG = [pscustomobject]@{}
Assert-True (@(Invoke-FirmwareProvider).Count -eq 0) 'Firmware provider must return nothing when the config section is absent.'

# OEM catalogue maps the three supported manufacturers.
$fwCat = @(Get-FirmwareCatalogue)
Assert-True (@($fwCat | Where-Object { 'Dell Inc.' -imatch $_.Match }).Count -eq 1) 'Firmware catalogue should match Dell systems.'
Assert-True (@($fwCat | Where-Object { 'HP' -imatch $_.Match }).Count -eq 1) 'Firmware catalogue should match HP systems.'
Assert-True (@($fwCat | Where-Object { 'LENOVO' -imatch $_.Match }).Count -eq 1) 'Firmware catalogue should match Lenovo systems.'
Assert-True (@($fwCat | Where-Object { 'VMware, Inc.' -imatch $_.Match }).Count -eq 0) 'Firmware catalogue should not match a non-OEM manufacturer.'

#-- Descoping -----------------------------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-DescopeReason')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-IsDescoped')

$script:CFG = [pscustomobject]@{
    SLA = [pscustomobject]@{ Critical = 14 }
    Descope = [pscustomobject]@{
        PackageIds          = @('Google.Chrome')
        PackageNamePatterns = @('^Microsoft\s+Teams\b')
        Providers           = @('edge-update')
        Sources             = @('msstore')
        Reasons             = [pscustomobject]@{ 'Google.Chrome' = 'Managed by provider X.' }
    }
}

$reasonOut = ''
Assert-True (Test-IsDescoped -Item ([pscustomobject]@{ Name='Google Chrome'; PackageId='Google.Chrome'; Provider='winget'; Source='winget' }) -Reason ([ref]$reasonOut)) 'Descope: package id prefix should match.'
Assert-True ($reasonOut -eq 'Managed by provider X.') 'Descope: custom reason should be returned for the matched key.'
$reasonOut = ''
Assert-True (Test-IsDescoped -Item ([pscustomobject]@{ Name='Microsoft Teams'; PackageId='X.Y'; Provider='winget'; Source='winget' }) -Reason ([ref]$reasonOut)) 'Descope: name pattern should match.'
$reasonOut = ''
Assert-True (Test-IsDescoped -Item ([pscustomobject]@{ Name='Edge'; PackageId='Z'; Provider='edge-update'; Source='native' }) -Reason ([ref]$reasonOut)) 'Descope: provider should match case-insensitively.'
$reasonOut = ''
Assert-True (Test-IsDescoped -Item ([pscustomobject]@{ Name='Store App'; PackageId='A.B'; Provider='winget-msstore'; Source='msstore' }) -Reason ([ref]$reasonOut)) 'Descope: source should match.'
$reasonOut = ''
Assert-True (-not (Test-IsDescoped -Item ([pscustomobject]@{ Name='7-Zip'; PackageId='7zip.7zip'; Provider='winget'; Source='winget' }) -Reason ([ref]$reasonOut))) 'Descope: unrelated package should not match.'

#-- Maintenance window math ---------------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-MaintenanceWindow')

$Force = [System.Management.Automation.SwitchParameter]::new($false)
$script:CFG = [pscustomobject]@{
    MaintenanceWindow = [pscustomobject]@{
        Enabled = $true
        StartHour = 22
        EndHour = 6
        AllowedDays = @('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
        JitterMaxMinutes = 0
    }
}

# 2026-01-05 is a Monday
Assert-True (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 23:30')) 'Window: 23:30 should be inside an overnight 22-6 window.'
Assert-True (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 05:59')) 'Window: 05:59 should be inside an overnight 22-6 window.'
Assert-True (-not (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 12:00'))) 'Window: midday should be outside an overnight 22-6 window.'
Assert-True (-not (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 06:00'))) 'Window: EndHour itself should be outside the window.'

$script:CFG.MaintenanceWindow.AllowedDays = @('Sunday')
Assert-True (-not (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 23:30'))) 'Window: disallowed day should be outside the window.'

$script:CFG.MaintenanceWindow.Enabled = $false
Assert-True (Test-MaintenanceWindow -Now ([datetime]'2026-01-05 12:00')) 'Window: disabled window should always pass.'

#-- SLA state lifecycle --------------------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Set-ContentAtomic')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-PatchState')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Save-PatchState')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-SLABreaches')

$tempStateDir = Join-Path ([System.IO.Path]::GetTempPath()) "pm-test-state-$([guid]::NewGuid())"
$script:CFG = [pscustomobject]@{
    State   = [pscustomobject]@{ StatePath = $tempStateDir; StateFile = 'patch_state.json' }
    SLA     = [pscustomobject]@{ Critical = 14 }
    Logging = [pscustomobject]@{ RetentionDays = 90 }
}
$script:RING = 'Pilot'

try {
    $state = Get-PatchState
    Assert-True (@($state.TrackedUpdates).Count -eq 0) 'SLA state: fresh state should have no tracked updates.'

    $upgradeSeen = [pscustomobject]@{ PackageId = 'Vendor.App'; Name = 'Vendor App'; Available = '2.0'; Version = '1.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @($upgradeSeen) -AppliedResults @()
    Assert-True (@($state.TrackedUpdates).Count -eq 1) 'SLA state: newly available update should be tracked.'
    Assert-True (-not $state.TrackedUpdates[0].Applied) 'SLA state: tracked update should start unapplied.'

    Assert-True (@(Get-SLABreaches -State $state).Count -eq 0) 'SLA state: fresh tracked update should not breach.'

    # Force a breach by back-dating the SLA due date
    $state.TrackedUpdates[0].SLADue = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
    Assert-True (@(Get-SLABreaches -State $state).Count -eq 1) 'SLA state: past-due unapplied update should breach.'

    # Applying the update clears the breach
    $appliedRow = [pscustomobject]@{ PackageId = 'Vendor.App'; Success = $true; Status = 'Succeeded'; ConfirmedVersion = '2.0'; AvailableVersion = '2.0'; NewVer = '2.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @() -AppliedResults @($appliedRow)
    Assert-True ($state.TrackedUpdates[0].Applied) 'SLA state: applied result should mark the tracked update applied.'
    Assert-True (@(Get-SLABreaches -State $state).Count -eq 0) 'SLA state: applied update should no longer breach.'

    # State survives a round-trip through the JSON file
    $state2 = Get-PatchState
    Assert-True (@($state2.TrackedUpdates).Count -eq 1) 'SLA state: state file round-trip should preserve tracked updates.'
    Assert-True ($state2.TrackedUpdates[0].Applied) 'SLA state: applied flag should persist to disk.'
} finally {
    Remove-Item $tempStateDir -Recurse -Force -EA SilentlyContinue
}

#-- PendingFileRenameOperations benign filtering ------------------------------------
# Mirrors the filter logic in Test-PendingReboot: Xbox Gaming Services proxy DLL
# cleanup is benign and must not be treated as a real pending reboot, while a
# genuine pending rename still counts.
$benignPfroPatterns = @('gamingservices', 'gamingservicesproxy')
$benignPfroRegex = ($benignPfroPatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
function Select-RealPfroEntries {
    param([string[]]$Entries)
    return @($Entries | Where-Object {
        $entry = [string]$_
        (-not [string]::IsNullOrWhiteSpace($entry)) -and ($entry -inotmatch $benignPfroRegex)
    })
}

Assert-True ((Select-RealPfroEntries @('*1\??\C:\Windows\System32\gamingservicesproxy_11.dll.0', '')).Count -eq 0) 'PFRO: gaming-services-only entries should not count as a pending reboot.'
Assert-True ((Select-RealPfroEntries @('\??\C:\Windows\System32\realupdate.dll', '\??\C:\Windows\System32\realupdate.dll.new')).Count -eq 2) 'PFRO: genuine pending renames should count.'
Assert-True ((Select-RealPfroEntries @('*1\??\C:\Windows\System32\gamingservices_host.dll.0', '', '\??\C:\Windows\real.dll', '')).Count -eq 1) 'PFRO: real renames should survive alongside benign gaming-services entries.'
Assert-True ((Select-RealPfroEntries @('', '')).Count -eq 0) 'PFRO: empty entries should not count.'

#-- Self-update version parsing -----------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ScriptVersionFromContent')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-SelfUpdateSource')

Assert-True ((Get-ScriptVersionFromContent -Content "`$script:VERSION       = '1.0.0'") -eq '1.0.0') 'Self-update: version literal should be parsed from script content.'
Assert-True ($null -eq (Get-ScriptVersionFromContent -Content 'no version here')) 'Self-update: missing version should return null.'
Assert-True ($null -eq (Get-ScriptVersionFromContent -Content '')) 'Self-update: empty content should return null.'
# The live script must expose a parseable version to the self-updater
$selfVer = Get-ScriptVersionFromContent -Content (Get-Content -Path $scriptPath -Raw)
Assert-True ($null -ne $selfVer) 'Self-update: the current script must expose a version literal.'
Assert-True ($null -ne ([version]$selfVer)) 'Self-update: the current script version must parse as [version].'
Assert-True (Test-SelfUpdateSource -Repository 'ciaranwhiteside/PatchManager' -Ref 'main') 'Self-update: default GitHub source should validate.'
Assert-True (Test-SelfUpdateSource -Repository 'owner-name/repo.name' -Ref 'release/v1.2.3') 'Self-update: normal branch/tag refs should validate.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'https://github.com/owner/repo' -Ref 'main')) 'Self-update: repository must be owner/name, not a URL.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'owner/repo' -Ref '../main')) 'Self-update: ref traversal should be rejected.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'owner/repo' -Ref 'main?raw=1')) 'Self-update: refs with URL metacharacters should be rejected.'

#-- Scheduled-run UX regressions -----------------------------------------------------
# Live-session assertions would be flaky on session-0 CI runners, so assert on
# the function/task-builder source instead.
$interactiveFnText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-InteractiveSession'
Assert-True ($interactiveFnText -notmatch 'SESSIONNAME') 'Test-InteractiveSession must not depend on SESSIONNAME - Task Scheduler never sets it, which suppressed all popups on scheduled runs.'
Assert-True ($interactiveFnText -match 'SessionId') 'Test-InteractiveSession should gate on the process session id (session 0 = services).'

$taskInstallText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Install-PatchManagerStartupTask'
Assert-True ($taskInstallText -match '-WindowStyle Hidden') 'The startup task must run PowerShell hidden so scheduled runs stay in the background.'

#-- Public file hygiene ---------------------------------------------------------------
$publicFiles = @(
    'Invoke-PatchManager.ps1'
    'Get-FleetReport.ps1'
    'PatchManager.config.example.json'
    'README.md'
    'SECURITY.md'
    'CHANGELOG.md'
    'CODE_OF_CONDUCT.md'
    'CONTRIBUTING.md'
    'docs/brand/BRAND.md'
    'docs/brand/patchmanager-mark.svg'
    'docs/brand/patchmanager-wordmark.svg'
    'docs/brand/patchmanager-brand-board.svg'
    '.github/pull_request_template.md'
    '.github/ISSUE_TEMPLATE/bug_report.md'
    '.github/ISSUE_TEMPLATE/feature_request.md'
    '.gitignore'
    'LICENSE'
)
$forbiddenPathOne = 'C:\\' + 'Users\\'
$forbiddenPathTwo = 'C:\\' + ('Patch' + 'Manager' + 'Test')
$forbiddenHost = 'DESK' + 'TOP-'
$forbiddenUserPath = ('Cia' + 'ran') + '\\AppData'
$forbidden = "$forbiddenPathOne|$forbiddenPathTwo|$forbiddenHost|$forbiddenUserPath"
foreach ($file in $publicFiles) {
    $path = Join-Path $root $file
    Assert-True (Test-Path $path) "Expected public file missing: $file"
    $content = Get-Content -Path $path -Raw
    Assert-True ($content -notmatch $forbidden) "Forbidden personal/local path found in $file"
}

$readme = Get-Content -Path (Join-Path $root 'README.md') -Raw
Assert-True ($readme -match 'docs/brand/patchmanager-wordmark\.svg') 'README should reference the PatchManager wordmark asset.'
Assert-True ($readme -match 'docs/brand/BRAND\.md') 'README should link to the PatchManager brand guide.'
Assert-True ($readme -match 'docs/images/report-sample\.png') 'README should show the local report screenshot.'
Assert-True ($readme -match 'docs/images/fleet-report-sample\.png') 'README should show the fleet report screenshot.'
Assert-True ($readme -match 'docs/images/user-app-in-use-prompt\.png') 'README should show the app-in-use prompt screenshot.'
Assert-True ($readme -match 'docs/images/user-completion-popup\.png') 'README should show the completion popup screenshot.'
Assert-True (Test-Path (Join-Path $root 'docs/images/report-sample.png')) 'Local report screenshot should exist.'
Assert-True (Test-Path (Join-Path $root 'docs/images/fleet-report-sample.png')) 'Fleet report screenshot should exist.'
Assert-True (Test-Path (Join-Path $root 'docs/images/user-app-in-use-prompt.png')) 'App-in-use prompt screenshot should exist.'
Assert-True (Test-Path (Join-Path $root 'docs/images/user-completion-popup.png')) 'Completion popup screenshot should exist.'
$brandMark = Get-Content -Path (Join-Path $root 'docs/brand/patchmanager-mark.svg') -Raw
$brandWordmark = Get-Content -Path (Join-Path $root 'docs/brand/patchmanager-wordmark.svg') -Raw
$brandBoard = Get-Content -Path (Join-Path $root 'docs/brand/patchmanager-brand-board.svg') -Raw
Assert-True ($brandMark -match '#C49A3D') 'Canonical brand mark should include the amber ledger curve.'
Assert-True ($brandWordmark -match '#C49A3D') 'Wordmark should use the canonical amber ledger curve.'
Assert-True ($brandBoard -match 'Ledger curve = auditable proof') 'Brand board should document the ledger curve.'

$fleetScript = Get-Content -Path (Join-Path $root 'Get-FleetReport.ps1') -Raw
Assert-True ($fleetScript -match 'class="fleet-nav') 'Fleet report should include the sticky fleet command navigation.'
Assert-True ($fleetScript -match 'class="fleet-bento') 'Fleet report should include the audit fleet summary.'
Assert-True ($fleetScript -match 'class="fleet-lanes') 'Fleet report should include horizontal fleet risk lanes.'
Assert-True ($fleetScript -match 'class="fleet-evidence') 'Fleet report should include the pinned fleet evidence rail.'
Assert-True ($fleetScript -match 'class="brand-mark"') 'Fleet report should include the inline PatchManager brand mark.'
Assert-True ($fleetScript -match '#c49a3d') 'Fleet report brand mark should include the amber ledger curve.'
Assert-True ($fleetScript -match 'Patch\. Verify\. Prove it\.') 'Fleet report should include the PatchManager brand tagline.'
Assert-True ($fleetScript -match '--charcoal:#111513') 'Fleet report should use the Charcoal Ink brand token.'
Assert-True ($fleetScript -match '--paper:#f6f2e8') 'Fleet report should use the Ivory Paper brand token.'
Assert-True ($fleetScript -match '--blue:#18324a') 'Fleet report should use the Audit Blue brand token.'
Assert-True ($fleetScript -match '--green:#24744f') 'Fleet report should use the Verified Green brand token.'
Assert-True ($fleetScript -match '--red:#a53b35') 'Fleet report should use the Exposure Red brand token.'
Assert-True ($fleetScript -match '--amber-curve:#c49a3d') 'Fleet report should use the Caution Amber ledger token.'
Assert-True ($fleetScript -match 'Segoe UI Variable') 'Fleet report should use the Windows-safe brand font stack.'
Assert-True ($fleetScript -match 'Cascadia Mono') 'Fleet report should use Cascadia/Consolas for evidence values.'
Assert-True ($fleetScript -match 'Skip to host table') 'Fleet report should include keyboard skip navigation.'
Assert-True ($fleetScript -match 'id="fleetSearch"') 'Fleet report should include host search controls.'
Assert-True ($fleetScript -match 'id="postureFilter"') 'Fleet report should include posture filtering controls.'
Assert-True ($fleetScript -match 'id="ringFilter"') 'Fleet report should include ring filtering controls.'
Assert-True ($fleetScript -match 'id="profileFilter"') 'Fleet report should include profile filtering controls.'
Assert-True ($fleetScript -match 'id="fleetResultCount"') 'Fleet report should include a visible row count.'
Assert-True ($fleetScript -match 'data-ring=') 'Fleet report ring filter should be populated from row data.'
Assert-True ($fleetScript -match 'data-profile=') 'Fleet report profile filter should be populated from row data.'
Assert-True ($fleetScript -match 'data-sort="host"') 'Fleet report host table should keep sortable host columns.'
Assert-True ($fleetScript -match '<th data-sort="invkev">Inv\. KEV</th>') 'Fleet report host table should keep the inventory KEV column.'
Assert-True ($fleetScript -match 'https://github.com/ciaranwhiteside/PatchManager') 'Fleet report footer should link to the PatchManager repository.'
Assert-True ($fleetScript -match '<noscript><style>\.reveal\{opacity:1') 'Fleet report must stay readable when JavaScript is disabled.'
Assert-True ($fleetScript -match '\.reveal\{opacity:1 !important') 'Fleet report reveal sections must always print.'
Assert-True ($fleetScript -match 'prefers-reduced-motion') 'Fleet report should respect reduced-motion preferences.'
Assert-True ($fleetScript -notmatch 'cdnjs|unpkg|fonts\.googleapis|picsum|gsap') 'Fleet report should stay offline with no CDN, remote font, image, or GSAP dependency.'
Assert-True ($fleetScript -notmatch 'hero-visual|telemetry-strip|pulseBars') 'Fleet report should not include decorative animated hero telemetry.'
Assert-True ($fleetScript -notmatch '\.hero:before') 'Fleet report hero should not include decorative pseudo-art.'

Write-Host 'PatchManager static tests passed.' -ForegroundColor Green
