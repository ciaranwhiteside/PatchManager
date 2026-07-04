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

#-- Config merge + scope profiles ---------------------------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ObjectPropertyValue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Set-ScopeProfileDefaults')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Import-Configuration')

function New-TestDefaultCfg {
    [ordered]@{
        ScopeProfile = 'Personal'
        Descope = [ordered]@{ PackageIds = @(); PackageNamePatterns = @(); Providers = @(); Sources = @(); Reasons = [ordered]@{} }
        Network = [ordered]@{ BITSThrottleEnabled = $null; BITSMaxBandwidthKbps = 4096 }
        WindowsUpdate = [ordered]@{ Enabled = $true }
        Microsoft365 = [ordered]@{ Enabled = $true }
        Browsers = [ordered]@{ Enabled = $true; ChromeEnabled = $true; EdgeEnabled = $true }
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

    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Commercial'
    $commercialCfg = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($commercialCfg.Network.BITSThrottleEnabled -eq $true) 'Commercial profile should resolve BITSThrottleEnabled to true.'
    Assert-True ($commercialCfg.WindowsUpdate.Enabled -eq $false) 'Commercial profile should disable Windows Update provider.'
    Assert-True ('Google.Chrome' -in $commercialCfg.Descope.PackageIds) 'Commercial profile should descope Chrome.'
} finally {
    Remove-Item $tempCfgPath -Force -EA SilentlyContinue
}

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

Assert-True ((Get-ScriptVersionFromContent -Content "`$script:VERSION       = '1.1.0'") -eq '1.1.0') 'Self-update: version literal should be parsed from script content.'
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

#-- Public file hygiene ---------------------------------------------------------------
$publicFiles = @(
    'Invoke-PatchManager.ps1'
    'Get-FleetReport.ps1'
    'PatchManager.config.example.json'
    'README.md'
    'SECURITY.md'
    'CHANGELOG.md'
    'CONTRIBUTING.md'
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

Write-Host 'PatchManager static tests passed.' -ForegroundColor Green
