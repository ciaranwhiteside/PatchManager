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

$publicFiles = @(
    'Invoke-PatchManager.ps1'
    'PatchManager.config.example.json'
    'README.md'
    'SECURITY.md'
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
