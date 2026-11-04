#Requires -Version 5.1

param(
    [string]$VisualArtifactPath = ''
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'Invoke-PatchManager.ps1'
$exampleConfigPath = Join-Path $root 'PatchManager.config.example.json'
$configSchemaPath = Join-Path $root 'PatchManager.config.schema.json'
$readmePath = Join-Path $root 'README.md'
$changelogPath = Join-Path $root 'CHANGELOG.md'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-RelativeLuminance {
    param([Parameter(Mandatory)] [string]$Hex)
    $value = $Hex.TrimStart('#')
    Assert-True ($value.Length -eq 6) "Contrast helper requires a six-digit hex color: $Hex"
    $channels = foreach ($offset in @(0, 2, 4)) {
        $channel = [Convert]::ToInt32($value.Substring($offset, 2), 16) / 255
        if ($channel -le 0.04045) { $channel / 12.92 }
        else { [Math]::Pow((($channel + 0.055) / 1.055), 2.4) }
    }
    return (0.2126 * $channels[0]) + (0.7152 * $channels[1]) + (0.0722 * $channels[2])
}

function Get-ContrastRatio {
    param([Parameter(Mandatory)] [string]$Foreground, [Parameter(Mandatory)] [string]$Background)
    $first = Get-RelativeLuminance $Foreground
    $second = Get-RelativeLuminance $Background
    return ([Math]::Max($first, $second) + 0.05) / ([Math]::Min($first, $second) + 0.05)
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
Get-Content -Path $configSchemaPath -Raw | ConvertFrom-Json | Out-Null

$scriptContent = Get-Content -Path $scriptPath -Raw
$readmeContent = Get-Content -Path $readmePath -Raw
$changelogContent = Get-Content -Path $changelogPath -Raw
$versionMatch = [regex]::Match($scriptContent, "\`$script:VERSION\s*=\s*'([^']+)'")
Assert-True $versionMatch.Success 'Release version should be declared as a script literal.'
$releaseVersion = $versionMatch.Groups[1].Value
Assert-True ($scriptContent -match "Patch Manager v$([regex]::Escape($releaseVersion))") 'Script help header and runtime version should match.'
Assert-True ($readmeContent -match "Public beta \(v$([regex]::Escape($releaseVersion))\)") 'README public-beta version should match the runtime version.'
Assert-True ($changelogContent -match "## \[$([regex]::Escape($releaseVersion))\]") 'Changelog should contain the runtime release version.'

Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ObjectPropertyValue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-PatchRowKind')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-PatchResult')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-PatchResult')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Update-StatsFromResults')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-HTMLReport')

$falsePropertyObject = [pscustomobject]@{ Enabled = $false }
$falsePropertyDictionary = [ordered]@{ Enabled = $false }
Assert-True ((Get-ObjectPropertyValue $falsePropertyObject 'Enabled' $true) -eq $false) 'Object-property lookup must preserve an explicit false value.'
Assert-True ((Get-ObjectPropertyValue $falsePropertyDictionary 'Enabled' $true) -eq $false) 'Dictionary lookup must preserve an explicit false value.'
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
Assert-True ($dialogText -match 'AutoScaleMode.*Dpi') 'Dialogs should scale at high DPI.'
Assert-True ($dialogText -match 'AutoScaleDimensions.*96, 96') 'Dialogs should declare a 96-DPI design baseline for deterministic scaling.'
Assert-True ($dialogText -match 'TableLayoutPanel') 'Dialogs should use responsive layout containers.'
Assert-True ($dialogText -match '\$header\s*=\s*New-Object System\.Windows\.Forms\.TableLayoutPanel') 'Dialog headers should use layout containers rather than fixed coordinates.'
Assert-True ($dialogText -notmatch '\.(?:Location|Size)\s*=\s*New-Object System\.Drawing') 'Dialog controls should not rely on fixed coordinates or fixed control sizes.'
Assert-True ($dialogText -match 'MinimumSize\s*=\s*New-Object System\.Drawing\.Size\(120, 44\)') 'Dialog actions should retain a 44px minimum target before DPI scaling.'
Assert-True ($dialogText -match '\$brandIcon\.MaximumSize\s*=\s*New-Object System\.Drawing\.Size\(52, 52\)') 'The dialog brand mark should keep its intended footprint instead of stretching the header column.'
Assert-True ($dialogText -match '\$content\.AutoScroll\s*=\s*\$true') 'Long localized or technical dialog content should remain reachable.'
Assert-True ($dialogText -notmatch '\$form\.Height\s*\+=') 'Expanding technical evidence should reflow instead of applying an unscaled height delta.'
Assert-True ($dialogText -match '\$accent\.Margin\s*=\s*New-Object System\.Windows\.Forms\.Padding\(0\)') 'Dialog tone accents should remain visible inside the DPI-aware header row.'
Assert-True ($dialogText -match "ValidateSet\('Neutral',\s*'Success',\s*'Attention',\s*'Failure'\)") 'Dialogs should expose explicit semantic tones.'
Assert-True ($dialogText -match 'SystemInformation.*HighContrast') 'Dialogs should respect Windows High Contrast.'
Assert-True ($dialogText -match 'DetailText') 'Dialogs should expose long technical evidence in an expandable details area.'
Assert-True ($dialogText -notmatch 'AutoEllipsis\s*=\s*\$true') 'Dialog copy should not be ellipsized.'
Assert-True ($dialogText -match 'Automatically defers in') 'Timed app-in-use prompts should announce the live defer countdown.'
Assert-True ($completionPromptText -match "else \{ 'Success' \}") 'Clean completion prompts should use the success tone.'
Assert-True ($completionPromptText -match "hasFailure\) \{ 'Failure' \}") 'Failed completion prompts should use the failure tone.'

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
$script:CFG = [pscustomobject]@{ SLA = [pscustomobject]@{ Enabled = $true; Critical = 14 } }
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
$script:ExitCode = 0
$failedOutcomeRows = @(
    New-PatchResult -Name 'Blocked app' -PackageId 'Test.Blocked' -Provider 'winget' -Source 'winget' -Status 'Blocked' -Success $false -Evidence 'Still open.'
)
Update-StatsFromResults -Results $failedOutcomeRows
Assert-True ($script:Stats.UpdatesFailed -eq 1 -and $script:ExitCode -eq 1) 'Failed/blocked/verifying provider results must set a non-zero process exit code.'
$script:ExitCode = 0
Update-StatsFromResults -Results $updatedRows

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
Assert-True ($html -match '0 prioritized package row\(s\)') 'Source checks alone should not create actionable update rows.'
Assert-True ($html -match 'class="verdict-rail') 'HTML report should include the compact device verdict rail.'
Assert-True ($html -match '\.panel\{min-width:0;') 'Report panels must be allowed to shrink inside grid columns.'
Assert-True ($html -match '\.two-col\{display:grid;grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\)') 'Two-column evidence grids must contain wide tables instead of clipping adjacent panels.'
Assert-True ($html -match 'class="report-nav') 'HTML report should include the compact report command navigation.'
Assert-True ($html -match 'class="run-identity nav-run-identity"') 'Device run identity should sit in the compact evidence header.'
Assert-True ($html -match 'class="toolbar ledger-toolbar"') 'Device search and filters should sit beside the package ledger they control.'
Assert-True ($html.IndexOf('class="toolbar ledger-toolbar"') -gt $html.IndexOf('id="updates"')) 'Device ledger controls should not consume the opening header.'
Assert-True ($html -notmatch 'class="nav-links"') 'Device report should avoid pill-style anchor navigation in the evidence header.'
Assert-True ($html -match 'class="panel health-map"') 'HTML report should include the provider systems health map.'
Assert-True ($html -match 'class="health-root') 'Device health map should expose a device root node.'
Assert-True ($html -match "class='health-node") 'Device health map should expose provider evidence nodes.'
Assert-True ($html -match 'class="primary-action"') 'Device verdict should expose one clear primary action.'
Assert-True ($html -match '@media\(max-width:820px\)[^{]*\{[^}]*.*?\.primary-action\{min-height:44px\}') 'Device compact cascade should restore a 44px primary action at tablet width.'
Assert-True ($html -match '@media\(pointer:coarse\)\{[^}]*min-height:44px') 'Device report should preserve 44px controls for coarse pointers.'
Assert-True ($html -match 'seed a79596f6') 'Device report should preserve the selected Impeccable direction contract in emitted HTML.'
Assert-True ($html -like '*#updatesTable td:nth-child(6):before*') 'Device package rows should become labelled evidence cards on narrow screens.'
Assert-True ($html -match 'No package updates required action') 'HTML report should preserve the composed zero-action empty state.'

# End-user report layout: payload-first ordering + progressive-disclosure appendix.
Assert-True ($html -match 'id="auditDetail"') 'HTML report should wrap the audit appendix in a collapsible container.'
Assert-True ($html -match 'id="auditToggle"[^>]*hidden') 'The audit toggle must be hidden by default so a no-JS viewer never sees a dead button.'
Assert-True ($html -notmatch 'id="auditDetail" class="audit-detail is-collapsed"') 'The appendix must render EXPANDED by default (JS collapses it) so print/no-JS stay complete.'
Assert-True ($html -match '\.audit-detail,\.audit-detail\.is-collapsed\{display:block !important\}') 'A CSS rule must force the audit appendix expanded (used by both @media print and noscript).'
Assert-True ($html -match '<noscript><style>[^<]*audit-detail[^<]*display:block') 'A noscript rule must keep the audit appendix visible when JavaScript is off.'
Assert-True ($html -match '@media print') 'The report must retain print-specific styling.'
# Ordering: the actionable updates section must precede the breakdown counts.
Assert-True ($html.IndexOf('id="updates"') -lt $html.IndexOf('Result breakdown')) 'The actionable updates table must appear before the status/source/provider breakdown counts.'
Assert-True ($html.IndexOf('id="updates"') -lt $html.IndexOf('id="auditDetail"')) 'The actionable updates table must appear before the audit-detail appendix.'
# Evidence-ladder opening: verdict, compact status, then prioritized action.
Assert-True ($html -match 'class="verdict-state') 'The compact verdict rail should expose the run decision signals.'
Assert-True ($html -match 'Package verification ledger') 'The primary package section should use evidence-led ledger wording.'
Assert-True ($ast.Extent.Text -match 'class=.attention-list') 'The report should render one prioritized attention sequence.'
Assert-True ($ast.Extent.Text -match 'Inventory KEV') 'The attention sequence should include inventory KEV evidence.'
Assert-True ($ast.Extent.Text -match 'inventoryKevReviewGroups') 'Inventory KEV attention should group raw CVE rows into operator verification tasks.'
Assert-True ($ast.Extent.Text -match "notmatch '\^\\s\*\(\?:SLA\\s\+\)\?BREACH:'") 'Structured SLA breaches should not be presented again as runtime errors.'
Assert-True ($ast.Extent.Text -match 'Dry run found \$plannedCount planned update') 'Dry-run verdict should lead with the planned update count.'
Assert-True ($ast.Extent.Text -match 'Dry run only - no package action was attempted') 'Planned rows should explain why no execution evidence exists.'
Assert-True ($ast.Extent.Text -match '\$inventoryKevUnknownCount verify') 'The security summary should distinguish confirmed KEV exposure from verification work.'
Assert-True ($ast.Extent.Text -match '\$slaEvidence\s*=\s*@\(\)\s*if \(\$slaEnabled(?:\s+-and[^)]*)?\)') 'SLA-disabled report evidence must initialize as a real empty array under strict mode.'
Assert-True (([regex]::Matches($ast.Extent.Text, '\$slaBreaches\s*=\s*@\(\)\s*if \(\$script:CFG\.SLA\.Enabled\)')).Count -eq 3) 'Early-run and both main-run SLA breach collections must initialize as real empty arrays under strict mode.'
Assert-True ($html -match '\.nav-brand\{display:none\}') 'Mobile report should remove the duplicate navigation brand to keep the verdict in the first viewport.'
Assert-True ($html -match '\.hero-panel\{max-width:none;padding:12px;gap:8px\}') 'Mobile run evidence should remain visible in a compact first-viewport layout.'
Assert-True ($ast.Extent.Text -match 'SLA exposure') 'The attention sequence should include SLA evidence.'
Assert-True ($ast.Extent.Text -match 'Runtime error') 'The attention sequence should include runtime error evidence.'
Assert-True ($html -notmatch 'class="report-lanes') 'The duplicate report-lanes navigation row should be removed.'
Assert-True ($html -match 'expandAuditForFilter') 'An active search/filter must expand the audit appendix so matched rows are actually visible.'
Assert-True ($html -match 'https://github.com/ciaranwhiteside/PatchManager') 'HTML report footer should link to the PatchManager repository.'
Assert-True ($html -match 'class="brand-mark"') 'HTML report should include the inline PatchManager brand mark.'
Assert-True ($html -match '#c49a3d') 'HTML report brand mark should include the amber ledger curve.'
Assert-True ($html -match 'Patch\. Verify\. Prove it\.') 'HTML report should include the PatchManager brand tagline.'
Assert-True ($html -match '--charcoal:#111513') 'HTML report should use the Charcoal Ink brand token.'
Assert-True ($html -match '--paper:#f6f2e8') 'HTML report should use the Ivory Paper brand token.'
Assert-True ($html -match '--blue:#18324a') 'HTML report should use the Audit Blue brand token.'
Assert-True ($html -match '--green:#24744f') 'HTML report should use the Verified Green brand token.'
Assert-True ($html -match '--red:#a53b35') 'HTML report should use the Exposure Red brand token.'
Assert-True ($html -match '--amber:#955d20') 'HTML report should use the accessible Caution Amber ink token.'
Assert-True ($html -match '--amber-curve:#c49a3d') 'HTML report should use the Caution Amber ledger token.'
Assert-True ((Get-ContrastRatio '#955d20' '#faf0d8') -ge 4.5) 'Caution Amber text on its soft background must meet WCAG AA contrast.'
Assert-True ($html -match 'Segoe UI Variable') 'HTML report should use the Windows-safe brand font stack.'
Assert-True ($html -match 'Cascadia Mono') 'HTML report should use Cascadia/Consolas for evidence values.'
Assert-True ($html -match 'Skip to update table') 'HTML report should include keyboard skip navigation.'
Assert-True ($html -match "querySelectorAll\('tr\.data-row'\)") 'HTML report filters should discover options from all report rows.'
Assert-True ($html -match 'report row\(s\) visible') 'HTML report filter count should describe all report rows.'
Assert-True ($html -match 'main\{max-width:1440px') 'HTML report content should use the bounded responsive canvas.'
Assert-True ($html -match 'viewport-fit=cover') 'HTML reports should account for mobile safe areas.'
Assert-True ($html -match 'height:44px') 'HTML report inputs should meet the 44px touch-target floor.'
Assert-True ($html -match 'min-height:44px') 'HTML report buttons should meet the 44px touch-target floor.'
Assert-True ($html -match 'input,select,button\{font-size:16px\}') 'Mobile form controls should avoid browser text-zoom and remain readable.'
Assert-True ($html -match 'forced-colors:active') 'HTML report should support Windows High Contrast.'
Assert-True ($html -match '\.meta-grid\{min-width:0;display:grid;grid-template-columns:minmax\(0,1fr\) minmax\(0,1fr\)') 'Run metadata should be allowed to shrink without creating page-level mobile overflow.'
Assert-True ($html -match '\.report-nav>\*\{min-width:0\}') 'Mobile report navigation children should not force the page wider than the viewport.'
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

# Pending evidence remains amber; confirmed failures/exposure use red.
$reviewOnlyRows = @(
    New-PatchResult -Name 'Verification pending' -PackageId 'Test.Verifying' -Source 'winget' -Provider 'winget' -Status 'Verifying' -Success $false -Evidence 'Provider completed but installed version is not yet observable.'
    New-PatchResult -Name 'Restart pending' -PackageId 'Test.Reboot' -Source 'windows-update' -Provider 'windows-update' -Status 'Succeeded' -Success $true -RebootRequired $true -Evidence 'Restart is required to finish verification.'
)
$script:Stats.Errors.Clear()
Update-StatsFromResults -Results $reviewOnlyRows
$reviewOnlyHtml = New-HTMLReport -Results $reviewOnlyRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @()
Assert-True ($reviewOnlyHtml -match 'verdict-rail attention') 'Verifying/reboot-only evidence should use the amber verdict tone.'
Assert-True ($reviewOnlyHtml -match "panel review-panel needs-attention") 'Verifying/reboot-only evidence should use an amber review panel.'
Assert-True ($reviewOnlyHtml -match "<li class='review'>") 'Pending package evidence should use the amber review sequence marker.'
Assert-True ($reviewOnlyHtml -notmatch "panel danger-panel needs-attention") 'Pending-only evidence must not be presented as confirmed failure/exposure.'

$failedOnlyRows = @(
    New-PatchResult -Name 'Install failed' -PackageId 'Test.Failed' -Source 'winget' -Provider 'winget' -Status 'Failed' -Success $false -Evidence 'Installer returned a confirmed failure.'
)
$script:Stats.Errors.Clear()
Update-StatsFromResults -Results $failedOnlyRows
$failedOnlyHtml = New-HTMLReport -Results $failedOnlyRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @()
Assert-True ($failedOnlyHtml -match 'verdict-rail danger') 'Confirmed failure should use the red verdict tone.'
Assert-True ($failedOnlyHtml -match "panel danger-panel needs-attention") 'Confirmed failure should use the red attention panel.'
Update-StatsFromResults -Results $updatedRows

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
Assert-True (-not ($edgeParse.Upgrades.PackageId -contains 'Discord.Discord')) 'Edge fixture: the explicit-targeting table after the first table must be ignored.'
Assert-True (@($edgeParse.Upgrades | Where-Object { $_.PackageId -like '*VisualStudio*' }).Count -eq 0) 'Edge fixture: truncated ids must be skipped.'
Assert-True (@($edgeParse.Upgrades | Where-Object { $_.Name -like '*pins*' }).Count -eq 0) 'Edge fixture: footer lines must not become packages.'
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
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Copy-ConfigurationValue')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-ConfigurationType')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Assert-ValidConfiguration')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Set-ScopeProfileDefaults')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Import-Configuration')

function New-TestDefaultCfg {
    [ordered]@{
        ScopeProfile = 'Personal'
        Descope = [ordered]@{ PackageIds = @(); PackageNamePatterns = @(); Providers = @(); Sources = @(); Reasons = [ordered]@{} }
        Ring = [ordered]@{ Delays = [ordered]@{ Pilot = 0; Early = 3; Broad = 7 } }
        MaintenanceWindow = [ordered]@{ Enabled = $true; StartHour = 22; EndHour = 6; AllowedDays = @('Monday'); JitterMaxMinutes = $null }
        Network = [ordered]@{ BITSThrottleEnabled = $null; BITSMaxBandwidthKbps = 4096; ConnectivityTimeoutSec = 10 }
        WinGet = [ordered]@{ Scope = 'machine'; PackageTimeoutSeconds = 300; MaxUpdatesPerRun = 0; MaxRetries = 2 }
        WindowsUpdate = [ordered]@{ Enabled = $true }
        Microsoft365 = [ordered]@{ Enabled = $true }
        Browsers = [ordered]@{ Enabled = $true; ChromeEnabled = $true; EdgeEnabled = $true }
        PackageManagers = [ordered]@{ ChocolateyEnabled = $null; ScoopEnabled = $true; PythonManagerEnabled = $true }
        VendorUpdaters = [ordered]@{ Enabled = $true; ExtraCatalogue = @() }
        MicrosoftStore = [ordered]@{ Provider = 'Auto' }
        SelfUpdate = [ordered]@{ Enabled = $null; Ref = 'latest'; ExpectedSha256 = '' }
        SLA = [ordered]@{ Enabled = $null; Critical = 14 }
        Logging = [ordered]@{ RetentionDays = 90 }
        PreFlight = [ordered]@{ MinFreeSpaceGB = 5; MinBatteryPercent = 20 }
        NVD = [ordered]@{ DataSource = 'PublicApi'; MirrorBaseUrl = '' }
        NVDInventoryScan = [ordered]@{ ExcludeNamePatterns = @() }
    }
}

$tempCfgPath = Join-Path ([System.IO.Path]::GetTempPath()) "pm-test-config-$([guid]::NewGuid()).json"
@'
{
  "_comment": "test override",
  "Network": { "_comment": "section comment should be skipped", "BITSMaxBandwidthKbps": 1024 },
  "SLA": { "Critical": 7 }
}
'@ | Set-Content -Path $tempCfgPath -Encoding UTF8

try {
    $script:DefaultCfg = New-TestDefaultCfg
    $mergedCfg = Import-Configuration -Path $tempCfgPath
    Assert-True ($mergedCfg.Network.BITSMaxBandwidthKbps -eq 1024) 'Config merge: overridden scalar should win.'
    Assert-True ($mergedCfg.SLA.Critical -eq 7) 'Config merge: SLA override should apply.'
    Assert-True ($mergedCfg.Network.Contains('BITSThrottleEnabled')) 'Config merge: unlisted defaults should survive a partial section override.'
    Assert-True (-not $mergedCfg.Network.Contains('_comment')) 'Config merge: section-level _comment keys should be skipped.'
    Assert-True ($mergedCfg.Network.BITSThrottleEnabled -eq $false) 'Personal profile should resolve BITSThrottleEnabled to false.'
    Assert-True ($mergedCfg.MaintenanceWindow.JitterMaxMinutes -eq 0) 'Personal profile should resolve JitterMaxMinutes to 0 - a single device should not delay itself.'
    Assert-True ($mergedCfg.SLA.Enabled -eq $false) 'Personal profile should resolve SLA tracking to off.'

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
    Assert-True ($commercialCfg.PackageManagers.PythonManagerEnabled -eq $true) 'Commercial profile must keep the Python Install Manager enabled - only CommercialManaged assumes a platform owns it.'
    Assert-True ($commercialCfg.PackageManagers.ChocolateyEnabled -eq $false) 'Commercial profile must leave Chocolatey off by default - enabling it is an explicit licence decision.'
    Assert-True ($commercialCfg.SelfUpdate.Enabled -eq $true) 'Commercial profile should resolve self-update to on (no management platform owns the tool).'
    Assert-True ($commercialCfg.SLA.Enabled -eq $true) 'Commercial profile should resolve SLA tracking to on.'

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
    # Per-user patching providers follow the same managed-estate rule as Scoop.
    Assert-True ($managedCfg.PackageManagers.PythonManagerEnabled -eq $false) 'CommercialManaged profile should disable the Python Install Manager.'
    Assert-True ($managedCfg.PackageManagers.ChocolateyEnabled -eq $false) 'CommercialManaged profile should leave Chocolatey off.'
    Assert-True ($managedCfg.SelfUpdate.Enabled -eq $false) 'CommercialManaged profile should resolve self-update to off (the platform owns deployment).'
    Assert-True ($managedCfg.SLA.Enabled -eq $true) 'CommercialManaged profile should resolve SLA tracking to on.'

    # Personal resolves the licensing-gated Chocolatey default to on (free use).
    $script:DefaultCfg = New-TestDefaultCfg
    $personalCfg = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($personalCfg.PackageManagers.ChocolateyEnabled -eq $true) 'Personal profile should resolve Chocolatey to on (the CLI is free for personal use).'
    Assert-True ($personalCfg.SelfUpdate.Enabled -eq $true) 'Personal profile should resolve self-update to on by default.'
    Assert-True ($personalCfg.SLA.Enabled -eq $false) 'Personal profile should keep SLA tracking off by default.'

    # An explicit SLA.Enabled value must override the profile default.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.SLA.Enabled = $true
    $explicitSla = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($explicitSla.SLA.Enabled -eq $true) 'An explicit SLA.Enabled=true must override the Personal profile default.'

    # An explicit SelfUpdate.Enabled value must override the profile default.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.SelfUpdate.Enabled = $false
    $explicitSu = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($explicitSu.SelfUpdate.Enabled -eq $false) 'An explicit SelfUpdate.Enabled=false must win over the profile default.'

    # An explicit Chocolatey value in config must override the profile default.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Commercial'
    $script:DefaultCfg.PackageManagers.ChocolateyEnabled = $true
    $explicitChoco = Import-Configuration -Path 'nonexistent-config.json'
    Assert-True ($explicitChoco.PackageManagers.ChocolateyEnabled -eq $true) 'An explicit ChocolateyEnabled=true must win over the commercial-off default.'

    # Unknown profile values must fail closed; falling back to Personal can
    # unexpectedly patch OS/browser providers on a managed estate.
    $script:DefaultCfg = New-TestDefaultCfg
    $script:DefaultCfg.ScopeProfile = 'Enterprise'
    $threw = $false
    try { $null = Import-Configuration -Path 'nonexistent-config.json' } catch { $threw = $true }
    Assert-True $threw 'Unknown ScopeProfile must stop configuration loading.'

    # Unknown keys, malformed JSON, invalid regex, and wrong types must also
    # stop the run instead of silently reverting to broad defaults.
    $invalidCases = @(
        '{ "UnknownSection": { "Ignored": true } }',
        '{ invalid json',
        '{ "Descope": { "PackageNamePatterns": ["["] } }',
        '{ "Network": { "ConnectivityTimeoutSec": "ten" } }',
        '{ "Ring": { "Delays": { "Pilot": 0, "Early": 3, "Broad": 7, "Wave": 9 } } }',
        '{ "VendorUpdaters": { "ExtraCatalogue": [{ "Name": "X", "PackageId": "X", "Provider": "x", "UpdaterPathCandidates": ["x.exe"], "Unexpected": true }] } }'
    )
    foreach ($invalidJson in $invalidCases) {
        $invalidPath = Join-Path ([System.IO.Path]::GetTempPath()) "pm-invalid-config-$([guid]::NewGuid()).json"
        try {
            Set-Content -Path $invalidPath -Value $invalidJson -Encoding UTF8
            $script:DefaultCfg = New-TestDefaultCfg
            $threw = $false
            try { $null = Import-Configuration -Path $invalidPath } catch { $threw = $true }
            Assert-True $threw "Invalid configuration should fail closed: $invalidJson"
        } finally {
            Remove-Item $invalidPath -Force -EA SilentlyContinue
        }
    }
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

# Resolvers must return $null (never throw) when nothing matches - @()[0] throws
# under Set-StrictMode -Version Latest, which is how the script runs.
& {
    Set-StrictMode -Version Latest
    Assert-True ($null -eq (Resolve-FirstExistingPath -Candidates @('C:\definitely\missing\a.exe', 'C:\definitely\missing\b.exe'))) 'Resolve-FirstExistingPath must return $null (not throw) when no candidate exists under StrictMode.'
}

#-- Captured-process exit-code reliability ------------------------------------------
# Regression guard: Start-Process -PassThru leaves .ExitCode $null with redirected
# streams on PS 5.1, which made every choco upgrade look Failed and choco discovery
# look "failed to run". Invoke-CapturedProcess must return the real exit code.
foreach ($fn in 'Invoke-CapturedProcess','Test-SafeExecutablePath','Test-IsFleetProfile','Test-TrustedPath') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-SuccessfulProcessOutput')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-BrowserUpdaterArguments')
$cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
if (Test-Path $cmdExe) {
    $cpZero = Invoke-CapturedProcess -FilePath $cmdExe -Arguments @('/c', 'exit 0') -TimeoutSeconds 30
    Assert-True ($cpZero.ExitCode -eq 0) 'Invoke-CapturedProcess must capture exit code 0 (not $null) on a clean exit.'
    $cpReboot = Invoke-CapturedProcess -FilePath $cmdExe -Arguments @('/c', 'exit 3010') -TimeoutSeconds 30
    Assert-True ($cpReboot.ExitCode -eq 3010) 'Invoke-CapturedProcess must capture a non-zero exit code (e.g. reboot code 3010).'
    $cpOut = Invoke-CapturedProcess -FilePath $cmdExe -Arguments @('/c', 'echo captured-stdout') -TimeoutSeconds 30
    Assert-True ($cpOut.Output -match 'captured-stdout') 'Invoke-CapturedProcess must capture stdout.'
    # Stdin support (used by the Store CLI wrapper to answer y/n prompts).
    $cpIn = Invoke-CapturedProcess -FilePath $cmdExe -Arguments @('/c', 'findstr .') -TimeoutSeconds 30 -StandardInputLines @('hello-stdin')
    Assert-True ($cpIn.Output -match 'hello-stdin') 'Invoke-CapturedProcess must feed StandardInputLines to the child stdin.'
}
$cpMissing = Invoke-CapturedProcess -FilePath 'C:\definitely\missing\nope.exe' -Arguments @('x') -TimeoutSeconds 5
Assert-True ($null -eq $cpMissing.ExitCode -and $cpMissing.Output -match 'Exception') 'Invoke-CapturedProcess must report a launch failure as $null exit code with an Exception marker.'

# A failed runtime probe must not leak stderr into the report as a version.
Assert-True ((Get-SuccessfulProcessOutput ([pscustomobject]@{ ExitCode=0; TimedOut=$false; Output="  9.0.100`r`n" })) -eq '9.0.100') 'Successful process output should be normalised and returned.'
Assert-True ((Get-SuccessfulProcessOutput ([pscustomobject]@{ ExitCode=-2147450725; TimedOut=$false; Output='No .NET SDKs were found.' })) -eq '') 'Failed process output must not be reported as a runtime version.'
Assert-True ((Get-SuccessfulProcessOutput ([pscustomobject]@{ ExitCode=$null; TimedOut=$true; Output='Timed out.' })) -eq '') 'Timed-out process output must not be reported as a runtime version.'

# Google Updater rejected the legacy /ua arguments with exit 75009. Machine and
# per-user installs need the current Chromium updater command, while Edge keeps /ua.
$chromeMachineArgs = @(Get-BrowserUpdaterArguments -Browser Chrome -UpdaterPath (Join-Path ${env:ProgramFiles(x86)} 'Google\Update\GoogleUpdate.exe'))
$chromeUserArgs = @(Get-BrowserUpdaterArguments -Browser Chrome -UpdaterPath (Join-Path $env:LOCALAPPDATA 'Google\Update\GoogleUpdate.exe'))
$edgeArgs = @(Get-BrowserUpdaterArguments -Browser Edge -UpdaterPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate\MicrosoftEdgeUpdate.exe'))
Assert-True (($chromeMachineArgs -join ' ') -eq '--update-apps --system') 'Machine Chrome installs must use --update-apps --system.'
Assert-True (($chromeUserArgs -join ' ') -eq '--update-apps') 'Per-user Chrome installs must use --update-apps without --system.'
Assert-True (($edgeArgs -join ' ') -eq '/ua /installsource scheduler') 'Edge must retain its Omaha-compatible update arguments.'

#-- WinGet update execution correctness ----------------------------------------------
$packageUpdateText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-PackageUpdate'
$allUpdatesText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-AllUpdates'
$newPatchResultText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-PatchResult'
Assert-True ($packageUpdateText -match 'Resolve-WinGetInstalledScope') 'WinGet upgrades must resolve the installed package scope instead of blindly forcing the configured default.'
Assert-True ($packageUpdateText -match 'Get-WinGetPackageVerification') 'WinGet success/no-update outcomes must attempt structured post-update verification.'
Assert-True ($packageUpdateText -notmatch "@\('--custom',\s*'/norestart'\)") 'WinGet must not append an installer-specific /norestart argument to every package.'
Assert-True ($packageUpdateText -match '(?s)install technology is different.*LastUpdateStatus = ''Blocked''') 'Installer-technology conflicts must be non-retryable Blocked outcomes with remediation evidence.'
Assert-True ($allUpdatesText -match 'deferredByCap') 'Packages beyond MaxUpdatesPerRun must remain visible as deferred rows.'
Assert-True ($allUpdatesText -match 'ConfirmedVersion\s*=\s*\$script:LastUpdateConfirmedVersion') 'WinGet results must carry only the version observed during verification.'
Assert-True ($newPatchResultText -notmatch 'ConfirmedVersion\s*=\s*\$AvailableVersion') 'The shared result model must not infer confirmation from a provider-reported target.'
$unverifiedSuccess = New-PatchResult -Name 'Unverified' -PackageId 'Test.Unverified' -Provider 'test' -Source 'test' -AvailableVersion '2.0' -Status 'Succeeded' -Success $true
Assert-True ([string]::IsNullOrWhiteSpace($unverifiedSuccess.ConfirmedVersion)) 'A successful command without observed version proof must leave ConfirmedVersion empty.'

Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-WinGetInstalledScope')
$script:CFG = [pscustomobject]@{ WinGet = [pscustomobject]@{ PackageTimeoutSeconds=300 } }
$script:WINGET = 'fake-winget.exe'
$script:ScopeProbeCalls = [System.Collections.Generic.List[string]]::new()
function Invoke-CapturedProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds, [string[]]$StandardInputLines = @())
    $joined = $Arguments -join ' '
    $script:ScopeProbeCalls.Add($joined)
    $found = $joined -match '--scope user'
    [pscustomobject]@{ ExitCode=$(if ($found) { 0 } else { -1978335212 }); TimedOut=$false; Output='' }
}
$resolvedScope = Resolve-WinGetInstalledScope -PackageId 'Google.PlatformTools' -Source 'winget' -PreferredScope 'machine'
Assert-True ($resolvedScope -eq 'user') 'Scope resolution must fall back from machine to the user scope that owns the package.'
Assert-True ($script:ScopeProbeCalls.Count -eq 2 -and $script:ScopeProbeCalls[0] -match '--scope machine' -and $script:ScopeProbeCalls[1] -match '--scope user') 'Scope resolution must probe the configured scope first and alternate scope second.'
Remove-Item Function:\Invoke-CapturedProcess
foreach ($fn in 'Invoke-CapturedProcess','Test-SafeExecutablePath','Test-IsFleetProfile','Test-TrustedPath') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }

$browserProviderText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-BrowserProvider'
$vendorProviderText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-VendorUpdaterProvider'
$m365ProviderText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-Microsoft365Provider'
$chocoProviderText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-ChocolateyProvider'
Assert-True ($browserProviderText -match '\$run\.ExitCode\s+-ne\s+0') 'Browser provider must fail a non-zero native-updater exit code.'
Assert-True ($vendorProviderText -match '\$run\.ExitCode\s+-ne\s+0') 'Vendor provider must fail a non-zero native-updater exit code.'
Assert-True ($m365ProviderText -match '\$run\.ExitCode\s+-ne\s+0') 'Microsoft 365 provider must fail a non-zero OfficeC2RClient exit code.'
Assert-True ($chocoProviderText -match '\$discovery\.ExitCode\s+-ne\s+0') 'Chocolatey discovery must fail on a non-zero exit code.'
Assert-True ($vendorProviderText -match "else \{ 'Verifying' \}") 'A vendor updater without observable versions must remain Verifying, not report clean completion.'

# The Store CLI wrapper must preserve real exit codes and only flag Failed for
# launch failures - a $null exit code previously slipped through the exit-code
# gate and disabled the exit-5 -> MDM-bridge fallback.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-StoreCliCommand')
if (Test-Path $cmdExe) {
    $storeOk = Invoke-StoreCliCommand -StoreCli $cmdExe -Arguments @('/c', 'exit 5') -TimeoutSeconds 30
    Assert-True ($storeOk.ExitCode -eq 5 -and -not $storeOk.Failed) 'Store CLI wrapper must surface a real non-zero exit code without marking Failed.'
}
$storeMissing = Invoke-StoreCliCommand -StoreCli 'C:\definitely\missing\store.exe' -Arguments @('updates') -TimeoutSeconds 5
Assert-True ($storeMissing.Failed -and $null -eq $storeMissing.ExitCode) 'Store CLI wrapper must mark a launch failure as Failed.'

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
$savedDryRunForVerdict = $DryRun
$DryRun = [System.Management.Automation.SwitchParameter]::new($false)
$stalenessHtml = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @() -StalenessFindings $stalenessFindings
$DryRun = $savedDryRunForVerdict
Assert-True ($stalenessHtml -match 'Environment staleness') 'HTML report should render the Environment staleness panel when findings exist.'
Assert-True ($stalenessHtml -match 'Report-only exposure checks') 'Staleness panel should state it is report-only.'
Assert-True ($stalenessHtml -match 'Microsoft Defender') 'Staleness panel should list the Defender finding.'
Assert-True ($stalenessHtml -match 'verdict-rail attention') 'A staleness-only report must use the amber verdict instead of false-green completion.'
Assert-True ($stalenessHtml -match 'Review before close\.') 'A staleness-only report should direct the operator to review evidence.'
Assert-True ($stalenessHtml -match 'panel review-panel') 'Advisory staleness evidence should use the amber review panel, not red danger.'

#-- Report row classification (one predicate for JSON, HTML classes, and the count) ---
function New-KindRow {
    param([string]$Status, [bool]$Reboot = $false, [bool]$Kev = $false, [bool]$Success = $false)
    [pscustomobject]@{ Status = $Status; RebootRequired = $Reboot; IsKEV = $Kev; Success = $Success }
}

Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Failed'))    -eq 'attention') 'Row kind: Failed -> attention.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Blocked'))   -eq 'attention') 'Row kind: Blocked -> attention.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Verifying')) -eq 'attention') 'Row kind: Verifying -> attention.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Succeeded' -Reboot $true -Success $true)) -eq 'attention') 'Row kind: a reboot-required row needs attention even when it succeeded.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Succeeded' -Kev $true -Success $true))    -eq 'attention') 'Row kind: a confirmed-KEV row needs attention.'
# A confirmed-KEV package deferred by the per-run cap is still exposure, not a tidy skip.
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Skipped' -Kev $true)) -eq 'attention') 'Row kind: a KEV row skipped by the update cap still needs attention.'

Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Planned'))   -eq 'action')  'Row kind: Planned -> action.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Succeeded' -Success $true)) -eq 'updated') 'Row kind: Succeeded -> updated.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Skipped'))   -eq 'skipped') 'Row kind: Skipped -> skipped.'
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'Completed' -Success $true)) -eq 'provider') 'Row kind: a provider check row -> provider.'

# Regression: Descoped rows carry Success=$false by default, and the JSON export used to
# treat "Success=false and status is not Skipped" as needing attention - so every
# deliberately descoped row was reported as an attention item (worst under
# CommercialManaged, which descopes the most).
$descoped = New-KindRow -Status 'Descoped'
Assert-True ($descoped.Success -eq $false) 'A Descoped row carries Success=$false - the trap the old heuristic fell into.'
Assert-True ((Get-PatchRowKind $descoped) -eq 'skipped') 'Row kind: Descoped is a deliberate outcome, never an attention item.'
# ...and an AlreadyCurrent provider row is evidence, not a problem.
Assert-True ((Get-PatchRowKind (New-KindRow -Status 'AlreadyCurrent' -Success $true)) -eq 'provider') 'Row kind: AlreadyCurrent -> provider evidence.'

# The headline count and the attention list must be the same predicate. Previously the
# HTML could headline "1 item(s) need review" over an empty list. A reboot-required row
# is the cheapest way to catch a regression: the old count ignored it entirely.
$driftRows = @(
    (New-PatchResult -Name 'Rebooter' -PackageId 'A' -Provider 'winget' -Source 'winget' -Status 'Succeeded' -Success $true -RebootRequired $true)
    (New-PatchResult -Name 'Descoped app' -PackageId 'B' -Provider 'winget' -Source 'winget' -Status 'Descoped')
    (New-PatchResult -Name 'Fine' -PackageId 'C' -Provider 'winget' -Source 'winget' -Status 'Succeeded' -Success $true)
)
$driftAttention = @($driftRows | Where-Object { (Get-PatchRowKind $_) -eq 'attention' })
Assert-True ($driftAttention.Count -eq 1) 'Attention rows: exactly the reboot-required row, not the descoped one.'
$script:Stats.KEVMatches = 0
$driftHtml = New-HTMLReport -Results $driftRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @()
Assert-True ($driftHtml -match '1 operator task\(s\) need review') 'HTML headline must count the reboot-required row.'
Assert-True ($driftHtml -match 'Skipped and descoped rows remain in the audit appendix') 'Attention panel must say descoped rows remain available as audit evidence.'
Assert-True ($driftHtml -notmatch '2 operator task\(s\) need review') 'HTML headline must not count the descoped row.'
# Regression from a real dry-run report: SLA breaches were duplicated as script errors,
# and two unknown CVEs for one installed product appeared as two separate operator tasks.
$script:Stats.UpdatesPlanned = 12
$script:Stats.Errors = [System.Collections.Generic.List[string]]::new()
$script:Stats.Errors.Add('SLA BREACH: 4 update(s) available for over 14 days.')
$script:Stats.Errors.Add('  BREACH: Android SDK Platform-Tools v37.0.1 available since 2026-07-09 (due: 2026-07-23)')
$script:Stats.Errors.Add('  BREACH: Affinity v3.2.3.4646 available since 2026-07-17 (due: 2026-07-31)')
$script:Stats.Errors.Add('  BREACH: Microsoft GameInput v3.4.218 available since 2026-07-17 (due: 2026-07-31)')
$script:Stats.Errors.Add('  BREACH: Rockstar Games Launcher v1.0.108.2970 available since 2026-07-18 (due: 2026-08-01)')
$actualLikeInventoryKev = @(
    [pscustomobject]@{ InstalledApp='Microsoft.Edge.GameAssist'; ExposureState='Unknown'; CVE='CVE-2016-7201'; InstalledVer='1.0'; FixedVersion=''; ExposureDetail='NVD range unavailable'; Description=''; CISADueDate='' }
    [pscustomobject]@{ InstalledApp='Microsoft.Edge.GameAssist'; ExposureState='Unknown'; CVE='CVE-2016-7200'; InstalledVer='1.0'; FixedVersion=''; ExposureDetail='NVD range unavailable'; Description=''; CISADueDate='' }
)
$actualLikeSla = @(
    [pscustomobject]@{ PackageName='Android SDK Platform-Tools'; PackageId='Google.PlatformTools'; VersionAvailable='37.0.1'; FirstSeenAvailable='2026-07-09'; SLADue='2026-07-23'; Ring='Pilot' }
    [pscustomobject]@{ PackageName='Affinity'; PackageId='Canva.Affinity'; VersionAvailable='3.2.3.4646'; FirstSeenAvailable='2026-07-17'; SLADue='2026-07-31'; Ring='Pilot' }
    [pscustomobject]@{ PackageName='Microsoft GameInput'; PackageId='Microsoft.GameInput'; VersionAvailable='3.4.218'; FirstSeenAvailable='2026-07-17'; SLADue='2026-07-31'; Ring='Pilot' }
    [pscustomobject]@{ PackageName='Rockstar Games Launcher'; PackageId='RockstarGames.Launcher'; VersionAvailable='1.0.108.2970'; FirstSeenAvailable='2026-07-18'; SLADue='2026-08-01'; Ring='Pilot' }
)
$script:CFG = [pscustomobject]@{ SLA = [pscustomobject]@{ Enabled = $true; Critical = 14 } }
$actualLikeHtml = New-HTMLReport -Results @() -KEVMatches @() -SLABreaches $actualLikeSla -Elapsed 0.4 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=12 }) -InventoryKEVMatches $actualLikeInventoryKev
Assert-True ($actualLikeHtml -match 'Dry run found 12 planned update\(s\)') 'Real-report regression: dry-run verdict should lead with planned updates.'
Assert-True ($actualLikeHtml -match '5 operator task\(s\) need review') 'Real-report regression: one grouped KEV verification plus four SLA tasks should total five.'
Assert-True ($actualLikeHtml -match '0 package / 1 KEV review / 4 SLA / 0 runtime') 'Real-report regression: summary categories should be complete and de-duplicated.'
Assert-True (([regex]::Matches($actualLikeHtml, 'Verify inventory KEV - Microsoft\.Edge\.GameAssist')).Count -eq 1) 'Real-report regression: unknown CVEs for one product should form one verification task.'
Assert-True ($actualLikeHtml -match '2 catalogue CVE\(s\) need version verification') 'Real-report regression: grouped verification should retain the raw CVE count.'
Assert-True ($actualLikeHtml -notmatch '<strong>Runtime error</strong>') 'Real-report regression: structured SLA messages must not reappear as runtime errors.'
Assert-True ($actualLikeHtml -match 'Runtime: No errors') 'Real-report regression: runtime evidence should remain clean when only SLA messages were logged.'
$script:CFG.SLA.Enabled = $false
$personalSlaOffHtml = New-HTMLReport -Results @() -KEVMatches @() -SLABreaches $actualLikeSla -Elapsed 0.4 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=12 }) -InventoryKEVMatches $actualLikeInventoryKev
Assert-True ($personalSlaOffHtml -notmatch 'SLA: Updates past deadline') 'Personal SLA-off report must omit the SLA evidence panel.'
Assert-True ($personalSlaOffHtml -notmatch 'SLA exposure -') 'Personal SLA-off report must not create SLA operator tasks.'
Assert-True ($personalSlaOffHtml -notmatch '\bSLA\b') 'Personal SLA-off report should omit SLA terminology entirely.'
Assert-True ($personalSlaOffHtml -match 'Run metrics: Coverage summary') 'Personal SLA-off audit metrics should show coverage without patch-state SLA framing.'
Assert-True ($personalSlaOffHtml -notmatch 'Patch state summary') 'Personal SLA-off audit metrics must not surface stale tracked-update state.'
Assert-True ($personalSlaOffHtml -match 'class="two-col single reveal"') 'Security evidence should use the full width when the SLA panel is omitted.'
$script:CFG.SLA = [ordered]@{ Enabled = $false; Critical = 14 }
$earlySlaOffHtml = New-HTMLReport -Results @() -KEVMatches @() -SLABreaches $null -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @()
$earlySlaFragments = @([regex]::Matches($earlySlaOffHtml, '.{0,80}\bSLA\b.{0,80}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Value })
Assert-True ($earlySlaOffHtml -notmatch '\bSLA\b') "An SLA-off early report must render without SLA terminology when the collection is null. Found: $($earlySlaFragments -join ' | ')"
Assert-True ($earlySlaOffHtml -notmatch 'SLA: Updates past deadline') 'An SLA-off dictionary config must not be replaced by the report helper default.'
$script:CFG.SLA.Enabled = $true

#-- KEV exposure resolution (CISA KEV names products; NVD supplies versions) ---------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-VersionParts')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Compare-SoftwareVersion')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-CpeToken')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertFrom-CpeCriteria')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-CpeProductAlignment')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-VersionInCpeRange')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-KEVExposure')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-WordMatch')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Find-KEVCandidates')

# Live-feed regression: CISA returned product "Windows " with trailing whitespace.
# Without trimming, it bypassed the Windows exclusion and matched the word Windows
# in .NET Desktop Runtime, creating four false emergency exposures.
$windowsKev = [pscustomobject]@{ vulnerabilities = @([pscustomobject]@{
    vendorProject=' Microsoft '; product='Windows '; cveID='CVE-2024-30088'
    vulnerabilityName='Windows Kernel test'; dateAdded='2024-01-01'; dueDate='2024-01-31'
}) }
$dotnetUpgrade = [pscustomobject]@{
    Name='Microsoft .NET Windows Desktop Runtime 10.0'; PackageId='Microsoft.DotNet.DesktopRuntime.10'
    Publisher='Microsoft Corporation'; Version='10.0.9'; Source='winget'
}
Assert-True (@(Find-KEVCandidates -Packages @($dotnetUpgrade) -KEVData $windowsKev).Count -eq 0) 'Whitespace-padded Microsoft Windows KEV entries must never match .NET packages.'

# Version comparison: dotted-numeric only; anything else is undecidable, never "equal".
Assert-True ((Compare-SoftwareVersion '150.0.7871.47' '86.0.4240.198') -eq 1)  'Compare: Chrome 150 is newer than 86.0.4240.198.'
Assert-True ((Compare-SoftwareVersion '86.0.4240.197' '86.0.4240.198') -eq -1) 'Compare: one patch behind is older.'
Assert-True ((Compare-SoftwareVersion '86' '86.0.0') -eq 0)                    'Compare: missing trailing segments are zero.'
Assert-True ((Compare-SoftwareVersion 'v20.11.1' '20.11.1') -eq 0)             'Compare: a leading v is stripped.'
Assert-True ((Compare-SoftwareVersion '9.0.0' '10.0.0') -eq -1)                'Compare: numeric, not lexicographic (9 < 10).'
Assert-True ($null -eq (Compare-SoftwareVersion '3.14-64' '3.14.6'))           'Compare: a non-numeric segment is undecidable ($null).'
Assert-True ($null -eq (Compare-SoftwareVersion '' '1.0'))                     'Compare: an empty version is undecidable ($null).'
Assert-True ($null -eq (Compare-SoftwareVersion '1.0.0-beta' '1.0.0'))         'Compare: a pre-release suffix is undecidable ($null).'

# CPE parsing and product alignment.
$cpeChrome = ConvertFrom-CpeCriteria 'cpe:2.3:a:google:chrome:*:*:*:*:*:*:*:*'
Assert-True ($cpeChrome.Part -eq 'a' -and $cpeChrome.Vendor -eq 'google' -and $cpeChrome.Product -eq 'chrome') 'CPE 2.3 parses into part/vendor/product.'
Assert-True ($null -eq (ConvertFrom-CpeCriteria 'not-a-cpe')) 'A malformed CPE parses to $null.'
Assert-True ((ConvertTo-CpeToken 'Google Chrome') -eq 'google_chrome') 'CPE token normalisation collapses separators.'
Assert-True (Test-CpeProductAlignment $cpeChrome 'Google' 'Chrome') 'Chrome CPE aligns with the Google/Chrome KEV entry.'
Assert-True (-not (Test-CpeProductAlignment (ConvertFrom-CpeCriteria 'cpe:2.3:a:google:android:*:*:*:*:*:*:*:*') 'Google' 'Chrome')) 'An Android CPE must not align with a Chrome KEV entry.'
Assert-True (-not (Test-CpeProductAlignment (ConvertFrom-CpeCriteria 'cpe:2.3:h:google:chrome:*:*:*:*:*:*:*:*') 'Google' 'Chrome')) 'A hardware-part CPE is not an application match.'

$nvd = Get-Content -Path (Join-Path $fixtureDir 'nvd-cpematches.json') -Raw | ConvertFrom-Json

# Range membership.
$chromeRange = @($nvd.'chrome-cve-2020-16017')[0]
Assert-True ((Test-VersionInCpeRange -Version '86.0.4240.197' -CpeMatch $chromeRange) -eq $true)  'A version below versionEndExcluding is inside the range.'
Assert-True ((Test-VersionInCpeRange -Version '86.0.4240.198' -CpeMatch $chromeRange) -eq $false) 'The fix version itself is outside the range (End*Excluding*).'
Assert-True ((Test-VersionInCpeRange -Version '150.0.7871.47' -CpeMatch $chromeRange) -eq $false) 'A far-newer version is outside the range.'
$windowed = @($nvd.'chrome-bounded-window')[0]
Assert-True ((Test-VersionInCpeRange -Version '79.0.0.0' -CpeMatch $windowed) -eq $false) 'Below versionStartIncluding is outside the range.'
Assert-True ((Test-VersionInCpeRange -Version '80.0.0.0' -CpeMatch $windowed) -eq $true)  'versionStartIncluding is inclusive.'
$exact = @($nvd.'chrome-exact-version')[0]
Assert-True ((Test-VersionInCpeRange -Version '86.0.4240.197' -CpeMatch $exact) -eq $true)  'A CPE pinning an exact version matches that version.'
Assert-True ((Test-VersionInCpeRange -Version '86.0.4240.198' -CpeMatch $exact) -eq $false) 'A CPE pinning an exact version rejects any other version.'
# An unbounded wildcard is deliberately undecidable - honouring it would resurrect the
# false-positive emergencies the NVD gate exists to prevent.
Assert-True ($null -eq (Test-VersionInCpeRange -Version '150.0.7871.47' -CpeMatch @($nvd.'chrome-unbounded')[0])) 'An unbounded wildcard CPE is undecidable, not affected.'
Assert-True ($null -eq (Test-VersionInCpeRange -Version '3.14-64' -CpeMatch $chromeRange)) 'An uncomparable installed version is undecidable.'

# Resolve-KEVExposure: the regression this whole gate exists for.
# Chrome 150.0.7871.47 was reported as an actionable KEV match for CVE-2020-16017
# (fixed in 86.0.4240.198) and triggered a maintenance-window bypass.
$chromeExposure = Resolve-KEVExposure -InstalledVersion '150.0.7871.47' -Vendor 'Google' -Product 'Chrome' -CpeMatches @($nvd.'chrome-cve-2020-16017')
Assert-True ($chromeExposure.State -eq 'NotAffected') 'Chrome 150 must resolve NotAffected against CVE-2020-16017.'
Assert-True ($chromeExposure.FixedVersion -eq '86.0.4240.198') 'NotAffected should still report the fix boundary it cleared.'

$vulnChrome = Resolve-KEVExposure -InstalledVersion '86.0.4240.197' -Vendor 'Google' -Product 'Chrome' -CpeMatches @($nvd.'chrome-cve-2020-16017')
Assert-True ($vulnChrome.State -eq 'Affected') 'Chrome one patch below the fix must resolve Affected.'
Assert-True ($vulnChrome.FixedVersion -eq '86.0.4240.198') 'Affected should report the version that fixes it.'

# Unknown, never Affected, whenever the data cannot settle it.
Assert-True ((Resolve-KEVExposure -InstalledVersion '150.0.0.0' -Vendor 'Google' -Product 'Chrome' -CpeMatches @()).State -eq 'Unknown') 'No CPE data -> Unknown.'
Assert-True ((Resolve-KEVExposure -InstalledVersion '150.0.0.0' -Vendor 'Google' -Product 'Chrome' -CpeMatches $null).State -eq 'Unknown') 'Null CPE data -> Unknown.'
Assert-True ((Resolve-KEVExposure -InstalledVersion '3.14-64' -Vendor 'Google' -Product 'Chrome' -CpeMatches @($nvd.'chrome-cve-2020-16017')).State -eq 'Unknown') 'An uncomparable installed version -> Unknown.'
Assert-True ((Resolve-KEVExposure -InstalledVersion '150.0.0.0' -Vendor 'Google' -Product 'Chrome' -CpeMatches @($nvd.'chrome-unbounded')).State -eq 'Unknown') 'An unbounded wildcard range -> Unknown, never Affected.'
Assert-True ((Resolve-KEVExposure -InstalledVersion '150.0.0.0' -Vendor 'Google' -Product 'Chrome' -CpeMatches @($nvd.'unrelated-product-only')).State -eq 'Unknown') 'No aligned product CPE -> Unknown.'

# A 'vulnerable: false' CPE row must not be treated as an affected range.
Assert-True ((Resolve-KEVExposure -InstalledVersion '32' -Vendor 'Fedoraproject' -Product 'Fedora' -CpeMatches @($nvd.'chrome-cve-2020-16017')).State -eq 'Unknown') 'A non-vulnerable CPE row cannot establish exposure.'

# Edge GameAssist 1.0.4019.0 matched two 2016 legacy-Edge CVEs by name alone.
$edgeExposure = Resolve-KEVExposure -InstalledVersion '1.0.4019.0' -Vendor 'Microsoft' -Product 'Edge' -CpeMatches @($nvd.'edge-legacy-cve-2016-7201')
Assert-True ($edgeExposure.State -eq 'Unknown') 'Legacy Edge CVE with no version range -> Unknown, not a confirmed exposure.'

#-- Python Install Manager provider (pymanager owns Store-installed Python) ----------
# Runs after Compare-SoftwareVersion is in scope: Find-PyManagerUpgrades depends on it.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertFrom-PyManagerList')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Find-PyManagerUpgrades')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-PyUpdateOutcome')

$pyInstalledRaw = Get-Content -Path (Join-Path $fixtureDir 'py-list-installed.json') -Raw
$pyOnlineRaw    = Get-Content -Path (Join-Path $fixtureDir 'py-list-online.json')    -Raw

# Parsing: pymanager prints signature-verification notices before the JSON body.
$pyInstalled = @((ConvertFrom-PyManagerList -Json $pyInstalledRaw).Runtimes)
Assert-True ($pyInstalled.Count -eq 4) 'py list parser: should read all four runtimes, notices and all.'
$py314 = $pyInstalled | Where-Object { $_.Id -eq 'pythoncore-3.14-64' } | Select-Object -First 1
Assert-True ($py314.Version -eq '3.14.5' -and $py314.Tag -eq '3.14-64') 'py list parser: reads sort-version and tag.'
Assert-True (-not $py314.Unmanaged) 'py list parser: a pymanager-installed runtime is managed.'
$pyAstral = $pyInstalled | Where-Object { $_.Company -eq 'Astral' } | Select-Object -First 1
Assert-True ($pyAstral.Unmanaged) 'py list parser: an Astral/uv runtime is flagged unmanaged.'

# $null (not an empty listing) distinguishes "not the Python Install Manager" from
# "no runtimes". Resolve-PyManagerCommand keys its legacy-launcher rejection on that.
Assert-True ($null -eq (ConvertFrom-PyManagerList -Json 'Python 3.14.5')) 'py list parser: non-JSON output (legacy py launcher) -> $null.'
Assert-True ($null -eq (ConvertFrom-PyManagerList -Json '')) 'py list parser: empty output -> $null.'
Assert-True ($null -eq (ConvertFrom-PyManagerList -Json '{"other": 1}')) 'py list parser: JSON without a versions key -> $null.'
$pyNone = ConvertFrom-PyManagerList -Json '{"versions": []}'
Assert-True ($null -ne $pyNone) 'py list parser: a manager reporting no runtimes is still the manager, not $null.'
Assert-True (@($pyNone.Runtimes).Count -eq 0) 'py list parser: a manager reporting no runtimes -> empty Runtimes.'

# Regression: a machine with exactly ONE managed runtime is the common case. A bare array
# return unrolls in the pipeline, delivering a scalar whose .Count throws under StrictMode
# (and an empty listing as $null, indistinguishable from "not the manager"). The wrapper
# object is what keeps .Runtimes an array in both cases.
$pySingle = ConvertFrom-PyManagerList -Json '{"versions": [{"id": "pythoncore-3.14-64", "sort-version": "3.14.5", "company": "PythonCore", "tag": "3.14-64", "display-name": "Python 3.14.5"}]}'
Assert-True ($pySingle.Runtimes -is [array]) 'py list parser: a single runtime must still come back as an array.'
Assert-True ($pySingle.Runtimes.Count -eq 1) 'py list parser: .Count must work on a single-runtime result (StrictMode).'
$pySingleOnline = ConvertFrom-PyManagerList -Json '{"versions": [{"id": "pythoncore-3.14-64", "sort-version": "3.14.6", "company": "PythonCore", "tag": "3.14-64", "display-name": "Python 3.14.6"}]}'
Assert-True (@(Find-PyManagerUpgrades -Installed @($pySingle.Runtimes) -Online @($pySingleOnline.Runtimes)).Count -eq 1) 'py upgrades: a lone managed runtime with a newer build is offered.'
Assert-True (@(Find-PyManagerUpgrades -Installed @() -Online @()).Count -eq 0) 'py upgrades: empty in, empty out.'

# Upgrade pairing: exact install-id match, strictly newer version only.
$pyOnline   = @((ConvertFrom-PyManagerList -Json $pyOnlineRaw).Runtimes)
$pyUpgrades = @(Find-PyManagerUpgrades -Installed $pyInstalled -Online $pyOnline)
Assert-True ($pyUpgrades.Count -eq 1) 'py upgrades: only the one runtime with a newer build should be offered.'
Assert-True ($pyUpgrades[0].Id -eq 'pythoncore-3.14-64') 'py upgrades: pairs installed to online by exact install id.'
Assert-True ($pyUpgrades[0].Current -eq '3.14.5' -and $pyUpgrades[0].Available -eq '3.14.6') 'py upgrades: 3.14.5 -> 3.14.6, the case WinGet cannot see.'

# The unmanaged Astral runtime has a NEWER online version in the fixture (3.11.99).
# pymanager does not own it, so it must never be offered for update.
Assert-True (@($pyUpgrades | Where-Object { $_.Id -like '__unmanaged*' }).Count -eq 0) 'py upgrades: an unmanaged runtime is never offered, even when a newer version exists.'
# A runtime already on the latest build must not be offered.
Assert-True (@($pyUpgrades | Where-Object { $_.Id -eq 'pythoncore-3.12-64' }).Count -eq 0) 'py upgrades: an already-current runtime is not offered.'
# A 32-bit/arm64 build of the same tag must not be mistaken for the installed 64-bit one.
Assert-True (@($pyUpgrades | Where-Object { $_.Id -match '32|arm64' }).Count -eq 0) 'py upgrades: a different architecture id is not an upgrade candidate.'
Assert-True (@(Find-PyManagerUpgrades -Installed $pyInstalled -Online @()).Count -eq 0) 'py upgrades: an empty online index yields nothing.'
Assert-True (@(Find-PyManagerUpgrades -Installed @() -Online $pyOnline).Count -eq 0) 'py upgrades: nothing installed yields nothing.'

# Update verdict: the observed version decides, the exit code is only evidence.
# Regression, observed on a real 3.14.5 -> 3.14.6 run: pymanager installed the runtime,
# restored site-packages, then exited 1 from its shortcut refresh with
# "INTERNAL ERROR: AttributeError: 'str' object has no attribute 'satisfied_by'".
# Gating on the exit code reported an applied update as Failed and would retry it forever.
$pyDirtyExit = Resolve-PyUpdateOutcome -ExitCode 1 -CurrentVersion '3.14.5' -ObservedVersion '3.14.6'
Assert-True ($pyDirtyExit.Status -eq 'Succeeded' -and $pyDirtyExit.Success) 'py outcome: a non-zero exit with a verified version bump is Succeeded.'
Assert-True ($pyDirtyExit.Note -match 'exited non-zero after applying') 'py outcome: the exit-code anomaly must be recorded in the evidence.'

$pyClean = Resolve-PyUpdateOutcome -ExitCode 0 -CurrentVersion '3.14.5' -ObservedVersion '3.14.6'
Assert-True ($pyClean.Status -eq 'Succeeded' -and $pyClean.Success) 'py outcome: clean exit with a version bump is Succeeded.'
Assert-True ($pyClean.Note -notmatch 'exited non-zero') 'py outcome: a clean exit records no anomaly.'

# The mirror image of the 1.4.2 defects: exit 0 must never imply an applied update.
$pyLyingZero = Resolve-PyUpdateOutcome -ExitCode 0 -CurrentVersion '3.14.5' -ObservedVersion '3.14.5'
Assert-True ($pyLyingZero.Status -eq 'Failed' -and -not $pyLyingZero.Success) 'py outcome: exit 0 with an unchanged version is Failed, not Succeeded.'
$pyDirtyNoChange = Resolve-PyUpdateOutcome -ExitCode 1 -CurrentVersion '3.14.5' -ObservedVersion '3.14.5'
Assert-True ($pyDirtyNoChange.Status -eq 'Failed') 'py outcome: non-zero exit with an unchanged version is Failed.'

# Unverifiable outcomes: a clean exit is merely unconfirmed, a dirty one is a failure.
Assert-True ((Resolve-PyUpdateOutcome -ExitCode 0 -CurrentVersion '3.14.5' -ObservedVersion '').Status -eq 'Verifying') 'py outcome: clean exit, unreadable version -> Verifying.'
Assert-True ((Resolve-PyUpdateOutcome -ExitCode 1 -CurrentVersion '3.14.5' -ObservedVersion '').Status -eq 'Failed') 'py outcome: non-zero exit, unreadable version -> Failed.'
Assert-True ((Resolve-PyUpdateOutcome -ExitCode $null -CurrentVersion '3.14.5' -ObservedVersion '').Status -eq 'Failed') 'py outcome: a null exit code (process never returned one) is never Verifying.'
# A downgrade is not an update.
Assert-True ((Resolve-PyUpdateOutcome -ExitCode 0 -CurrentVersion '3.14.6' -ObservedVersion '3.14.5').Status -eq 'Failed') 'py outcome: an observed downgrade is Failed.'
# An uncomparable observed version must not be read as progress.
Assert-True ((Resolve-PyUpdateOutcome -ExitCode 0 -CurrentVersion '3.14.5' -ObservedVersion '3.14-64').Status -eq 'Failed') 'py outcome: an uncomparable observed version is never Succeeded.'

# Provider is config-gated, and the gate is documented in the shipped example config.
$exampleCfg = Get-Content -Path $exampleConfigPath -Raw | ConvertFrom-Json
Assert-True ($null -ne $exampleCfg.PackageManagers.PSObject.Properties['PythonManagerEnabled']) 'Example config should expose PackageManagers.PythonManagerEnabled.'
# The provider must be reachable from the update pipeline, not merely defined.
Assert-True ((Get-Content -Path $scriptPath -Raw) -match '@\(Invoke-PythonManagerProvider\)') 'Invoke-PythonManagerProvider must be wired into the update pipeline.'

#-- NVD inventory vulnerability scan (report-only; NVD CPE dictionary + CVE API) -----
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-CpeVersionString')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-BestCpeMatch')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-CvssFromCve')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-CvssSeverityRank')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-NVDVulnFinding')

# CPE version sanitisation: clean dotted-numeric passes, anything else signals fallback.
Assert-True ((ConvertTo-CpeVersionString '100.0.4896.60') -eq '100.0.4896.60') 'CPE version: clean dotted-numeric passes through.'
Assert-True ((ConvertTo-CpeVersionString 'v22.00') -eq '22.00') 'CPE version: leading v is stripped.'
Assert-True ((ConvertTo-CpeVersionString '1.2 (build 3)') -eq '') 'CPE version: a trailing suffix means the version is not CPE-reliable.'
Assert-True ((ConvertTo-CpeVersionString '2024-beta') -eq '') 'CPE version: non-numeric forms signal local-filter fallback.'
Assert-True ((ConvertTo-CpeVersionString '') -eq '') 'CPE version: empty input yields empty.'

# CPE dictionary match: collapse per-version CPEs to one product; never guess.
$cpesFixture = Get-Content -Path (Join-Path $fixtureDir 'nvd-cpes-sample.json') -Raw | ConvertFrom-Json
$chromeCpe = Resolve-BestCpeMatch -CpesResponse $cpesFixture -Name 'Google Chrome' -Publisher 'Google LLC'
Assert-True ($chromeCpe -eq 'cpe:2.3:a:google:chrome:*:*:*:*:*:*:*:*') 'CPE match: Google Chrome/Google LLC -> canonical google:chrome application CPE.'
# A response containing ONLY OS-part / deprecated entries must yield no match: the scan
# targets applications, and a deprecated CPE is no longer canonical.
$nonAppOnly = [pscustomobject]@{ products = @(
    [pscustomobject]@{ cpe = [pscustomobject]@{ deprecated = $false; cpeName = 'cpe:2.3:o:google:chrome_os:1.0:*:*:*:*:*:*:*' } }
    [pscustomobject]@{ cpe = [pscustomobject]@{ deprecated = $true;  cpeName = 'cpe:2.3:a:google:chrome:0.1.0.0:*:*:*:*:*:*:*' } }
) }
Assert-True ($null -eq (Resolve-BestCpeMatch -CpesResponse $nonAppOnly -Name 'Google Chrome' -Publisher 'Google LLC')) 'CPE match: OS-part and deprecated CPEs are never application matches.'
Assert-True ($null -eq (Resolve-BestCpeMatch -CpesResponse $null -Name 'Google Chrome' -Publisher 'Google')) 'CPE match: a null response resolves to $null.'
Assert-True ($null -eq (Resolve-BestCpeMatch -CpesResponse $cpesFixture -Name 'Totally Unrelated App' -Publisher 'Acme')) 'CPE match: no product-token overlap -> $null, never a guess.'
# Ambiguity: two distinct products with equal scores must yield $null.
$ambiguous = [pscustomobject]@{ products = @(
    [pscustomobject]@{ cpe = [pscustomobject]@{ deprecated = $false; cpeName = 'cpe:2.3:a:foo:editor:1.0:*:*:*:*:*:*:*' } }
    [pscustomobject]@{ cpe = [pscustomobject]@{ deprecated = $false; cpeName = 'cpe:2.3:a:bar:editor:1.0:*:*:*:*:*:*:*' } }
) }
Assert-True ($null -eq (Resolve-BestCpeMatch -CpesResponse $ambiguous -Name 'Editor' -Publisher 'Someone Else')) 'CPE match: a tie between distinct products is ambiguous -> $null.'
# ...but a vendor hit breaks the tie.
Assert-True ((Resolve-BestCpeMatch -CpesResponse $ambiguous -Name 'Editor' -Publisher 'Foo Inc') -eq 'cpe:2.3:a:foo:editor:*:*:*:*:*:*:*:*') 'CPE match: a Publisher/vendor hit breaks the tie.'

# CVSS extraction: v3.1 preferred, v3.0 fallback, v2-only -> $null.
$cveFixture = Get-Content -Path (Join-Path $fixtureDir 'nvd-cve-by-cpe-sample.json') -Raw | ConvertFrom-Json
$vulns = @($cveFixture.vulnerabilities)
$c31 = Get-CvssFromCve $vulns[0].cve
Assert-True ($c31.Severity -eq 'CRITICAL' -and $c31.Score -eq 9.8) 'CVSS: v3.1 metric extracted with score and severity.'
$c30 = Get-CvssFromCve $vulns[1].cve
Assert-True ($c30.Severity -eq 'HIGH' -and $c30.Score -eq 7.5) 'CVSS: v3.0 fallback when no v3.1 metric exists.'
Assert-True ($null -eq (Get-CvssFromCve $vulns[2].cve)) 'CVSS: a v2-only CVE yields $null (no v3 signal).'
Assert-True ((Get-CvssSeverityRank 'CRITICAL') -gt (Get-CvssSeverityRank 'HIGH')) 'CVSS rank: CRITICAL outranks HIGH.'
Assert-True ((Get-CvssSeverityRank 'bogus') -eq 0) 'CVSS rank: unknown severity ranks lowest.'

# Grouped finding shape: counts, top severity, ranked CVE order.
$nvdFinding = New-NVDVulnFinding -Item 'Google Chrome' -InstalledVersion '100.0.4896.60' -Cpe 'cpe:2.3:a:google:chrome:*:*:*:*:*:*:*:*' -Cves @(
    [pscustomobject]@{ CVE='CVE-2022-0002'; CvssScore=8.8; CvssSeverity='HIGH';     Description='high';  Published='2022-01-01' }
    [pscustomobject]@{ CVE='CVE-2024-1283'; CvssScore=9.8; CvssSeverity='CRITICAL'; Description='crit';  Published='2024-02-07' }
)
Assert-True ($nvdFinding.Severity -eq 'CRITICAL' -and $nvdFinding.MaxCvss -eq 9.8) 'NVD finding: top severity/score comes from the worst CVE.'
Assert-True ($nvdFinding.CveCount -eq 2 -and $nvdFinding.CriticalCount -eq 1 -and $nvdFinding.HighCount -eq 1) 'NVD finding: per-severity counts are correct.'
Assert-True ($nvdFinding.Cves[0].CVE -eq 'CVE-2024-1283') 'NVD finding: CVE list is ranked worst-first.'

# Report-only isolation: the scan must never touch the emergency path, and the queue
# tier must sit BELOW confirmed KEV. Source-level assertions keep this from regressing.
$mainSrc = Get-Content -Path $scriptPath -Raw
Assert-True ($mainSrc -match '(?s)EmergencyPatch\s*-and\s+-not\s+\$ReportOnly.*?NVD inventory scan: deferred') 'NVD scan must be deferred on an emergency run, never delay a KEV patch.'
Assert-True ($mainSrc -notmatch '(?s)NVDVulnFindings[^\r\n]*EmergencyPatch\s*=\s*\$true') 'NVD findings must never set the emergency flag.'
Assert-True ($mainSrc -match '-NVDFindings \$script:NVDVulnFindings') 'NVD findings must feed the patch-queue prioritiser.'
Assert-True ($mainSrc -match 'coveredWinGetCandidates') 'Browser/vendor overlap suppression must depend on successful WinGet coverage, not discovery alone.'
Assert-True ($mainSrc -match 'Invoke-BrowserProvider -Browser Chrome -WinGetCandidates \$coveredWinGetCandidates') 'Chrome native fallback must remain available after a failed or deferred WinGet row.'
# HTML report renders the NVD panel with the danger tone only when a Critical exists.
$script:Stats.KEVMatches = 0
$savedDryRunForVerdict = $DryRun
$DryRun = [System.Management.Automation.SwitchParameter]::new($false)
$nvdHtml = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @() -StalenessFindings @() -EndOfLifeFindings @() -NVDVulnFindings @($nvdFinding)
Assert-True ($nvdHtml -match 'Known vulnerabilities \(NVD\)') 'HTML report should render the NVD panel when findings exist.'
Assert-True ($nvdHtml -match 'not necessarily <em>actively exploited</em>') 'NVD panel must distinguish itself from KEV (known vs actively exploited).'
Assert-True ($nvdHtml -match 'nvd\.nist\.gov/vuln/detail/CVE-2024-1283') 'NVD panel should link CVEs to nvd.nist.gov.'
Assert-True ($nvdHtml -match 'verdict-rail danger') 'An NVD-critical-only report must use the red verdict instead of false-green completion.'
Assert-True ($nvdHtml -match 'Exposure needs action\.') 'An NVD-critical-only report should expose the action verdict.'
Assert-True ($nvdHtml -match "status fail'>Critical") 'Critical NVD evidence must use the implemented red failure badge class.'
$highOnly = New-NVDVulnFinding -Item '7-Zip' -InstalledVersion '22.00' -Cpe 'cpe:2.3:a:7-zip:7-zip:*:*:*:*:*:*:*:*' -Cves @(
    [pscustomobject]@{ CVE='CVE-2024-11477'; CvssScore=7.8; CvssSeverity='HIGH'; Description='zstd'; Published='2024-11-22' }
)
$nvdHighHtml = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @() -StalenessFindings @() -EndOfLifeFindings @() -NVDVulnFindings @($highOnly)
$DryRun = $savedDryRunForVerdict
Assert-True ($nvdHighHtml -notmatch "danger-panel'><div class='section-head'><div><p class='eyebrow'>Known vulnerabilities") 'An NVD panel with no Critical must not take the danger tone.'
Assert-True ($nvdHighHtml -match 'verdict-rail attention') 'An NVD-high-only report should use the amber review verdict.'
Assert-True ($nvdHighHtml -match 'panel review-panel') 'An NVD-high-only panel should use amber review styling.'

# Example config exposes both new blocks.
Assert-True ($null -ne $exampleCfg.PSObject.Properties['NVDInventoryScan']) 'Example config should expose the NVDInventoryScan block.'
Assert-True ($exampleCfg.NVDInventoryScan.Enabled -eq $false) 'NVDInventoryScan must ship opt-in (off).'
Assert-True ($null -ne $exampleCfg.NVD.PSObject.Properties['DataSource'] -and $null -ne $exampleCfg.NVD.PSObject.Properties['MirrorBaseUrl']) 'Example config should expose NVD.DataSource and NVD.MirrorBaseUrl.'

#-- End-of-life report (report-only; endoflife.date) --------------------------------
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-VersionCycleKeys')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ReleaseLatestName')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-EolReleaseForVersion')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-WindowsEolRelease')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-EolStatus')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-EndOfLifeFinding')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-EolFindingFromRelease')

# Cycle-key extraction: most specific first.
Assert-True (((ConvertTo-VersionCycleKeys '3.9.13') -join ',') -eq '3.9,3') 'Cycle keys: 3.9.13 -> 3.9,3.'
Assert-True (((ConvertTo-VersionCycleKeys 'v20.11.1') -join ',') -eq '20.11,20') 'Cycle keys: v20.11.1 -> 20.11,20 (strips leading v).'
Assert-True (@(ConvertTo-VersionCycleKeys '').Count -eq 0) 'Cycle keys: empty input yields nothing.'

$winReleases = @((Get-Content -Path (Join-Path $fixtureDir 'eol-windows.json') -Raw | ConvertFrom-Json).result.releases)
$pyReleases  = @((Get-Content -Path (Join-Path $fixtureDir 'eol-python.json')  -Raw | ConvertFrom-Json).result.releases)

# Runtime major.minor mapping.
$py39 = Resolve-EolReleaseForVersion -Releases $pyReleases -InstalledVersion '3.9.13'
Assert-True ($py39.name -eq '3.9') 'Python 3.9.13 should resolve to cycle 3.9.'
Assert-True ((Test-EolStatus -Release $py39).Status -eq 'EOL') 'Python 3.9 is past its EOL date -> EOL.'
$py313 = Resolve-EolReleaseForVersion -Releases $pyReleases -InstalledVersion '3.13.1'
Assert-True ((Test-EolStatus -Release $py313).Status -eq 'Supported') 'Python 3.13 is supported.'

# Windows build + edition disambiguation (consumer W vs enterprise E share a build).
$w23Pro = Resolve-WindowsEolRelease -Releases $winReleases -Build '22631' -Edition 'Professional'
Assert-True ($w23Pro.name -eq '11-23h2-w') 'Windows build 22631 on Pro should map to the consumer 23H2 (W) cycle.'
Assert-True ((Test-EolStatus -Release $w23Pro).Status -eq 'EOL') 'Windows 23H2 (W) is out of support -> EOL.'
$w23Ent = Resolve-WindowsEolRelease -Releases $winReleases -Build '22631' -Edition 'Enterprise'
Assert-True ($w23Ent.name -eq '11-23h2-e') 'Windows build 22631 on Enterprise should map to the 23H2 (E) cycle.'
Assert-True ((Test-EolStatus -Release $w23Ent).Status -in @('Supported','NearEOL')) 'Windows 23H2 (E) remains in support, including the warning window.'
$w25Pro = Resolve-WindowsEolRelease -Releases $winReleases -Build '26200' -Edition 'Professional'
Assert-True ($w25Pro.name -eq '11-25h2-w') 'Windows build 26200 on Pro should map to the supported 25H2 (W) cycle.'
Assert-True ($null -eq (Resolve-WindowsEolRelease -Releases $winReleases -Build '99999' -Edition 'Professional')) 'An unknown build resolves to $null (no crash under StrictMode).'
Assert-True ($null -eq (Resolve-EolReleaseForVersion -Releases @() -InstalledVersion '1.0')) 'Empty release list resolves to $null.'

# Test-EolStatus boundaries around the warning window (deterministic, now-relative).
$relPast   = [pscustomobject]@{ name='x'; isEol=$true;  eolFrom=(Get-Date).AddDays(-5).ToString('yyyy-MM-dd');  latest=[pscustomobject]@{ name='9' } }
$relNear   = [pscustomobject]@{ name='x'; isEol=$false; eolFrom=(Get-Date).AddDays(30).ToString('yyyy-MM-dd');  latest=[pscustomobject]@{ name='9' } }
$relFuture = [pscustomobject]@{ name='x'; isEol=$false; eolFrom=(Get-Date).AddDays(400).ToString('yyyy-MM-dd'); latest=[pscustomobject]@{ name='9' } }
Assert-True ((Test-EolStatus -Release $relPast   -WarnWithinDays 90).Status -eq 'EOL')       'Test-EolStatus: past eolFrom -> EOL.'
Assert-True ((Test-EolStatus -Release $relNear   -WarnWithinDays 90).Status -eq 'NearEOL')   'Test-EolStatus: within the warning window -> NearEOL.'
Assert-True ((Test-EolStatus -Release $relFuture -WarnWithinDays 90).Status -eq 'Supported') 'Test-EolStatus: beyond the warning window -> Supported.'
Assert-True ((Test-EolStatus -Release $null).Status -eq 'Unknown') 'Test-EolStatus: a null release -> Unknown.'

# Finding shape: EOL is a review finding; fully current is info.
$eolFinding = New-EolFindingFromRelease -Product 'python' -Item 'Python' -InstalledVersion '3.9.13' -Release $py39 -WarnWithinDays 90 -Recommendation 'Upgrade Python.'
Assert-True ($eolFinding.Severity -eq 'review' -and $eolFinding.Status -eq 'EOL' -and $eolFinding.LatestSupported -eq '3.9.25') 'EOL finding should be a review with latest-supported populated.'
$okFinding = New-EolFindingFromRelease -Product 'python' -Item 'Python' -InstalledVersion '3.13.14' -Release $py313 -WarnWithinDays 90
Assert-True ($okFinding.Severity -eq 'info' -and $okFinding.Status -eq 'Supported') 'A supported release on its latest patch should be info.'

# Patch-level drift inside a supported release line is a review finding, not silence.
# Regression: Python 3.14.5 with 3.14.6 available was reported as Supported/info.
$behindFinding = New-EolFindingFromRelease -Product 'python' -Item 'Python' -InstalledVersion '3.13.1' -Release $py313 -WarnWithinDays 90
Assert-True ($behindFinding.Status -eq 'PatchBehind') 'A supported cycle with a newer patch release -> PatchBehind.'
Assert-True ($behindFinding.Severity -eq 'review') 'PatchBehind must be a review finding, not info.'
Assert-True ($behindFinding.Recommendation -match '3\.13\.14') 'PatchBehind should recommend the specific latest patch release.'
Assert-True ($behindFinding.Detail -match 'behind 3\.13\.14') 'PatchBehind detail should name the version it is behind.'

# Windows reports a bare build against a '10.0.<build>' latest - different scales, so
# patch drift must not be inferred there.
$winFinding = New-EolFindingFromRelease -Product 'windows' -Item 'Windows 25H2' -InstalledVersion '26200' -Release $w25Pro -WarnWithinDays 90 -SkipPatchDrift
Assert-True ($winFinding.Status -eq 'Supported') 'Windows build vs 10.0.x latest must not be graded as PatchBehind.'

# .NET is the same trap: `dotnet --version` reports the SDK version (third component is
# a feature band, >= 100) while endoflife.date's dotnet 'latest' is the RUNTIME version
# (e.g. 9.0.17). SDK 9.0.100 compares ABOVE runtime 9.0.17, so drift never fires today -
# and becomes a false positive the day a runtime patch reaches .100. Suppress it outright.
$dotnetRel = [pscustomobject]@{ name='9'; isEol=$false; eolFrom=(Get-Date).AddDays(400).ToString('yyyy-MM-dd'); latest=[pscustomobject]@{ name='9.0.17' } }
$dotnetFinding = New-EolFindingFromRelease -Product 'dotnet' -Item '.NET' -InstalledVersion '9.0.100' -Release $dotnetRel -WarnWithinDays 90 -SkipPatchDrift
Assert-True ($dotnetFinding.Status -eq 'Supported') '.NET SDK version vs runtime latest must not be graded as PatchBehind.'
Assert-True ((Compare-SoftwareVersion '9.0.100' '9.0.17') -eq 1) 'SDK feature band 9.0.100 compares above runtime 9.0.17 - the scale mismatch the skip guards.'
# The runtime table must actually carry the flag, or the guard above is decorative.
Assert-True ((Get-Content -Path $scriptPath -Raw) -match "Product = 'dotnet';[^\r\n]*SkipPatchDrift = \`$true") '.NET must be declared SkipPatchDrift in the runtime table.'
Assert-True ((Get-Content -Path $scriptPath -Raw) -match "Product = 'python';[^\r\n]*SkipPatchDrift = \`$false") 'Python must NOT skip patch drift - it reports the version endoflife.date tracks.'

# HTML report renders the End-of-life panel when findings exist.
$eolFindings = @(
    (New-EolFindingFromRelease -Product 'windows' -Item 'Windows 23H2 (build 22631)' -InstalledVersion '22631' -Release $w23Pro -WarnWithinDays 90 -SkipPatchDrift -Recommendation 'Upgrade Windows.')
    $okFinding
    $behindFinding
)
$savedDryRunForVerdict = $DryRun
$DryRun = [System.Management.Automation.SwitchParameter]::new($false)
$eolHtml = New-HTMLReport -Results $sourceRows -KEVMatches @() -SLABreaches @() -Elapsed 0.1 -Metrics ([pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches @() -StalenessFindings @() -EndOfLifeFindings $eolFindings
$DryRun = $savedDryRunForVerdict
Assert-True ($eolHtml -match 'End-of-life') 'HTML report should render the End-of-life panel when findings exist.'
Assert-True ($eolHtml -match 'endoflife\.date') 'EOL panel should credit its data source.'
Assert-True ($eolHtml -match 'End of life') 'EOL panel should show the End of life status badge for an EOL row.'
Assert-True ($eolHtml -match 'Behind latest') 'EOL panel should show the Behind latest badge for a PatchBehind row.'
Assert-True ($eolHtml -match 'verdict-rail danger') 'An EOL-only report must use the red verdict instead of false-green completion.'
Assert-True ($eolHtml -match "status fail'>End of life") 'Confirmed EOL evidence must use the implemented red failure badge class.'

#-- KEV report rendering: exposure state must be visible, and tone must follow it ----
$kevNotAffected = [pscustomobject]@{
    CVE='CVE-2020-16017'; VendorProject='Google'; Product='Chrome'; Description='Use-After-Free'
    DateAdded='2021-11-03'; CISADueDate='2022-05-03'; InstalledApp='Google Chrome'
    InstalledVer='150.0.7871.47'; PackageId='Google.Chrome'; Source='winget'
    ExposureState='NotAffected'; FixedVersion='86.0.4240.198'; ExposureDetail='Outside the NVD vulnerable range.'
}
$kevAffected = [pscustomobject]@{
    CVE='CVE-2020-16017'; VendorProject='Google'; Product='Chrome'; Description='Use-After-Free'
    DateAdded='2021-11-03'; CISADueDate='2022-05-03'; InstalledApp='Google Chrome'
    InstalledVer='86.0.4240.197'; PackageId='Google.Chrome'; Source='winget'
    ExposureState='Affected'; FixedVersion='86.0.4240.198'; ExposureDetail='Inside the NVD vulnerable range.'
}
$emptyMetrics = [pscustomobject]@{ AvgDaysToApply='N/A'; TotalTracked=0; Applied=0; Pending=0 }

$script:Stats.KEVMatches = 0
$kevCleanHtml = New-HTMLReport -Results $sourceRows -KEVMatches @($kevNotAffected) -SLABreaches @() -Elapsed 0.1 -Metrics $emptyMetrics -InventoryKEVMatches @()
Assert-True ($kevCleanHtml -match 'Not affected') 'KEV panel should render the Not affected badge.'
Assert-True ($kevCleanHtml -match 'KEV product history, no confirmed exposure') 'A name-only KEV match must not be presented as an exposure.'
Assert-True ($kevCleanHtml -match 'no version data') 'KEV panel should state that the catalogue carries no version data.'
Assert-True ($kevCleanHtml -notmatch "danger-panel'><div class='section-head'><div><p class='eyebrow'>CISA KEV</p>") 'A KEV panel with no confirmed exposure must not use the danger tone.'

$script:Stats.KEVMatches = 1
$kevDangerHtml = New-HTMLReport -Results $sourceRows -KEVMatches @($kevAffected) -SLABreaches @() -Elapsed 0.1 -Metrics $emptyMetrics -InventoryKEVMatches @()
Assert-True ($kevDangerHtml -match '1 confirmed KEV exposure') 'A confirmed exposure should be headlined as such.'
Assert-True ($kevDangerHtml -match '>Affected<') 'KEV panel should render the Affected badge.'
Assert-True ($kevDangerHtml -match '86\.0\.4240\.198') 'KEV panel should show the fixing version.'
$script:Stats.KEVMatches = 0

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

# Reboot codes are per-OEM. Dell's exit 2 is a FATAL error - a shared reboot-code
# list previously classified it as success + reboot required.
$fwDell = $fwCat | Where-Object { $_.Provider -eq 'firmware-dell' } | Select-Object -First 1
Assert-True (1 -in @($fwDell.RebootCodes) -and 5 -in @($fwDell.RebootCodes)) 'Dell reboot codes must include 1 and 5.'
Assert-True (2 -notin @($fwDell.RebootCodes)) 'Dell exit code 2 (fatal error) must NOT be a reboot/success code.'
$fwHp = $fwCat | Where-Object { $_.Provider -eq 'firmware-hp' } | Select-Object -First 1
Assert-True (3010 -in @($fwHp.RebootCodes)) 'HP reboot codes must include 3010 (MSI convention).'
$fwLenovo = $fwCat | Where-Object { $_.Provider -eq 'firmware-lenovo' } | Select-Object -First 1
Assert-True (@($fwLenovo.RebootCodes).Count -eq 0) 'Lenovo trusts only exit 0 (no documented reboot codes).'

# File-version helper (browser/Brave verification reads the binary, not BLBeacon).
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-InstalledFileVersion')
Assert-True ((Get-InstalledFileVersion -Candidates @('C:\definitely\missing\a.exe')) -eq '') 'Get-InstalledFileVersion returns empty for missing files.'
$cmdVer = Get-InstalledFileVersion -Candidates @((Join-Path $env:SystemRoot 'System32\cmd.exe'))
Assert-True ($cmdVer -match '\d') 'Get-InstalledFileVersion should read a real product version from cmd.exe.'

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
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-PatchMetrics')

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
    $disabledMetrics = Get-PatchMetrics -State $state -Enabled $false
    Assert-True ($disabledMetrics.TotalTracked -eq 0 -and $disabledMetrics.Pending -eq 0 -and $disabledMetrics.SLABreaches -eq 0) 'SLA-disabled metrics must not surface stale tracked state.'

    # Applying the update clears the breach
    $appliedRow = [pscustomobject]@{ PackageId = 'Vendor.App'; Success = $true; Status = 'Succeeded'; ConfirmedVersion = '2.0'; AvailableVersion = '2.0'; NewVer = '2.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @() -AppliedResults @($appliedRow)
    Assert-True ($state.TrackedUpdates[0].Applied) 'SLA state: applied result should mark the tracked update applied.'
    Assert-True (@(Get-SLABreaches -State $state).Count -eq 0) 'SLA state: applied update should no longer breach.'

    # A failed discovery must not close pending rows, but a healthy discovery
    # that no longer offers the exact update must resolve it rather than leave a
    # permanent false breach.
    $gone = [pscustomobject]@{ PackageId = 'Gone.App'; Name = 'Gone App'; Available = '4.0'; Version = '3.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @($gone) -AppliedResults @()
    $goneEntry = @($state.TrackedUpdates | Where-Object PackageId -eq 'Gone.App')[0]
    $goneEntry.SLADue = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd')
    $state = Save-PatchState -State $state -AvailableUpgrades @() -AppliedResults @() -DiscoveryHealthy $false
    Assert-True (-not [bool]$goneEntry.Closed) 'SLA state: failed discovery must not resolve a pending update.'
    $state = Save-PatchState -State $state -AvailableUpgrades @() -AppliedResults @() -DiscoveryHealthy $true
    Assert-True ([bool]$goneEntry.Closed) 'SLA state: a no-longer-offered update should close after healthy discovery.'
    Assert-True (@(Get-SLABreaches -State $state | Where-Object PackageId -eq 'Gone.App').Count -eq 0) 'SLA state: resolved rows must not remain breached.'

    # When an older version is already pending and a newer version is discovered
    # and applied in the same run, the exact new row must be marked applied.
    $old = [pscustomobject]@{ PackageId = 'Multi.App'; Name = 'Multi App'; Available = '2.0'; Version = '1.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @($old) -AppliedResults @()
    $new = [pscustomobject]@{ PackageId = 'Multi.App'; Name = 'Multi App'; Available = '3.0'; Version = '1.0' }
    $newApplied = [pscustomobject]@{ PackageId = 'Multi.App'; Success = $true; Status = 'Succeeded'; ConfirmedVersion = '3.0'; AvailableVersion = '3.0'; NewVer = '3.0' }
    $state = Save-PatchState -State $state -AvailableUpgrades @($new) -AppliedResults @($newApplied)
    $newEntry = @($state.TrackedUpdates | Where-Object { $_.PackageId -eq 'Multi.App' -and $_.VersionAvailable -eq '3.0' })[0]
    Assert-True ([bool]$newEntry.Applied) 'SLA state: exact newly-added version should be marked applied in the same run.'

    # State survives a round-trip through the JSON file
    $state2 = Get-PatchState
    Assert-True (@($state2.TrackedUpdates).Count -ge 1) 'SLA state: state file round-trip should preserve tracked updates.'
    Assert-True (@($state2.TrackedUpdates | Where-Object { $_.PackageId -eq 'Vendor.App' -and $_.Applied }).Count -eq 1) 'SLA state: applied flag should persist to disk.'
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
$selfUpdateFnText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-SelfUpdate'
Assert-True ($selfUpdateFnText -notmatch 'Skipped \(git clone') 'Self-update: git-clone installs must not be skipped because the documented install path uses git clone.'
Assert-True ($selfUpdateFnText -notmatch 'running from a git clone') 'Self-update: legacy git-clone skip message must not return.'
Assert-True ($selfUpdateFnText -match 'replacing Invoke-PatchManager\.ps1 only') 'Self-update: git-clone installs should make clear that only the runnable script is replaced.'
Assert-True (Test-SelfUpdateSource -Repository 'ciaranwhiteside/PatchManager' -Ref 'main') 'Self-update: default GitHub source should validate.'
Assert-True (Test-SelfUpdateSource -Repository 'owner-name/repo.name' -Ref 'release/v1.2.3') 'Self-update: normal branch/tag refs should validate.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'https://github.com/owner/repo' -Ref 'main')) 'Self-update: repository must be owner/name, not a URL.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'owner/repo' -Ref '../main')) 'Self-update: ref traversal should be rejected.'
Assert-True (-not (Test-SelfUpdateSource -Repository 'owner/repo' -Ref 'main?raw=1')) 'Self-update: refs with URL metacharacters should be rejected.'
Assert-True (Test-SelfUpdateSource -Repository 'ciaranwhiteside/PatchManager' -Ref 'latest') 'Self-update: the default "latest" ref should validate.'
Assert-True (Test-SelfUpdateSource -Repository 'ciaranwhiteside/PatchManager' -Ref 'v1.2.0') 'Self-update: a resolved release tag should validate.'

# Latest-release tag extraction + ref resolution.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-LatestReleaseTagFromJson')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-SelfUpdateRef')
Assert-True ((Get-LatestReleaseTagFromJson -Json '{"tag_name":"v1.2.0","name":"x"}') -eq 'v1.2.0') 'Self-update: tag_name should be extracted from the releases API JSON.'
Assert-True ($null -eq (Get-LatestReleaseTagFromJson -Json '{"name":"no tag"}')) 'Self-update: missing tag_name should yield null.'
Assert-True ($null -eq (Get-LatestReleaseTagFromJson -Json 'not json')) 'Self-update: malformed JSON should yield null, not throw.'
Assert-True ((Resolve-SelfUpdateRef -Repository 'owner/repo' -Ref 'v9.9.9' -TimeoutSec 5) -eq 'v9.9.9') 'Self-update: a non-latest ref must pass through without a network call.'

#-- Scheduled-run UX regressions -----------------------------------------------------
# Live-session assertions would be flaky on session-0 CI runners, so assert on
# the function/task-builder source instead.
$interactiveFnText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Test-InteractiveSession'
Assert-True ($interactiveFnText -notmatch 'SESSIONNAME') 'Test-InteractiveSession must not depend on SESSIONNAME - Task Scheduler never sets it, which suppressed all popups on scheduled runs.'
Assert-True ($interactiveFnText -match 'SessionId') 'Test-InteractiveSession should gate on the process session id (session 0 = services).'

$taskInstallText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Install-PatchManagerStartupTask'
Assert-True ($taskInstallText -match '-WindowStyle Hidden') 'The startup task must run PowerShell hidden so scheduled runs stay in the background.'

$mainText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-Main'
$earlyRunText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Complete-EarlyRun'
Assert-True ($earlyRunText -match 'CFG\.SLA\.Enabled') 'Early-run reports must respect profile-resolved SLA tracking.'
$liveScriptText = Get-Content -Path $scriptPath -Raw
Assert-True ($liveScriptText -notmatch '#Requires\s+-RunAsAdministrator') '-ValidateConfig must remain usable from a non-elevated session.'
Assert-True ($mainText -match 'Test-IsAdministrator') 'Live patch and task operations must retain an explicit administrator gate.'
Assert-True ($earlyRunText -match 'New-ComplianceReport') 'Early terminal paths must generate a compliance report.'
Assert-True ($mainText -match "Complete-EarlyRun -Name 'Pre-flight failure'") 'Pre-flight failures must be fleet-visible reports.'
Assert-True ($mainText -match "Complete-EarlyRun -Name 'User-active deferral'") 'User-active deferrals must be fleet-visible reports.'
Assert-True ($mainText -match "Complete-EarlyRun -Name 'Maintenance-window deferral'") 'Maintenance-window deferrals must be fleet-visible reports.'
Assert-True ($mainText -match "Complete-EarlyRun -Name 'Overlapping instance'") 'Overlapping attempts must be fleet-visible reports.'

#-- Fleet terminal-disposition integration ------------------------------------------
$fleetFixtureRoot = Join-Path $PSScriptRoot 'Fixtures\FleetCentral'
$fleetOutputDir = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-test-$([guid]::NewGuid())"
try {
    & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $fleetFixtureRoot -OutputPath $fleetOutputDir -StaleDays 9999
    $fleetCsvPath = Get-ChildItem $fleetOutputDir -Filter 'FleetReport_*.csv' | Select-Object -First 1
    $fleetHtmlPath = Get-ChildItem $fleetOutputDir -Filter 'FleetReport_*.html' | Select-Object -First 1
    Assert-True ($null -ne $fleetCsvPath -and $null -ne $fleetHtmlPath) 'Fleet integration: HTML and CSV should be generated.'
    $fleetRow = Import-Csv $fleetCsvPath.FullName | Select-Object -First 1
    Assert-True ($fleetRow.ProvidersExecuted -eq 'False') 'Fleet integration: terminal report must preserve ProvidersExecuted=false.'
    Assert-True ($fleetRow.Note -eq 'Maintenance-window deferral') 'Fleet integration: terminal disposition should appear in Notes.'
    $fleetHtmlText = Get-Content $fleetHtmlPath.FullName -Raw
    Assert-True ($fleetHtmlText -match "data-posture='attention'") 'Fleet integration: a terminal deferral must be classified as attention.'
    Assert-True ($fleetHtmlText -match 'Review the deferral reason and confirm the next eligible patch run') 'Fleet UI: deferred hosts should have a specific next step.'
    Assert-True ($fleetHtmlText -match 'Failed / deferred') 'Fleet integration: dashboard should expose deferred provider runs.'
    Assert-True ($fleetHtmlText -match 'Security hosts') 'Fleet integration: an all-Personal estate should use neutral security wording without SLA labels.'
    Assert-True ($fleetHtmlText -notmatch 'SLA pressure|KEV / SLA') 'Fleet integration: an all-Personal estate with no breaches should not advertise SLA pressure.'
    Assert-True ($fleetHtmlText -match 'class="lane danger" data-risk-filter="failure"') 'Fleet integration: a deferred host should mark only its execution path as action-required.'
    Assert-True ($fleetHtmlText -match 'class="lane good" data-risk-filter="security"') 'Fleet integration: a zero-count security path should render verified.'
    Assert-True ($fleetHtmlText -match 'class="lane good" data-risk-filter="stale"') 'Fleet integration: a zero-count currency path should render verified.'
    Assert-True ($fleetHtmlText -match 'class="lane good" data-risk-filter="eol"') 'Fleet integration: a zero-count lifecycle path should render verified.'
    Assert-True ($fleetHtmlText -match 'class="lane good" data-risk-filter="reboot"') 'Fleet integration: a zero-count completion path should render verified.'
} finally {
    Remove-Item $fleetOutputDir -Recurse -Force -EA SilentlyContinue
}

#-- Fleet clear-estate health-map semantics -----------------------------------------
$fleetClearRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-clear-$([guid]::NewGuid())"
$fleetClearOutput = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-clear-output-$([guid]::NewGuid())"
try {
    $clearHostDir = New-Item -ItemType Directory -Path (Join-Path $fleetClearRoot 'CLEAR-HOST') -Force
    $clearReport = [ordered]@{
        Metadata = [ordered]@{ Hostname='CLEAR-HOST'; ScriptVer='test'; Ring='Pilot'; ScopeProfile='Personal'; DryRun=$false; ProvidersExecuted=$true; RunDisposition='' }
        Statistics = [ordered]@{ UpdatesApplied=3; UpdatesFailed=0; UpdatesSkipped=0; KEVMatches=0; NvdCritical=0; NvdHigh=0; SLABreaches=0; Errors=@() }
        AttentionItems = @()
        RebootRequiredItems = @()
        InventoryKEVMatches = @()
        EndOfLifeFindings = @()
        StalenessFindings = @()
    }
    $clearJson = Join-Path $clearHostDir.FullName 'PatchReport_CLEAR-HOST_20991231_235959_000.json'
    $clearReport | ConvertTo-Json -Depth 8 | Set-Content -Path $clearJson -Encoding UTF8
    & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $fleetClearRoot -OutputPath $fleetClearOutput -StaleDays 9999
    $clearHtmlPath = Get-ChildItem $fleetClearOutput -Filter 'FleetReport_*.html' | Select-Object -First 1
    $clearHtml = Get-Content $clearHtmlPath.FullName -Raw
    Assert-True ($clearHtml -match 'class="fleet-verdict good"') 'Fleet clear integration: a clean estate should use the verified verdict tone.'
    foreach ($risk in @('security','failure','stale','eol','reboot')) {
        Assert-True ($clearHtml -match ('class="lane good" data-risk-filter="' + $risk + '"')) "Fleet clear integration: the $risk path should render verified when its predicate count is zero."
    }
} finally {
    Remove-Item $fleetClearRoot -Recurse -Force -EA SilentlyContinue
    Remove-Item $fleetClearOutput -Recurse -Force -EA SilentlyContinue
}

#-- Fleet malformed/empty-host resilience ------------------------------------------
$fleetEdgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-edge-$([guid]::NewGuid())"
$fleetEdgeOutput = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-edge-output-$([guid]::NewGuid())"
try {
    $brokenHostDir = New-Item -ItemType Directory -Path (Join-Path $fleetEdgeRoot 'BrokenHost') -Force
    [void](New-Item -ItemType Directory -Path (Join-Path $fleetEdgeRoot 'EmptyHost') -Force)
    $brokenJsonPath = Join-Path $brokenHostDir.FullName 'PatchReport_BrokenHost_20260827_000000_000.json'
    Set-Content -Path $brokenJsonPath -Value '{ malformed json' -Encoding UTF8
    Set-Content -Path ([System.IO.Path]::ChangeExtension($brokenJsonPath, '.html')) -Value '<!DOCTYPE html><title>Broken host evidence</title>' -Encoding UTF8

    $invalidReports = [ordered]@{
        EmptyObject = '{}'
        NullReport = 'null'
        ArrayReport = '[{},{}]'
        MissingStatistics = '{"Metadata":{}}'
        MissingCounters = '{"Metadata":{},"Statistics":{}}'
        InvalidCounter = '{"Metadata":{},"Statistics":{"UpdatesApplied":0,"UpdatesFailed":"invalid","UpdatesSkipped":0}}'
        NegativeCounter = '{"Metadata":{},"Statistics":{"UpdatesApplied":0,"UpdatesFailed":-1,"UpdatesSkipped":0}}'
        OverflowCounter = '{"Metadata":{},"Statistics":{"UpdatesApplied":0,"UpdatesFailed":2147483648,"UpdatesSkipped":0}}'
        StringBoolean = '{"Metadata":{"ProvidersExecuted":"false"},"Statistics":{"UpdatesApplied":0,"UpdatesFailed":0,"UpdatesSkipped":0}}'
    }
    foreach ($name in $invalidReports.Keys) {
        $invalidDir = New-Item -ItemType Directory -Path (Join-Path $fleetEdgeRoot $name) -Force
        Set-Content -LiteralPath (Join-Path $invalidDir.FullName 'PatchReport_invalid.json') -Value $invalidReports[$name] -Encoding UTF8
    }
    # Legacy reports may omit newer optional metrics and provider metadata.
    $legacyDir = New-Item -ItemType Directory -Path (Join-Path $fleetEdgeRoot 'Legacy[1]') -Force
    $legacyPath = Join-Path $legacyDir.FullName 'PatchReport_legacy.json'
    Set-Content -LiteralPath $legacyPath -Value '{"Metadata":{"Hostname":"Legacy[1]"},"Statistics":{"UpdatesApplied":1,"UpdatesFailed":0,"UpdatesSkipped":0}}' -Encoding UTF8
    [IO.File]::SetLastWriteTime($legacyPath, (Get-Date).AddDays(-7).AddMinutes(-10))

    & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $fleetEdgeRoot -OutputPath $fleetEdgeOutput -StaleDays 7
    $edgeCsvPath = Get-ChildItem $fleetEdgeOutput -Filter 'FleetReport_*.csv' | Select-Object -First 1
    $edgeHtmlPath = Get-ChildItem $fleetEdgeOutput -Filter 'FleetReport_*.html' | Select-Object -First 1
    $edgeRows = @(Import-Csv $edgeCsvPath.FullName)
    $brokenRow = $edgeRows | Where-Object Hostname -eq 'BrokenHost' | Select-Object -First 1
    $emptyRow = $edgeRows | Where-Object Hostname -eq 'EmptyHost' | Select-Object -First 1
    Assert-True ($edgeRows.Count -eq (3 + $invalidReports.Count)) 'Fleet edge integration: every host must remain visible despite invalid reports.'
    Assert-True ($brokenRow.Note -match '^Could not parse') 'Fleet edge integration: malformed JSON should produce a specific recovery note.'
    Assert-True ($emptyRow.Note -eq 'Folder exists but contains no JSON reports.') 'Fleet edge integration: an empty host folder should produce the explicit no-report note.'
    foreach ($name in $invalidReports.Keys) {
        $invalidRow = $edgeRows | Where-Object Hostname -eq $name
        Assert-True ($invalidRow.Note -match '^Could not parse') "Fleet edge integration: $name must report invalid evidence."
        Assert-True ($invalidRow.ProvidersExecuted -eq 'False' -and $invalidRow.Stale -eq 'True') "Fleet edge integration: $name must never be treated as healthy."
        Assert-True ($invalidRow.Failed -eq '') "Fleet edge integration: $name must preserve unknown counts rather than invent zero failures."
    }
    $legacyRow = $edgeRows | Where-Object Hostname -eq 'Legacy[1]'
    Assert-True ($legacyRow.Applied -eq '1' -and $legacyRow.Note -eq '') 'Fleet edge integration: literal host paths and legacy reports must remain readable.'
    Assert-True ($legacyRow.Stale -eq 'True' -and [double]$legacyRow.ReportAgeDays -eq 7) 'Fleet edge integration: stale classification must use elapsed time before display rounding.'
    $edgeHtml = Get-Content $edgeHtmlPath.FullName -Raw
    foreach ($name in @('BrokenHost', 'EmptyHost') + @($invalidReports.Keys)) {
        $hostRowHtml = [regex]::Match($edgeHtml, "(?s)<tr class='fleet-row [^>]*data-host='$([regex]::Escape($name))'.*?</tr>").Value
        Assert-True ($hostRowHtml -match 'Evidence unavailable' -and $hostRowHtml -match 'Not assessed') "Fleet UI: $name should explain missing evidence."
        Assert-True ($hostRowHtml -notmatch "signal clear") "Fleet UI: $name must not show a reassuring clear status."
        Assert-True ($hostRowHtml -match 'collect a valid report') "Fleet UI: $name should offer a recovery step."
    }
    Assert-True ($edgeHtml -match "class='host-link' href='file:///") 'Fleet edge integration: an existing sibling HTML report should use a safe absolute file URI even when JSON is malformed.'
    Assert-True ($edgeHtml -match "<strong>EmptyHost</strong><span class='cell-detail'>HTML report unavailable") 'Fleet edge integration: missing HTML should render plain text rather than a broken link.'
} finally {
    Remove-Item $fleetEdgeRoot -Recurse -Force -EA SilentlyContinue
    Remove-Item $fleetEdgeOutput -Recurse -Force -EA SilentlyContinue
}

$emptyFleetRoot = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-empty-$([guid]::NewGuid())"
$emptyFleetOutput = Join-Path ([System.IO.Path]::GetTempPath()) "pm-fleet-empty-output-$([guid]::NewGuid())"
try {
    [void](New-Item -ItemType Directory -Path $emptyFleetRoot -Force)
    $emptyFleetThrew = $false
    try {
        & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $emptyFleetRoot -OutputPath $emptyFleetOutput
    } catch {
        $emptyFleetThrew = $_.Exception.Message -match 'No host report folders found'
    }
    Assert-True $emptyFleetThrew 'Fleet edge integration: an empty estate should fail with a specific configuration recovery message.'
} finally {
    Remove-Item $emptyFleetRoot -Recurse -Force -EA SilentlyContinue
    Remove-Item $emptyFleetOutput -Recurse -Force -EA SilentlyContinue
}

#-- Public file hygiene ---------------------------------------------------------------
$publicFiles = @(
    'Invoke-PatchManager.ps1'
    'Get-FleetReport.ps1'
    'PatchManager.config.example.json'
    'PatchManager.config.schema.json'
    'README.md'
    'CHANGELOG.md'
    'docs/CONFIGURATION.md'
    'docs/OPERATIONS.md'
    'docs/brand/BRAND.md'
    'docs/brand/patchmanager-mark.svg'
    'docs/brand/patchmanager-wordmark.svg'
    'docs/brand/patchmanager-brand-board.svg'
    '.github/SECURITY.md'
    '.github/CODE_OF_CONDUCT.md'
    '.github/CONTRIBUTING.md'
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

$fleetPath = Join-Path $root 'Get-FleetReport.ps1'
$fleetScript = Get-Content -Path $fleetPath -Raw
$fleetTokens = $null
$fleetErrors = $null
$fleetAst = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $fleetPath), [ref]$fleetTokens, [ref]$fleetErrors)
Assert-True ($fleetErrors.Count -eq 0) "Fleet report parser errors: $($fleetErrors | Out-String)"
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $fleetAst -Name 'Get-FleetRiskRank')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $fleetAst -Name 'Get-FleetPosture')
function New-FleetRiskTestRow {
    param([int]$Kev = 0, [int]$InventoryKev = 0, [int]$NvdCritical = 0, [int]$NvdHigh = 0, [int]$Sla = 0, [int]$Failed = 0, [int]$Errors = 0, [bool]$ProvidersExecuted = $true, [bool]$Stale = $false, [int]$Eol = 0, [int]$Staleness = 0, [int]$Reboot = 0)
    [pscustomobject]@{ KEVMatches=$Kev; InventoryKEV=$InventoryKev; NvdCritical=$NvdCritical; NvdHigh=$NvdHigh; SLABreaches=$Sla; Failed=$Failed; Errors=$Errors; ProvidersExecuted=$ProvidersExecuted; Stale=$Stale; EolExposure=$Eol; StalenessReview=$Staleness; RebootRequired=$Reboot }
}
foreach ($row in @((New-FleetRiskTestRow -Kev 1),(New-FleetRiskTestRow -InventoryKev 1),(New-FleetRiskTestRow -NvdCritical 1),(New-FleetRiskTestRow -Sla 1))) {
    Assert-True ((Get-FleetRiskRank $row) -eq 1) 'KEV, inventory KEV, NVD Critical, and SLA exposure must rank first.'
}
foreach ($row in @((New-FleetRiskTestRow -Failed 1),(New-FleetRiskTestRow -Errors 1),(New-FleetRiskTestRow -ProvidersExecuted $false))) {
    Assert-True ((Get-FleetRiskRank $row) -eq 2) 'Failures, script errors, and deferred provider execution must rank second.'
}
foreach ($row in @((New-FleetRiskTestRow -Stale $true),(New-FleetRiskTestRow -Eol 1),(New-FleetRiskTestRow -NvdHigh 1),(New-FleetRiskTestRow -Staleness 1),(New-FleetRiskTestRow -Reboot 1))) {
    Assert-True ((Get-FleetRiskRank $row) -eq 3) 'Stale, EOL, NVD High, staleness, and reboot signals must rank third.'
}
Assert-True ((Get-FleetRiskRank (New-FleetRiskTestRow)) -eq 4) 'Healthy hosts must rank last.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -Failed 1)) -eq 'attention') 'Confirmed fleet failures should use the red attention posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -Eol 1)) -eq 'attention') 'Confirmed EOL exposure should use the red attention posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -Reboot 1)) -eq 'review') 'Reboot-only fleet evidence should use the amber review posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -NvdHigh 1)) -eq 'review') 'NVD-high-only fleet evidence should use the amber review posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -Staleness 1)) -eq 'review') 'Staleness findings should use the amber review posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow -Stale $true)) -eq 'stale') 'Old reports should retain the explicit stale posture.'
Assert-True ((Get-FleetPosture (New-FleetRiskTestRow)) -eq 'healthy') 'Clear fleet rows should retain the healthy posture.'
Assert-True ($fleetScript -match 'class="fleet-nav') 'Fleet report should include the compact fleet evidence header.'
Assert-True ($fleetScript -match 'class="fleet-run-identity nav-run-identity"') 'Fleet run identity should sit in the compact evidence header.'
Assert-True ($fleetScript -match 'class="fleet-toolbar ledger-toolbar"') 'Fleet search and filters should sit beside the host ledger they control.'
Assert-True ($fleetScript -notmatch 'class="nav-links"') 'Fleet report should avoid pill-style anchor navigation in the evidence header.'
Assert-True ($fleetScript -match 'class="fleet-verdict') 'Fleet report should include the compact estate verdict rail.'
Assert-True ($fleetScript -match 'class="panel fleet-health-map"') 'Fleet report should include the connected estate health map.'
Assert-True ($fleetScript -match 'class="fleet-lanes" aria-label="Filter hosts by risk"') 'Fleet report should retain functional risk lanes inside the health map.'
Assert-True ($fleetScript -match 'class="estate-root') 'Fleet health map should expose a connected estate root node.'
Assert-True ($fleetScript -match 'Open prioritized host queue') 'Fleet verdict should expose one clear primary action.'
Assert-True ($fleetScript -match 'seed a79596f6') 'Fleet report should preserve the selected Impeccable direction contract in emitted HTML.'
Assert-True ($fleetScript -like '*#fleetTable td:nth-child(8):before*') 'Fleet host rows should become labelled evidence cards on narrow screens.'
Assert-True ($fleetScript -match '@media\(max-width:820px\).*?#fleetTable\{min-width:0\}') 'Fleet host rows should reflow at tablet width instead of hiding columns in horizontal scroll.'
Assert-True ($fleetScript -match '@media\(max-width:820px\).*?\.primary-action\{min-height:44px\}') 'Fleet compact cascade should restore a 44px primary action at tablet width.'
Assert-True ($fleetScript -match '@media\(pointer:coarse\)\{[^}]*min-height:44px') 'Fleet report should preserve 44px controls for coarse pointers.'
Assert-True ($fleetScript -match 'class="fleet-evidence') 'Fleet report should preserve evidence provenance after the host queue.'
Assert-True ($fleetScript -match 'class="brand-mark"') 'Fleet report should include the inline PatchManager brand mark.'
Assert-True ($fleetScript -match '#c49a3d') 'Fleet report brand mark should include the amber ledger curve.'
Assert-True ($fleetScript -match 'Patch\. Verify\. Prove it\.') 'Fleet report should include the PatchManager brand tagline.'
Assert-True ($fleetScript -match '--charcoal:#111513') 'Fleet report should use the Charcoal Ink brand token.'
Assert-True ($fleetScript -match '--paper:#f6f2e8') 'Fleet report should use the Ivory Paper brand token.'
Assert-True ($fleetScript -match '--blue:#18324a') 'Fleet report should use the Audit Blue brand token.'
Assert-True ($fleetScript -match '--green:#24744f') 'Fleet report should use the Verified Green brand token.'
Assert-True ($fleetScript -match '--red:#a53b35') 'Fleet report should use the Exposure Red brand token.'
Assert-True ($fleetScript -match '--amber:#955d20') 'Fleet report should use the accessible Caution Amber ink token.'
Assert-True ($fleetScript -match '--amber-curve:#c49a3d') 'Fleet report should use the Caution Amber ledger token.'
Assert-True ((Get-ContrastRatio '#955d20' '#faf0d8') -ge 4.5) 'Fleet Caution Amber text on its soft background must meet WCAG AA contrast.'
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
Assert-True ($fleetScript -match 'ProvidersExecuted') 'Fleet report must distinguish terminal deferrals from completed provider runs.'
Assert-True ($fleetScript -match 'data-sort="host"') 'Fleet report host table should keep sortable host columns.'
Assert-True ($fleetScript -match 'Host / priority') 'Fleet report should use the reduced triage-oriented host table.'
Assert-True ($fleetScript -match 'All metrics') 'Secondary fleet metrics should move into expandable per-host details.'
Assert-True ($fleetScript -match 'data-risk-filter="security"') 'Fleet risk lanes should be functional security predicates.'
Assert-True ($fleetScript -match 'data-risk-filter="failure"') 'Fleet risk lanes should expose execution failure predicates.'
Assert-True ($fleetScript.Contains('class="lane $securityTone" data-risk-filter="security"')) 'Fleet security lane tone should derive from its actual predicate count.'
Assert-True ($fleetScript.Contains('class="lane $executionTone" data-risk-filter="failure"')) 'Fleet execution lane tone should derive from failed, errored, or deferred hosts.'
Assert-True ($fleetScript.Contains('class="lane $currencyTone" data-risk-filter="stale"')) 'Fleet currency lane tone should derive from stale evidence.'
Assert-True ($fleetScript.Contains('class="lane $lifecycleTone" data-risk-filter="eol"')) 'Fleet lifecycle lane tone should derive from end-of-life exposure.'
Assert-True ($fleetScript.Contains('class="lane $completionTone" data-risk-filter="reboot"')) 'Fleet completion lane tone should derive from reboot-required hosts.'
Assert-True ($fleetScript -match '\$_.Stale -or \$_.StalenessReview -gt 0') 'The stale-evidence lane should include both old reports and staleness findings.'
Assert-True ($fleetScript -match 'NvdHigh -gt 0 -or \$_.SLABreaches -gt 0\) \{ \$riskTokens.Add\(''security''\) \}') 'NVD High must participate in the fleet security filter predicate.'
Assert-True ($fleetScript -match "signal attention.*NVD high") 'NVD High must be visible as an amber fleet signal.'
Assert-True ($fleetScript -match 'aria-pressed="false"') 'Fleet risk lanes should expose toggle state.'
Assert-True ($fleetScript -match "riskFilter=''") 'Clearing fleet filters should also clear the active risk lane.'
Assert-True ($fleetScript -match "setAttribute\('aria-sort'") 'Sortable fleet headers should update aria-sort.'
Assert-True ($fleetScript -match 'role="status" aria-live="polite"') 'Fleet filtering should announce visible result counts.'
Assert-True ($fleetScript -match 'ChangeExtension\(\$latestJson.FullName, ''.html''\)') 'Fleet report links should target the matching HTML beside the selected JSON.'
Assert-True ($fleetScript -match '\.AbsoluteUri') 'Fleet report links should use safe absolute file URIs.'
Assert-True ($fleetScript -match 'HTML report unavailable') 'Fleet hostnames should fall back to plain text when HTML is unavailable.'
Assert-True ($fleetScript -match 'Export-Csv -Path \$csvPath -NoTypeInformation') 'The fleet CSV export path and columns should remain sourced from the unchanged host rows.'
Assert-True ($fleetScript -match 'https://github.com/ciaranwhiteside/PatchManager') 'Fleet report footer should link to the PatchManager repository.'
Assert-True ($fleetScript -match '<noscript><style>\.reveal\{opacity:1') 'Fleet report must stay readable when JavaScript is disabled.'
Assert-True ($fleetScript -match 'details>:not\(summary\)\{display:') 'Fleet report detail evidence must remain visible for print and no-JavaScript output.'
Assert-True ($fleetScript -match 'forced-colors:active') 'Fleet report should support Windows High Contrast.'
Assert-True ($fleetScript -match 'prefers-reduced-motion') 'Fleet report should respect reduced-motion preferences.'
Assert-True ($fleetScript -match 'viewport-fit=cover') 'Fleet reports should account for mobile safe areas.'
Assert-True ($fleetScript -match 'height:44px') 'Fleet inputs should meet the 44px touch-target floor.'
Assert-True ($fleetScript -match 'min-height:44px') 'Fleet buttons should meet the 44px touch-target floor.'
Assert-True ($fleetScript -match 'input,select,button\{font-size:16px\}') 'Fleet mobile form controls should remain readable without browser text zoom.'
Assert-True ($fleetScript -match '\.hero-panel\{min-width:0;') 'Fleet hero evidence should shrink within narrow viewports.'
Assert-True ($fleetScript -match '\.fleet-nav>\*\{min-width:0\}') 'Fleet mobile navigation children should not force page-level horizontal overflow.'
Assert-True ($fleetScript -notmatch 'cdnjs|unpkg|fonts\.googleapis|picsum|gsap') 'Fleet report should stay offline with no CDN, remote font, image, or GSAP dependency.'
Assert-True ($fleetScript -notmatch 'hero-visual|telemetry-strip|pulseBars') 'Fleet report should not include decorative animated hero telemetry.'
Assert-True ($fleetScript -notmatch '\.hero:before') 'Fleet report hero should not include decorative pseudo-art.'

if (-not [string]::IsNullOrWhiteSpace($VisualArtifactPath)) {
    [void](New-Item -ItemType Directory -Path $VisualArtifactPath -Force)

    $script:HOSTNAME = 'DEMO-WORKSTATION'
    $script:RING = 'Pilot'
    $script:VERSION = '1.7.1'
    $script:STARTTIME = (Get-Date).AddMinutes(-7)
    $script:EmergencyPatch = $false
    $script:CFG = [pscustomobject]@{ SLA = [pscustomobject]@{ Enabled = $false; Critical = 14 } }
    $DryRun = [System.Management.Automation.SwitchParameter]::new($false)
    $script:Stats.Errors = [System.Collections.Generic.List[string]]::new()
    $visualRows = @(
        (New-PatchResult -Name '7-Zip' -PackageId '7zip.7zip' -Source 'winget' -Provider 'winget' -InstalledVersion '24.08' -AvailableVersion '24.09' -ConfirmedVersion '24.09' -Status 'Updated' -Success $true -Evidence 'Installed version confirmed after WinGet completed.')
        (New-PatchResult -Name 'Affinity' -PackageId 'Canva.Affinity' -Source 'winget' -Provider 'winget' -InstalledVersion '3.2.2' -AvailableVersion '3.2.3' -Status 'Failed' -Success $false -Evidence 'Installer returned a confirmed failure. Retry from an elevated terminal.')
        (New-PatchResult -Name 'Microsoft 365 Apps' -PackageId 'Microsoft.Office.ClickToRun' -Source 'office-c2r' -Provider 'microsoft-365' -InstalledVersion '16.0.19127.20264' -AvailableVersion '16.0.19127.20310' -Status 'Verifying' -Success $false -Evidence 'Click-to-Run is still applying; confirm on the next run.')
        (New-PatchResult -Name 'Windows cumulative update' -PackageId 'Windows.Update.KB5070001' -Source 'windows-update' -Provider 'windows-update' -InstalledVersion 'KB5069999' -AvailableVersion 'KB5070001' -ConfirmedVersion 'KB5070001' -Status 'Succeeded' -Success $true -RebootRequired $true -Evidence 'Installation completed; restart is required to finish servicing.')
        (New-PatchResult -Name 'WinGet source: winget' -PackageId 'WinGet.Source.winget' -Source 'winget' -Provider 'winget-discovery' -Status 'Completed' -Success $true -Evidence 'Source health and discovery completed.')
        (New-PatchResult -Name 'Managed browser' -PackageId 'Example.ManagedBrowser' -Source 'winget' -Provider 'winget' -Status 'Descoped' -Success $false -Evidence 'Managed by the selected commercial provider profile.')
    )
    Update-StatsFromResults -Results $visualRows
    $visualInventoryKev = @(
        [pscustomobject]@{ InstalledApp='Microsoft Edge Game Assist'; ExposureState='Unknown'; CVE='CVE-2016-7201'; InstalledVer='1.0'; FixedVersion=''; ExposureDetail='NVD range unavailable; verify the installed build manually.'; Description='Product-name match requires version evidence.'; CISADueDate='2016-12-01' }
    )
    $visualStaleness = @(
        [pscustomobject]@{ Category='Antivirus definitions'; Item='Microsoft Defender'; Severity='review'; Detail='Security intelligence is 9 days old.'; Recommendation='Run Update-MpSignature.' }
    )
    $visualEol = @(
        [pscustomobject]@{ Item='Node.js'; InstalledVersion='18.20.4'; Cycle='18'; Status='EOL'; Severity='review'; EolDate='2025-04-30'; LatestSupported='22.18.0'; Detail='Move to a supported LTS release.' }
    )
    $visualHtml = New-HTMLReport -Results $visualRows -KEVMatches @() -SLABreaches @() -Elapsed 7.2 -Metrics ([pscustomobject]@{ AvgDaysToApply='2.4'; TotalTracked=0; Applied=0; Pending=0 }) -InventoryKEVMatches $visualInventoryKev -StalenessFindings $visualStaleness -EndOfLifeFindings $visualEol
    $visualDevicePath = Join-Path $VisualArtifactPath 'DeviceReport.html'
    Set-Content -Path $visualDevicePath -Value $visualHtml -Encoding UTF8

    $visualCentral = Join-Path $VisualArtifactPath 'FleetCentral'
    $visualFleetOutput = Join-Path $VisualArtifactPath 'FleetOutput'
    [void](New-Item -ItemType Directory -Path $visualCentral -Force)
    $fleetSamples = @(
        [pscustomobject]@{ Host='SECURITY-HOST'; Applied=2; Failed=0; Providers=$true; Kev=1; InventoryKev='Affected'; NvdCritical=1; Eol=$false; Staleness=$false; Reboot=$false; Note='' },
        [pscustomobject]@{ Host='FAILED-HOST'; Applied=0; Failed=1; Providers=$true; Kev=0; InventoryKev=''; NvdCritical=0; Eol=$false; Staleness=$false; Reboot=$false; Note='' },
        [pscustomobject]@{ Host='REVIEW-HOST'; Applied=3; Failed=0; Providers=$true; Kev=0; InventoryKev=''; NvdCritical=0; Eol=$false; Staleness=$true; Reboot=$true; Note='' },
        [pscustomobject]@{ Host='HEALTHY-HOST'; Applied=4; Failed=0; Providers=$true; Kev=0; InventoryKev=''; NvdCritical=0; Eol=$false; Staleness=$false; Reboot=$false; Note='' },
        [pscustomobject]@{ Host='DEFERRED-HOST'; Applied=0; Failed=0; Providers=$false; Kev=0; InventoryKev=''; NvdCritical=0; Eol=$false; Staleness=$false; Reboot=$false; Note='Maintenance-window deferral' }
    )
    foreach ($sample in $fleetSamples) {
        $sampleDir = New-Item -ItemType Directory -Path (Join-Path $visualCentral $sample.Host) -Force
        $sampleReport = [ordered]@{
            Metadata = [ordered]@{ Hostname=$sample.Host; Ring='Pilot'; ScopeProfile='Personal'; ScriptVer='1.7.1'; DryRun=$false; ProvidersExecuted=$sample.Providers; RunDisposition=$sample.Note }
            Statistics = [ordered]@{ UpdatesApplied=$sample.Applied; UpdatesFailed=$sample.Failed; UpdatesSkipped=0; KEVMatches=$sample.Kev; SLABreaches=0; NvdCritical=$sample.NvdCritical; NvdHigh=0; Errors=@() }
            RebootRequiredItems = $(if ($sample.Reboot) { @([ordered]@{ Name='Windows cumulative update' }) } else { @() })
            AttentionItems = @()
            InventoryKEVMatches = $(if ($sample.InventoryKev) { @([ordered]@{ ExposureState=$sample.InventoryKev }) } else { @() })
            EndOfLifeFindings = $(if ($sample.Eol) { @([ordered]@{ Severity='review' }) } else { @() })
            StalenessFindings = $(if ($sample.Staleness) { @([ordered]@{ Severity='review' }) } else { @() })
        }
        $sampleJson = Join-Path $sampleDir.FullName "PatchReport_$($sample.Host)_20260827_120000_000.json"
        $sampleReport | ConvertTo-Json -Depth 8 | Set-Content -Path $sampleJson -Encoding UTF8
        Set-Content -Path ([System.IO.Path]::ChangeExtension($sampleJson, '.html')) -Value "<!DOCTYPE html><title>$($sample.Host) report</title>" -Encoding UTF8
    }
    & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $visualCentral -OutputPath $visualFleetOutput -StaleDays 7
    Write-Host "Visual artifacts: $VisualArtifactPath" -ForegroundColor Cyan
}

# --- Audit 2026-11 regression tests -----------------------------------------------

function Protect-TestPath {
    # Leave only the current account on a temp path, so Test-TrustedPath sees it as admin-owned.
    param([string]$Path)
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRule($rule) }
    $inherit = if (Test-Path -LiteralPath $Path -PathType Container) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($me, 'FullControl', $inherit, 'None', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# T1: KEV emergency / SLA breach messages must not force exit 1 (ERROR sets ExitCode).
$kevSlaErrorLogs = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -eq 'Write-Log' -and
    $node.Extent.Text -match '(EMERGENCY:|BREACH:)' -and
    $node.Extent.Text -match '-Level ERROR'
}, $true))
Assert-True ($kevSlaErrorLogs.Count -eq 0) 'KEV emergency and SLA breach logs must be WARN so a clean run does not exit 1.'

# T2: Ring.Delays loaded from JSON is a PSCustomObject; the lookup must not index it.
$jsonDelays = '{"Pilot":0,"Early":3,"Broad":10}' | ConvertFrom-Json
Assert-True ((Get-ObjectPropertyValue $jsonDelays 'Early' 0) -eq 3) 'Ring delay lookup must work on a JSON object.'
Assert-True ($scriptContent -notmatch '\.Ring\.Delays\[') 'Ring.Delays must not be indexed with [] (throws on PSCustomObject under StrictMode).'

# T3: a schema-minimal ExtraCatalogue entry (no UpdaterArgs / VersionRegistryPaths) must not throw.
foreach ($fn in 'Invoke-VendorUpdaterProvider','Resolve-FirstExistingPath','Get-InstalledFileVersion','Get-RegistryVersion') {
    Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn)
}
& {
    Set-StrictMode -Version Latest
    function Get-VendorUpdaterCatalogue { ,@('{"Name":"X","PackageId":"X.X","Provider":"x","UpdaterPathCandidates":["' + ("$env:SystemRoot\System32\where.exe" -replace '\\','\\') + '"]}' | ConvertFrom-Json) }
    function Test-IsDescoped { param($Item, [ref]$Reason) $false }
    $script:CFG = [pscustomobject]@{ VendorUpdaters = [pscustomobject]@{ Enabled = $true } }
    $DryRun = $true
    $vendorRows = @(Invoke-VendorUpdaterProvider)
    Assert-True ($vendorRows.Count -eq 1 -and $vendorRows[0].Status -eq 'Planned') 'Minimal ExtraCatalogue entry should plan, not throw.'
}

# T4: every report Set-Content in New-ComplianceReport must sit inside a try, so a full disk is not FATAL 99.
$complianceAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-ComplianceReport' }, $true)
$reportWrites = @($complianceAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Set-Content','Export-Csv' }, $true))
Assert-True ($reportWrites.Count -ge 2) 'Expected report writes in New-ComplianceReport.'
foreach ($write in $reportWrites) {
    $p = $write.Parent; $inTry = $false
    while ($p -and $p -ne $complianceAst) { if ($p -is [System.Management.Automation.Language.TryStatementAst]) { $inTry = $true; break }; $p = $p.Parent }
    Assert-True $inTry "Report write at line $($write.Extent.StartLineNumber) must be inside try/catch."
}

# T5: a truncated KEV cache must not throw; an HTML (proxy) response must not be cached.
foreach ($fn in 'Get-CISAKEVData','Test-TrustedPath') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Set-ContentAtomic')
$kevCacheDir = Join-Path ([IO.Path]::GetTempPath()) "pm-kev-$([guid]::NewGuid())"
[void](New-Item -ItemType Directory -Path $kevCacheDir)
Protect-TestPath $kevCacheDir
try {
    & {
        Set-StrictMode -Version Latest
        $script:CFG = [pscustomobject]@{ CISAKEV = [pscustomobject]@{ Enabled = $true; CachePath = $kevCacheDir; CacheHours = 24; FeedUrl = 'https://example.invalid/kev.json' } }
        Set-Content -Path (Join-Path $kevCacheDir 'cisa_kev.json') -Value '{"vulnerabilities":[{"cveID":"CVE-1' -Encoding UTF8
        function Invoke-RestMethod { throw 'offline' }
        Assert-True ($null -eq (Get-CISAKEVData)) 'Truncated KEV cache with no network should return null, not throw.'
        function Invoke-RestMethod { '<html>captive portal</html>' }
        Assert-True ($null -eq (Get-CISAKEVData)) 'HTML response should be rejected.'
        Assert-True ((Get-Content (Join-Path $kevCacheDir 'cisa_kev.json') -Raw) -notmatch 'captive') 'HTML response must not be cached.'
        function Invoke-RestMethod { [pscustomobject]@{ vulnerabilities = @([pscustomobject]@{ cveID = 'CVE-2024-0001' }) } }
        $fresh = Get-CISAKEVData
        Assert-True (@($fresh.vulnerabilities).Count -eq 1) 'Valid feed should be returned.'
        $cachedKev = Get-Content (Join-Path $kevCacheDir 'cisa_kev.json') -Raw | ConvertFrom-Json
        Assert-True ($cachedKev.vulnerabilities[0].cveID -eq 'CVE-2024-0001') 'Valid feed should be cached.'
    }
} finally { Remove-Item $kevCacheDir -Recurse -Force -EA SilentlyContinue }

# T6: a corrupt state file is preserved as .corrupt-* before a fresh state is returned.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-PatchState')
$stateDir = Join-Path ([IO.Path]::GetTempPath()) "pm-state-$([guid]::NewGuid())"
[void](New-Item -ItemType Directory -Path $stateDir)
try {
    $script:CFG = [pscustomobject]@{ State = [pscustomobject]@{ StatePath = $stateDir; StateFile = 'state.json' } }
    Set-Content -Path (Join-Path $stateDir 'state.json') -Value '{"TrackedUpdates":[{"Pack' -Encoding UTF8
    $freshState = Get-PatchState
    Assert-True (@($freshState.TrackedUpdates).Count -eq 0) 'Corrupt state should yield a fresh state.'
    Assert-True (@(Get-ChildItem $stateDir -Filter 'state.json.corrupt-*').Count -eq 1) 'Corrupt state file should be preserved.'
} finally { Remove-Item $stateDir -Recurse -Force -EA SilentlyContinue }

# T7: files a standard user can write are not trusted by an elevated run.
$trustFile = Join-Path ([IO.Path]::GetTempPath()) "pm-trust-$([guid]::NewGuid()).json"
Set-Content -Path $trustFile -Value '{}' -Encoding UTF8
try {
    Protect-TestPath $trustFile
    Assert-True (Test-TrustedPath $trustFile) 'A file owned and writable only by the running account should be trusted.'
    & icacls.exe $trustFile /grant '*S-1-5-32-545:(W)' | Out-Null
    Assert-True (-not (Test-TrustedPath $trustFile)) 'A file BUILTIN\Users can write must not be trusted.'
    Assert-True (-not (Test-TrustedPath (Join-Path $trustFile 'missing'))) 'An unreadable path must not be trusted.'
} finally { Remove-Item $trustFile -Force -EA SilentlyContinue }

# T8: fleet profiles refuse executables in user-writable folders; Personal keeps per-user tools.
$script:CFG = [pscustomobject]@{ ScopeProfile = 'Commercial' }
Assert-True (Test-SafeExecutablePath "$env:SystemRoot\System32\cmd.exe") 'System32 binaries are safe.'
Assert-True (-not (Test-SafeExecutablePath (Join-Path $env:LOCALAPPDATA 'Google\Update\GoogleUpdate.exe'))) 'Per-user updater must be refused in fleet profiles.'
Assert-True (-not (Test-SafeExecutablePath (Join-Path $env:USERPROFILE 'scoop\shims\scoop.cmd'))) 'Scoop shim must be refused in fleet profiles.'
$refused = Invoke-CapturedProcess -FilePath (Join-Path $env:USERPROFILE 'evil.exe') -TimeoutSeconds 5
Assert-True ($null -eq $refused.ExitCode -and $refused.Output -match '^Refused') 'Invoke-CapturedProcess must refuse user-writable executables in fleet profiles.'
$script:CFG = [pscustomobject]@{ ScopeProfile = 'Personal' }
Assert-True (Test-SafeExecutablePath (Join-Path $env:LOCALAPPDATA 'Google\Update\GoogleUpdate.exe')) 'Personal profile keeps per-user tools.'

# T9: fleet identity comes from the share folder, not host-written JSON.
$spoofRoot = Join-Path ([IO.Path]::GetTempPath()) "pm-fleet-spoof-$([guid]::NewGuid())"
$spoofOut = "$spoofRoot-out"
$fixtureJson = Get-Content (Get-ChildItem (Join-Path $PSScriptRoot 'Fixtures\FleetCentral\TEST-HOST') -Filter '*.json' | Select-Object -First 1).FullName -Raw
try {
    foreach ($spoofHost in 'DC01','EVIL') {
        $dir = New-Item -ItemType Directory -Path (Join-Path $spoofRoot $spoofHost) -Force
        $json = Join-Path $dir.FullName "PatchReport_${spoofHost}_20260101_000000_000.json"
        Set-Content -Path $json -Value ($fixtureJson -replace '"TEST-HOST"', '"DC01"') -Encoding UTF8
        Set-Content -Path ([IO.Path]::ChangeExtension($json, '.html')) -Value "<title>$spoofHost</title>" -Encoding UTF8
    }
    & (Join-Path $root 'Get-FleetReport.ps1') -CentralReportPath $spoofRoot -OutputPath $spoofOut -StaleDays 9999 | Out-Null
    $spoofRows = @(Import-Csv (Get-ChildItem $spoofOut -Filter 'FleetReport_*.csv' | Select-Object -First 1).FullName)
    Assert-True ((@($spoofRows.Hostname) -join ',') -eq 'DC01,EVIL') 'Fleet: each share folder must produce its own row.'
    Assert-True (($spoofRows | Where-Object Hostname -eq 'EVIL').Note -match "claims hostname 'DC01'") 'Fleet: a hostname mismatch must be noted.'
    $spoofHtml = Get-Content (Get-ChildItem $spoofOut -Filter 'FleetReport_*.html' | Select-Object -First 1).FullName -Raw
    Assert-True ($spoofHtml -match '/EVIL/PatchReport_EVIL_' -and $spoofHtml -match '/DC01/PatchReport_DC01_') 'Fleet: each row must link to its own folder''s report.'
} finally { Remove-Item $spoofRoot, $spoofOut -Recurse -Force -EA SilentlyContinue }

# T10: CSV exports neutralise spreadsheet formulas from untrusted text.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'ConvertTo-SafeCsvRow')
$safeRow = [pscustomobject]@{ Name = '=HYPERLINK("http://x")'; Ver = '+1'; Count = -3; Plain = 'Chrome' } | ConvertTo-SafeCsvRow
Assert-True ($safeRow.Name -eq '''=HYPERLINK("http://x")' -and $safeRow.Ver -eq '''+1') 'Formula-like text must be prefixed with a quote.'
Assert-True ($safeRow.Count -eq -3 -and $safeRow.Plain -eq 'Chrome') 'Numbers and plain text must be unchanged.'
Assert-True (($scriptContent -split 'Export-Csv').Count -eq ($scriptContent -split 'ConvertTo-SafeCsvRow \| Export-Csv').Count) 'Every device CSV export must pass through ConvertTo-SafeCsvRow.'
Assert-True ((Get-Content (Join-Path $root 'Get-FleetReport.ps1') -Raw) -match 'ConvertTo-SafeCsvRow \| Export-Csv') 'Fleet CSV export must pass through ConvertTo-SafeCsvRow.'

# T11: whole-word match works next to '.'/'+', and Chromium KEV entries reach Google Chrome.
Assert-True (Test-WordMatch 'Microsoft .NET Framework 4.8' '.NET Framework') '.NET Framework must match.'
Assert-True (Test-WordMatch 'Microsoft Visual C++ 2015 Redistributable' 'Visual C++') 'Visual C++ must match.'
Assert-True (-not (Test-WordMatch 'Snapple' 'Apple')) 'Whole-word matching must still reject substrings.'
$chromiumKev = [pscustomobject]@{ vulnerabilities = @([pscustomobject]@{ cveID = 'CVE-2025-0001'; vendorProject = 'Google'; product = 'Chromium V8'; vulnerabilityName = 'V8 type confusion'; dateAdded = '2025-01-01'; dueDate = '2025-01-22' }) }
$chromePkg = [pscustomobject]@{ Name = 'Google Chrome'; PackageId = 'Google.Chrome'; Version = '120.0.1'; Source = 'winget' }
$chromiumHits = @(Find-KEVCandidates -Packages @($chromePkg) -KEVData $chromiumKev)
Assert-True ($chromiumHits.Count -eq 1 -and $chromiumHits[0].Product -eq 'Chrome') 'A Chromium KEV entry must become a Google Chrome candidate.'

# T12: an OS CPE (chrome_os) must not align with desktop Chrome; app qualifiers still do.
Assert-True (-not (Test-CpeProductAlignment (ConvertFrom-CpeCriteria 'cpe:2.3:o:google:chrome_os:*:*:*:*:*:*:*:*') 'Google' 'Chrome')) 'A ChromeOS CPE must not align with a Chrome KEV entry.'
Assert-True (Test-CpeProductAlignment (ConvertFrom-CpeCriteria 'cpe:2.3:a:microsoft:edge_chromium:*:*:*:*:*:*:*:*') 'Microsoft' 'Edge') 'Application qualifiers (edge_chromium) still align.'

# T13: a failed NVD fetch is retried once and never memoised.
foreach ($fn in 'Invoke-NVDPacedRequest','Get-NVDCpeMatches') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
& {
    $nvdCfg = [pscustomobject]@{ Enabled = $true; RequestDelayMs = 0; CachePath = (Join-Path ([IO.Path]::GetTempPath()) "pm-nvd-$([guid]::NewGuid())"); MaxLookupsPerRun = 5 }
    $script:NVDLastRequest = [datetime]::MinValue
    $script:nvdCalls = 0
    function Get-CachedApiJson { $script:nvdCalls++; if ($script:nvdCalls -eq 1) { $null } else { [pscustomobject]@{ ok = $true } } }
    $nvdReq = Invoke-NVDPacedRequest -NvdCfg $nvdCfg -Endpoint 'cves' -PublicBaseUrl 'https://example.invalid/cves' -Query 'cveId=CVE-1' -CacheKey 'nvd_CVE-1'
    Assert-True ($script:nvdCalls -eq 2 -and $nvdReq.Data.ok) 'A failed NVD fetch should be retried once.'

    $script:CFG = [pscustomobject]@{ NVD = $nvdCfg }
    $script:NVDMemo = @{}; $script:NVDLookupCount = 0
    function Invoke-NVDPacedRequest { [pscustomobject]@{ Data = $null; Fetched = $true } }
    [void](Get-NVDCpeMatches -CveId 'CVE-2')
    Assert-True (-not $script:NVDMemo.ContainsKey('CVE-2')) 'A failed NVD lookup must not be memoised.'
}

# T15: localised winget output (unrecognised header) is a Failed discovery, never "0 upgrades".
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-WinGetUpgrades')
& {
    function Get-WinGetUpgradesViaModule { $null }
    $script:CFG = [pscustomobject]@{ WinGet = [pscustomobject]@{ IncludeMSStore = $false } }
    $script:SourceCheckResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $deLines = Get-Content -Path (Join-Path $PSScriptRoot 'Fixtures\winget-upgrade-de.txt') -Encoding UTF8
    $script:WINGET = { $global:LASTEXITCODE = 0; $deLines }.GetNewClosure()
    $deUpgrades = @(Get-WinGetUpgrades)
    Assert-True ($deUpgrades.Count -eq 0) 'German output parses no rows.'
    Assert-True ($script:SourceCheckResults[0].Status -eq 'Failed') 'Unrecognised winget table must mark discovery Failed so SLA state is kept.'
}

# T16: an empty module result is @(), not $null, so winget.exe is not re-run.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-WinGetUpgradesViaModule')
& {
    function Get-Module { [pscustomobject]@{ Name = 'Microsoft.WinGet.Client' } }
    function Import-Module { }
    function Get-WinGetPackage { }
    $script:CFG = [pscustomobject]@{ WinGet = [pscustomobject]@{ IncludeMSStore = $false } }
    $script:SourceCheckResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $moduleResult = Get-WinGetUpgradesViaModule
    Assert-True ($null -ne $moduleResult -and @($moduleResult).Count -eq 0) 'Empty module discovery must return an empty array, not $null.'
}

# T17: a timeout kills the whole process tree; zero timeouts are rejected.
$script:CFG = $null
$treeRun = Invoke-CapturedProcess -FilePath "$env:SystemRoot\System32\cmd.exe" -Arguments @('/c', 'ping -n 37 127.0.0.37 >nul') -TimeoutSeconds 2
Start-Sleep -Milliseconds 500
$orphans = @(Get-CimInstance Win32_Process -Filter "Name = 'PING.EXE'" | Where-Object { $_.CommandLine -match '127\.0\.0\.37' })
Assert-True ($treeRun.TimedOut -and $orphans.Count -eq 0) 'Timed-out child processes (grandchildren) must be killed too.'
$zeroCfg = New-TestDefaultCfg
$zeroCfg.WinGet.PackageTimeoutSeconds = 0
$zeroThrew = $false
try { Assert-ValidConfiguration -Config $zeroCfg } catch { $zeroThrew = $_.Exception.Message -match 'PackageTimeoutSeconds must be at least 1' }
Assert-True $zeroThrew 'WinGet.PackageTimeoutSeconds = 0 must be rejected.'

# T18: OEM "no updates" exit codes are AlreadyCurrent; a timed-out scan skips apply.
foreach ($fn in 'Invoke-FirmwareProvider','Get-FirmwareCatalogue') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
& {
    $DryRun = $false
    $script:CFG = [pscustomobject]@{ Firmware = [pscustomobject]@{ Enabled = $true } }
    function Get-CimInstance { [pscustomobject]@{ Manufacturer = 'Dell Inc.' } }
    function Test-OnACPower { $true }
    function Resolve-FirstExistingPath { 'C:\fake\dcu-cli.exe' }
    $script:fwCalls = @()
    function Invoke-CapturedProcess { param($FilePath, $Arguments, $TimeoutSeconds) $script:fwCalls += ,$Arguments; [pscustomobject]@{ ExitCode = 500; TimedOut = $false; Output = 'No updates' } }
    $fwRow = @(Invoke-FirmwareProvider)[0]
    Assert-True ($fwRow.Status -eq 'AlreadyCurrent' -and $fwRow.Success -and $script:fwCalls.Count -eq 1) 'Dell exit 500 on scan must be AlreadyCurrent without running apply.'
    $script:fwCalls = @()
    function Invoke-CapturedProcess { param($FilePath, $Arguments, $TimeoutSeconds) $script:fwCalls += ,$Arguments; [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Output = '' } }
    $fwRow = @(Invoke-FirmwareProvider)[0]
    Assert-True ($fwRow.Status -eq 'Failed' -and $script:fwCalls.Count -eq 1) 'A timed-out firmware scan must not be followed by apply.'
}

# T19: restore points use CIM (works on PowerShell 5.1 and 7), not 5.1-only cmdlets.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-PatchRestorePoint')
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-PatchRestorePoint') -notmatch 'Checkpoint-Computer|Enable-ComputerRestore') 'Restore point must not depend on Windows PowerShell-only cmdlets.'
& {
    $DryRun = $false
    $script:CFG = [pscustomobject]@{ SystemRestore = [pscustomobject]@{ Enabled = $true; Description = 'test' } }
    $script:cimCalls = @()
    function Invoke-CimMethod { param($Namespace, $ClassName, $MethodName, $Arguments) $script:cimCalls += $MethodName; [pscustomobject]@{ ReturnValue = 0 } }
    New-PatchRestorePoint
    Assert-True ($script:cimCalls -contains 'CreateRestorePoint') 'New-PatchRestorePoint must call SystemRestore.CreateRestorePoint.'
}

# T20: Store matching ignores empty/short keys and prefers exact names.
foreach ($fn in 'ConvertTo-StoreMatchKey','Test-StoreKeyMatch','Find-StoreSnapshotPackage') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
Assert-True (-not (Test-StoreKeyMatch 'Microsoft.WindowsCalculator_8wekyb3d8bbwe' ([string][char]0x5FAE + [char]0x4FE1))) 'An empty (CJK) key must not match.'
Assert-True (-not (Test-StoreKeyMatch 'Microsoft.Photos_2024.1_x64__8wekyb3d8bbwe' 'X')) 'A 1-character key must not substring-match x64.'
Assert-True (Test-StoreKeyMatch 'Microsoft.WindowsCalculator' 'Windows Calculator') 'A real name still substring-matches.'
$storeSnap = @{
    a = [pscustomobject]@{ Name = 'Microsoft.XboxApp'; PackageFamilyName = 'Microsoft.XboxApp_8wekyb3d8bbwe'; PackageFullName = 'Microsoft.XboxApp_1.0_x64__8wekyb3d8bbwe'; Version = '1.0' }
    b = [pscustomobject]@{ Name = 'X'; PackageFamilyName = 'X_abc'; PackageFullName = 'X_2.0_x64__abc'; Version = '2.0' }
}
Assert-True ((Find-StoreSnapshotPackage -Snapshot $storeSnap -Candidate ([pscustomobject]@{ Name = 'X' })).Version -eq '2.0') 'Exact name match must win over substring matches.'
Assert-True ($scriptContent -notmatch 'Compare-VersionText') 'Compare-VersionText must be replaced by Compare-SoftwareVersion.'

# T21: winget package folder is chosen by numeric version and CPU architecture.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Select-WinGetPackageFolder')
$wingetFolders = @('Microsoft.DesktopAppInstaller_1.9.25200.0_x64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_1.27.460.0_x64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_1.28.1.0_arm64__8wekyb3d8bbwe', 'Microsoft.DesktopAppInstaller_1.27.460.0_neutral_~_8wekyb3d8bbwe') | ForEach-Object { [pscustomobject]@{ Name = $_ } }
$savedArch = $env:PROCESSOR_ARCHITECTURE
try {
    $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    Assert-True ((Select-WinGetPackageFolder -Folders $wingetFolders).Name -like '*_1.27.460.0_x64_*') 'x64 must pick 1.27 over 1.9 (numeric sort).'
    $env:PROCESSOR_ARCHITECTURE = 'ARM64'
    Assert-True ((Select-WinGetPackageFolder -Folders $wingetFolders).Name -like '*_arm64_*') 'ARM64 must pick the arm64 package.'
} finally { $env:PROCESSOR_ARCHITECTURE = $savedArch }

# T22: Chocolatey ConfirmedVersion comes from the installed nuspec, not the requested target.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ChocoInstalledVersion')
$chocoRoot = Join-Path ([IO.Path]::GetTempPath()) "pm-choco-$([guid]::NewGuid())"
try {
    [void](New-Item -ItemType Directory -Path (Join-Path $chocoRoot 'bin'), (Join-Path $chocoRoot 'lib\git') -Force)
    Set-Content -Path (Join-Path $chocoRoot 'lib\git\git.nuspec') -Value '<?xml version="1.0"?><package xmlns="http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd"><metadata><id>git</id><version>2.47.1</version></metadata></package>' -Encoding UTF8
    Assert-True ((Get-ChocoInstalledVersion -ChocoPath (Join-Path $chocoRoot 'bin\choco.exe') -PackageId 'git') -eq '2.47.1') 'Installed choco version must be read from the nuspec.'
    Assert-True ((Get-ChocoInstalledVersion -ChocoPath (Join-Path $chocoRoot 'bin\choco.exe') -PackageId 'missing') -eq '') 'Unknown package must give an empty confirmed version.'
} finally { Remove-Item $chocoRoot -Recurse -Force -EA SilentlyContinue }
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-ChocolateyProvider') -notmatch 'ConfirmedVersion \$pkg\.Available') 'Chocolatey must not claim the target version as confirmed.'

# T23: the lock and BITS throttle are released before any popup; popups time out; skipped attempts show none.
foreach ($popupFn in 'Invoke-Main', 'Complete-EarlyRun') {
    $popupAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $popupFn }, $true)
    $popupCalls = @($popupAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Show-CompletionPopup','Exit-SingleInstance','Restore-BITSThrottle' }, $true))
    $firstPopup = ($popupCalls | Where-Object { $_.GetCommandName() -eq 'Show-CompletionPopup' } | Select-Object -First 1).Extent.StartOffset
    foreach ($release in 'Exit-SingleInstance','Restore-BITSThrottle') {
        $releaseAt = ($popupCalls | Where-Object { $_.GetCommandName() -eq $release } | Select-Object -First 1).Extent.StartOffset
        Assert-True ($null -ne $releaseAt -and $releaseAt -lt $firstPopup) "${popupFn}: $release must run before Show-CompletionPopup."
    }
}
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Show-CompletionPopup') -notmatch '-TimeoutSeconds 0') 'The completion popup must time out.'
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Complete-EarlyRun') -match "\`$Status -ne 'Skipped'") 'Skipped early runs must not show the completion popup.'

# T24: the tail of an overnight window belongs to the night it started.
$Force = [System.Management.Automation.SwitchParameter]::new($false)
$script:CFG = [pscustomobject]@{ MaintenanceWindow = [pscustomobject]@{ Enabled = $true; StartHour = 22; EndHour = 6; AllowedDays = @('Saturday'); JitterMaxMinutes = 0 } }
# 2026-01-10 is a Saturday.
Assert-True (Test-MaintenanceWindow -Now ([datetime]'2026-01-11 02:00')) 'Sunday 02:00 is Saturday night and must be inside.'
Assert-True (-not (Test-MaintenanceWindow -Now ([datetime]'2026-01-10 02:00'))) 'Saturday 02:00 is Friday night and must be outside.'
Assert-True (Test-MaintenanceWindow -Now ([datetime]'2026-01-10 23:00')) 'Saturday 23:00 must be inside.'
$equalCfg = New-TestDefaultCfg
$equalCfg.MaintenanceWindow.StartHour = 3; $equalCfg.MaintenanceWindow.EndHour = 3
$equalThrew = $false
try { Assert-ValidConfiguration -Config $equalCfg } catch { $equalThrew = $_.Exception.Message -match 'must differ' }
Assert-True $equalThrew 'StartHour equal to EndHour must be rejected.'

# T25: exit 3010 uses per-row reboot flags plus Test-PendingReboot; the narrower duplicate is gone.
$mainText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-Main'
Assert-True ($scriptContent -notmatch 'function Test-RebootRequired') 'Test-RebootRequired duplicate must be removed.'
Assert-True ($mainText -match 'rowNeedsReboot' -and $mainText -match 'Test-PendingReboot\)\)\)') 'Exit 3010 must consider row RebootRequired and Test-PendingReboot.'

# T26: two batteries on AC power count as on AC.
$preflightText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-PreFlightChecks'
$batteryLines = ($preflightText -split "`n" | Where-Object { $_ -match '^\s*\$(pct|onAC)\s*=' }) -join "`n"
$battery = @([pscustomobject]@{ BatteryStatus = 2; EstimatedChargeRemaining = 80 }, [pscustomobject]@{ BatteryStatus = 2; EstimatedChargeRemaining = 15 })
Invoke-Expression $batteryLines
Assert-True ($onAC -eq $true -and $pct -eq 15) 'Two charging batteries must read as on AC with the lowest charge.'

# T27: idle detection compiles, measures the console session for SYSTEM, and fails closed.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-UserIdleMinutes')
$idleNow = Get-UserIdleMinutes
Assert-True ($idleNow -is [double] -or $idleNow -is [int] -or $idleNow -is [long]) 'Idle minutes must be a number.'
$consoleIdle = [PatchManagerIdle]::GetConsoleIdleMilliseconds()
Assert-True ($consoleIdle -ge -2) 'Console idle query must return a value without throwing.'
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-UserIdleMinutes') -match 'catch \{\s*return 0') 'An idle-check failure must treat the user as active.'

# T28: a superseding release keeps the SLA clock while the installed version is unchanged.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Save-PatchState')
$slaDir = Join-Path ([IO.Path]::GetTempPath()) "pm-sla-$([guid]::NewGuid())"
[void](New-Item -ItemType Directory -Path $slaDir)
try {
    $script:CFG = [pscustomobject]@{ State = [pscustomobject]@{ StatePath = $slaDir; StateFile = 'state.json' }; SLA = [pscustomobject]@{ Critical = 14 }; Logging = [pscustomobject]@{ RetentionDays = 90 } }
    $script:RING = 'Broad'
    $slaState = [pscustomobject]@{ TrackedUpdates = @() }
    $slaState = Save-PatchState -State $slaState -AvailableUpgrades @([pscustomobject]@{ PackageId = 'Google.Chrome'; Name = 'Chrome'; Version = '129.0'; Available = '130.0' })
    $slaState.TrackedUpdates[0].FirstSeenAvailable = '2026-01-01'; $slaState.TrackedUpdates[0].SLADue = '2026-01-15'
    $slaState = Save-PatchState -State $slaState -AvailableUpgrades @([pscustomobject]@{ PackageId = 'Google.Chrome'; Name = 'Chrome'; Version = '129.0'; Available = '131.0' })
    $row131 = $slaState.TrackedUpdates | Where-Object { $_.VersionAvailable -eq '131.0' }
    Assert-True ($row131.FirstSeenAvailable -eq '2026-01-01' -and $row131.SLADue -eq '2026-01-15') 'A superseding release must keep the original SLA clock.'
    $slaState = Save-PatchState -State $slaState -AvailableUpgrades @([pscustomobject]@{ PackageId = 'Google.Chrome'; Name = 'Chrome'; Version = '131.0'; Available = '132.0' })
    $row132 = $slaState.TrackedUpdates | Where-Object { $_.VersionAvailable -eq '132.0' }
    Assert-True ($row132.FirstSeenAvailable -eq (Get-Date -Format 'yyyy-MM-dd')) 'After the installed version moves, the next release starts a fresh clock.'
} finally { Remove-Item $slaDir -Recurse -Force -EA SilentlyContinue }

# T29: hostname-seeded jitter spreads hosts and separates anagrams.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Start-JitteredDelay')
& {
    $DryRun = $true
    $script:CFG = [pscustomobject]@{ MaintenanceWindow = [pscustomobject]@{ JitterMaxMinutes = 120 } }
    $script:jitterSlots = @{}
    function Write-Log { param($Message, $Level) if ($Message -match 'Jitter delay: (\d+) min') { $script:jitterSlots[$script:HOSTNAME] = [int]$Matches[1] } }
    foreach ($n in 1..300) { $script:HOSTNAME = 'WS{0:D3}' -f $n; $script:jitterSlots[$script:HOSTNAME] = 0; Start-JitteredDelay -Ring 'Broad' }
    $distinctSlots = @($script:jitterSlots.Values | Sort-Object -Unique).Count
    Assert-True ($distinctSlots -ge 90) "Jitter must spread 300 hosts over many slots (got $distinctSlots)."
    foreach ($n in 'PC-012','PC-021') { $script:HOSTNAME = $n; Start-JitteredDelay -Ring 'Broad' }
    Assert-True ($script:jitterSlots['PC-012'] -ne $script:jitterSlots['PC-021']) 'Anagram hostnames must not share a jitter slot.'
}
$script:HOSTNAME = $env:COMPUTERNAME

# T30: the startup task is an Administrators-group logon task with no dead boot trigger.
$taskText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Install-PatchManagerStartupTask'
Assert-True ($taskText -notmatch '-AtStartup' -and $taskText -notmatch 'AtLogOn -User') 'Task must not use a boot trigger or a single-user logon trigger.'
Assert-True ($taskText -match "-GroupId 'S-1-5-32-544'") 'Task principal must be the Administrators group.'

# T31: AlreadyCurrent rows are not "skipped" work.
$script:Stats = @{ Errors = [System.Collections.Generic.List[string]]::new() }
Update-StatsFromResults -Results @((New-PatchResult -Name 'Windows Update' -PackageId 'WU' -Provider 'windows-update' -Source 'wu' -Status 'AlreadyCurrent' -Success $true))
Assert-True ($script:Stats.UpdatesSkipped -eq 0) 'AlreadyCurrent must not count as skipped.'

# T32: early-run reports and notifications carry the SLA breach count.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Complete-EarlyRun')
& {
    $script:CFG = [pscustomobject]@{ SLA = [pscustomobject]@{ Enabled = $true } }
    $script:Stats = @{ Errors = [System.Collections.Generic.List[string]]::new(); SLABreaches = 0 }
    $script:STARTTIME = Get-Date
    $script:HOSTNAME = 'TEST'
    function Get-PatchState { [pscustomobject]@{ TrackedUpdates = @() } }
    function Get-PatchMetrics { $null }
    function Get-SLABreaches { @([pscustomobject]@{ PackageName = 'A' }, [pscustomobject]@{ PackageName = 'B' }) }
    function New-ComplianceReport { $script:reportSla = $script:Stats.SLABreaches; $null }
    function Copy-LogsToCentral { }
    function Write-RunEvent { }
    function Send-RunNotification { param($ReportInfo, $KEVMatches, $SLABreaches) $script:notifiedSla = @($SLABreaches).Count }
    function Restore-BITSThrottle { }
    function Exit-SingleInstance { }
    function Show-CompletionPopup { }
    Complete-EarlyRun -Name 'Maintenance-window deferral' -Status 'Skipped' -Evidence 'test'
    Assert-True ($script:reportSla -eq 2 -and $script:notifiedSla -eq 2) 'Early runs must report and notify SLA breaches.'
}
$script:HOSTNAME = $env:COMPUTERNAME

# T33: a KEV name candidate that NVD resolved as NotAffected does not trigger an OnlyOnProblems webhook.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Send-RunNotification')
& {
    $script:CFG = [pscustomobject]@{ Notifications = [pscustomobject]@{ Enabled = $true; WebhookUrl = 'https://example.invalid/hook'; OnlyOnProblems = $true; TimeoutSec = 5 } }
    $script:Stats = @{ UpdatesFailed = 0; Errors = [System.Collections.Generic.List[string]]::new(); KEVMatches = 0; SLABreaches = 0; UpdatesApplied = 0; UpdatesSkipped = 0 }
    $script:ExitCode = 0
    $script:posted = $false
    function Invoke-RestMethod { $script:posted = $true }
    Send-RunNotification -ReportInfo $null -KEVMatches @([pscustomobject]@{ CVE = 'CVE-1'; ExposureState = 'NotAffected' }) -SLABreaches @()
    Assert-True (-not $script:posted) 'Unconfirmed KEV candidates must not trigger an OnlyOnProblems notification.'
}

# T34: central log copies prune the host's share folder with the retention window.
foreach ($fn in 'Copy-LogsToCentral','Remove-OldFiles') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
$centralRoot = Join-Path ([IO.Path]::GetTempPath()) "pm-central-$([guid]::NewGuid())"
try {
    $script:HOSTNAME = 'HOST1'
    $hostShare = New-Item -ItemType Directory -Path (Join-Path $centralRoot 'HOST1') -Force
    $oldLog = Join-Path $hostShare.FullName 'PatchManager_20200101.log'
    Set-Content -Path $oldLog -Value 'old'
    (Get-Item $oldLog).LastWriteTime = (Get-Date).AddDays(-400)
    $script:LOGFILE = Join-Path $centralRoot 'PatchManager_today.log'
    Set-Content -Path $script:LOGFILE -Value 'new'
    $script:CFG = [pscustomobject]@{ Logging = [pscustomobject]@{ CentralLogPath = $centralRoot; RetentionDays = 90 } }
    Copy-LogsToCentral
    Assert-True (-not (Test-Path $oldLog) -and (Test-Path (Join-Path $hostShare.FullName 'PatchManager_today.log'))) 'Central log folder must drop files past retention and keep the new copy.'
    Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-ComplianceReport') -match "Remove-OldFiles -Path \`$dest -Filter 'PatchReport_\*'") 'Central report folder must be pruned after the copy.'
} finally { Remove-Item $centralRoot -Recurse -Force -EA SilentlyContinue; $script:HOSTNAME = $env:COMPUTERNAME }

# T35: RetentionDays 0 and a string SLA.Enabled are rejected.
foreach ($badCase in @(
    @{ Set = { param($c) $c.Logging.RetentionDays = 0 }; Expect = 'RetentionDays must be at least 1' },
    @{ Set = { param($c) $c.SLA.Enabled = 'false' }; Expect = 'SLA.Enabled must be true, false, or null' }
)) {
    $badCfg = New-TestDefaultCfg
    & $badCase.Set $badCfg
    $badThrew = $false
    try { Assert-ValidConfiguration -Config $badCfg } catch { $badThrew = $_.Exception.Message -match [regex]::Escape($badCase.Expect) }
    Assert-True $badThrew "Config validation must reject: $($badCase.Expect)."
}

# T36: a pinned-hash mismatch (newer, unapproved release) is a WARN, not a run error.
$selfUpdateText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'Invoke-SelfUpdate'
Assert-True ($selfUpdateText -match 'SHA256 mismatch[^\r\n]*-Level WARN') 'Pinned hash mismatch must log at WARN so the run does not exit 1.'

# T37: self-update refuses a release whose defaults no longer know a key this config sets.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-ConfigKeysUnknownToScript')
$compatDir = Join-Path ([IO.Path]::GetTempPath()) "pm-compat-$([guid]::NewGuid())"
[void](New-Item -ItemType Directory -Path $compatDir)
try {
    $newScript = Join-Path $compatDir 'new.ps1'
    Set-Content -Path $newScript -Value "`$script:DefaultCfg = [ordered]@{`n    ScopeProfile = 'Personal'`n    WinGet = [ordered]@{ Scope = 'machine'; Delays = [ordered]@{ A = 1 } }`n}`nthrow 'must never run'" -Encoding UTF8
    $compatCfg = Join-Path $compatDir 'cfg.json'
    Set-Content -Path $compatCfg -Value '{"_comment":"x","ScopeProfile":"Personal","WinGet":{"Scope":"user","SuppressReboot":true},"Legacy":{}}' -Encoding UTF8
    $unknownCfgKeys = @(Get-ConfigKeysUnknownToScript -ScriptPath $newScript -ConfigPath $compatCfg)
    Assert-True (($unknownCfgKeys -join ',') -eq 'WinGet.SuppressReboot,Legacy') "Unknown keys must be listed (got '$($unknownCfgKeys -join ',')')."
    Assert-True (@(Get-ConfigKeysUnknownToScript -ScriptPath $scriptPath -ConfigPath $exampleConfigPath).Count -eq 0) 'The shipped example config must be compatible with the current script.'
} finally { Remove-Item $compatDir -Recurse -Force -EA SilentlyContinue }

# T38: one property helper, not a nested byte-identical copy.
Assert-True ($scriptContent -notmatch 'Get-ReportProperty') 'Get-ReportProperty duplicate must be removed in favour of Get-ObjectPropertyValue.'

# T39: New-HTMLReport computes each count once.
$htmlText = Get-FunctionTextFromScriptAst -Ast $ast -Name 'New-HTMLReport'
Assert-True ($htmlText -notmatch '\$invKevAffected|\$invKevUnknown|\$hasConfirmedAttention') 'Recomputed counts and aliases must be removed from New-HTMLReport.'

# T40: browser helpers reuse the shared version/path helpers.
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-BrowserVersion')
Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-BrowserUpdater')
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Get-BrowserVersion') -match 'Get-RegistryVersion') 'Get-BrowserVersion must reuse Get-RegistryVersion.'
Assert-True ((Get-FunctionTextFromScriptAst -Ast $ast -Name 'Resolve-BrowserUpdater') -match 'Resolve-FirstExistingPath') 'Resolve-BrowserUpdater must reuse Resolve-FirstExistingPath.'
$script:CFG = [pscustomobject]@{ ScopeProfile = 'Personal' }
[void](Get-BrowserVersion -Browser 'Edge')
[void](Resolve-BrowserUpdater -Browser 'Chrome')

# T41: descoped rows go through Add-SkippedUpgradeResult.
foreach ($fn in 'Add-SkippedUpgradeResult','Get-FilteredUpgrades') { Invoke-Expression (Get-FunctionTextFromScriptAst -Ast $ast -Name $fn) }
& {
    $script:CFG = [pscustomobject]@{ WinGet = [pscustomobject]@{ ApprovedPackages = @(); PublisherManagedPackageIds = @(); ExcludePackagePrefixes = @('Microsoft.VCLibs') } }
    $script:SkippedUpgradeResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    function Test-IsDescoped { param($Item, [ref]$Reason) if ($Item.PackageId -eq 'Corp.Tool') { $Reason.Value = 'Descoped by policy.'; return $true }; $false }
    $filteredPkgs = @(Get-FilteredUpgrades -Upgrades @(
        [pscustomobject]@{ Name = 'Tool'; PackageId = 'Corp.Tool'; Source = 'winget'; Version = '1'; Available = '2' },
        [pscustomobject]@{ Name = 'VCLibs'; PackageId = 'Microsoft.VCLibs.140'; Source = 'winget'; Version = '1'; Available = '2' },
        [pscustomobject]@{ Name = 'Git'; PackageId = 'Git.Git'; Source = 'winget'; Version = '1'; Available = '2' }))
    Assert-True ($filteredPkgs.Count -eq 1 -and $filteredPkgs[0].PackageId -eq 'Git.Git') 'Only the eligible package remains.'
    Assert-True (@($script:SkippedUpgradeResults | Where-Object Status -eq 'Descoped').Count -eq 2 -and $script:SkippedUpgradeResults[0].Provider -eq 'winget') 'Descoped rows keep their status and provider.'
}

Write-Host 'PatchManager static tests passed.' -ForegroundColor Green
