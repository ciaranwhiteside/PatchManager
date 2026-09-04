#Requires -Version 5.1

<#
.SYNOPSIS
    Fleet compliance dashboard for PatchManager.

.DESCRIPTION
    Aggregates per-host PatchManager JSON reports from a central report share
    into a single estate-wide HTML dashboard and CSV summary.

    Expects the directory layout PatchManager writes when
    Reporting.CentralReportPath is configured:

        <CentralReportPath>\<HOSTNAME>\PatchReport_<HOSTNAME>_<stamp>.json

    Only the most recent report per host is used. Hosts whose newest report is
    older than -StaleDays are flagged as stale (device off, task broken, or
    share unreachable from that host).

    Read-only: this script never modifies devices and does not need elevation.

.PARAMETER CentralReportPath
    Root of the central report share (same value as Reporting.CentralReportPath).

.PARAMETER OutputPath
    Directory to write FleetReport_<stamp>.html and .csv. Defaults to the
    current directory.

.PARAMETER StaleDays
    Days without a report before a host is flagged stale. Default: 7.

.PARAMETER OpenReport
    Open the generated HTML dashboard when done.

.EXAMPLE
    .\Get-FleetReport.ps1 -CentralReportPath '\\fileserver\PatchManager\Reports'

.EXAMPLE
    .\Get-FleetReport.ps1 -CentralReportPath 'D:\Central\Reports' -StaleDays 3 -OpenReport
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$CentralReportPath,
    [string]$OutputPath = '.',
    [int]$StaleDays = 7,
    [switch]$OpenReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $CentralReportPath)) {
    throw "Central report path not found or unreachable: $CentralReportPath"
}
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

function ConvertTo-FleetHtml {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-JsonProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    return $Default
}

$now = Get-Date
$hostRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$reportLinks = @{}
$hostDirs = @(Get-ChildItem -Path $CentralReportPath -Directory -EA SilentlyContinue)

Write-Host "Scanning $($hostDirs.Count) host folder(s) under $CentralReportPath ..." -ForegroundColor Cyan

foreach ($hostDir in $hostDirs) {
    $latestJson = Get-ChildItem -Path $hostDir.FullName -Filter 'PatchReport_*.json' -File -EA SilentlyContinue |
                  Sort-Object LastWriteTime -Descending |
                  Select-Object -First 1
    if (-not $latestJson) {
        $hostRows.Add([PSCustomObject]@{
            Hostname        = $hostDir.Name
            LastRun         = $null
            ReportAgeDays   = $null
            Stale           = $true
            Ring            = ''
            ScopeProfile    = ''
            Version         = ''
            DryRun          = ''
            Applied         = $null
            Failed          = $null
            Skipped         = $null
            KEVMatches      = $null
            InventoryKEV    = $null
            EolExposure     = $null
            NvdCritical     = $null
            NvdHigh         = $null
            StalenessReview = $null
            SLABreaches     = $null
            Errors          = $null
            RebootRequired  = $null
            AttentionItems  = $null
            ProvidersExecuted = $false
            Note            = 'Folder exists but contains no JSON reports.'
        })
        continue
    }

    try {
        $report = Get-Content -Path $latestJson.FullName -Raw | ConvertFrom-Json
    } catch {
        $candidateHtmlPath = [System.IO.Path]::ChangeExtension($latestJson.FullName, '.html')
        if (Test-Path -LiteralPath $candidateHtmlPath -PathType Leaf) {
            $reportLinks[$hostDir.Name] = (New-Object System.Uri($candidateHtmlPath)).AbsoluteUri
        }

        $hostRows.Add([PSCustomObject]@{
            Hostname        = $hostDir.Name
            LastRun         = $latestJson.LastWriteTime
            ReportAgeDays   = [Math]::Round(($now - $latestJson.LastWriteTime).TotalDays, 1)
            Stale           = $true
            Ring            = ''
            ScopeProfile    = ''
            Version         = ''
            DryRun          = ''
            Applied         = $null
            Failed          = $null
            Skipped         = $null
            KEVMatches      = $null
            InventoryKEV    = $null
            EolExposure     = $null
            NvdCritical     = $null
            NvdHigh         = $null
            StalenessReview = $null
            SLABreaches     = $null
            Errors          = $null
            RebootRequired  = $null
            AttentionItems  = $null
            ProvidersExecuted = $false
            Note            = "Could not parse $($latestJson.Name): $_"
        })
        continue
    }

    $metadata = Get-JsonProperty $report 'Metadata'
    $stats    = Get-JsonProperty $report 'Statistics'
    $ageDays  = [Math]::Round(($now - $latestJson.LastWriteTime).TotalDays, 1)
    $errors   = @(@(Get-JsonProperty $stats 'Errors' @()) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    $reboot   = @(@(Get-JsonProperty $report 'RebootRequiredItems' @()) | Where-Object {
        $null -ne $_ -and @($_.PSObject.Properties).Count -gt 0
    })
    $attention = @(@(Get-JsonProperty $report 'AttentionItems' @()) | Where-Object {
        $null -ne $_ -and @($_.PSObject.Properties).Count -gt 0
    })
    # Inventory KEV exposure = candidates NVD confirmed affected, or could not clear.
    # A 'NotAffected' candidate is evidence the check ran, not a reason to flag a host.
    # Reports written before exposure resolution existed have no ExposureState; those
    # are counted, matching the old (conservative) behaviour.
    $invKev   = @(@(Get-JsonProperty $report 'InventoryKEVMatches' @()) | Where-Object {
        $null -ne $_ -and @($_.PSObject.Properties).Count -gt 0 -and
        ([string](Get-JsonProperty $_ 'ExposureState' 'Unknown')) -ne 'NotAffected'
    })
    # End-of-life exposure = findings needing action: out of support, nearing support,
    # or behind the latest patch of a still-supported release line.
    # 'info'/Supported findings are evidence, not exposure, so they are not counted.
    $eol      = @(Get-JsonProperty $report 'EndOfLifeFindings' @())
    $eolExposure = @($eol | Where-Object {
        $null -ne $_ -and [string](Get-JsonProperty $_ 'Severity' '') -eq 'review'
    }).Count
    # Staleness review items (stale Defender signatures, feature-update lag). Shown
    # per host for visibility but NOT part of the healthy/attention posture: these
    # thresholds are advisory, unlike a vendor-declared end-of-life boundary.
    $stalenessFindings = @(Get-JsonProperty $report 'StalenessFindings' @())
    $stalenessReview = @($stalenessFindings | Where-Object {
        $null -ne $_ -and [string](Get-JsonProperty $_ 'Severity' '') -eq 'review'
    }).Count

    $resolvedHostname = [string](Get-JsonProperty $metadata 'Hostname' $hostDir.Name)
    $candidateHtmlPath = [System.IO.Path]::ChangeExtension($latestJson.FullName, '.html')
    if (Test-Path -LiteralPath $candidateHtmlPath -PathType Leaf) {
        $reportLinks[$resolvedHostname] = (New-Object System.Uri($candidateHtmlPath)).AbsoluteUri
    }

    $hostRows.Add([PSCustomObject]@{
        Hostname        = $resolvedHostname
        LastRun         = $latestJson.LastWriteTime
        ReportAgeDays   = $ageDays
        Stale           = ($ageDays -gt $StaleDays)
        Ring            = [string](Get-JsonProperty $metadata 'Ring' '')
        ScopeProfile    = [string](Get-JsonProperty $metadata 'ScopeProfile' '')
        Version         = [string](Get-JsonProperty $metadata 'ScriptVer' '')
        DryRun          = [string](Get-JsonProperty $metadata 'DryRun' '')
        Applied         = [int](Get-JsonProperty $stats 'UpdatesApplied' 0)
        Failed          = [int](Get-JsonProperty $stats 'UpdatesFailed' 0)
        Skipped         = [int](Get-JsonProperty $stats 'UpdatesSkipped' 0)
        KEVMatches      = [int](Get-JsonProperty $stats 'KEVMatches' 0)
        InventoryKEV    = $invKev.Count
        EolExposure     = $eolExposure
        # Report-only NVD inventory scan: products with High/Critical CVEs at the
        # installed version. Critical drives the posture; High is shown for visibility.
        NvdCritical     = [int](Get-JsonProperty $stats 'NvdCritical' 0)
        NvdHigh         = [int](Get-JsonProperty $stats 'NvdHigh' 0)
        StalenessReview = $stalenessReview
        SLABreaches     = [int](Get-JsonProperty $stats 'SLABreaches' 0)
        Errors          = $errors.Count
        RebootRequired  = $reboot.Count
        AttentionItems  = $attention.Count
        ProvidersExecuted = [bool](Get-JsonProperty $metadata 'ProvidersExecuted' $true)
        Note            = $(if ([bool](Get-JsonProperty $metadata 'ProvidersExecuted' $true)) { '' } else { [string](Get-JsonProperty $metadata 'RunDisposition' 'Providers did not run') })
    })
}

if ($hostRows.Count -eq 0) {
    throw "No host report folders found under $CentralReportPath. Check Reporting.CentralReportPath on your devices."
}

$stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$csvPath  = Join-Path $OutputPath "FleetReport_$stamp.csv"
$htmlPath = Join-Path $OutputPath "FleetReport_$stamp.html"

$hostRows | Sort-Object Hostname | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

#-- Fleet summary numbers ---------------------------------------------------
$totalHosts    = $hostRows.Count
$staleHosts    = @($hostRows | Where-Object { $_.Stale }).Count
$hostsWithFail = @($hostRows | Where-Object { $_.Failed -gt 0 }).Count
$deferredHosts = @($hostRows | Where-Object { -not $_.ProvidersExecuted }).Count
$hostsWithKev  = @($hostRows | Where-Object { ($_.KEVMatches -gt 0) -or ($_.InventoryKEV -gt 0) }).Count
$hostsWithNvdHigh = @($hostRows | Where-Object { $_.NvdHigh -gt 0 }).Count
$hostsWithSla  = @($hostRows | Where-Object { $_.SLABreaches -gt 0 }).Count
$hostsWithErrors = @($hostRows | Where-Object { $_.Errors -gt 0 }).Count
$slaRelevant   = $hostsWithSla -gt 0 -or @($hostRows | Where-Object { $_.ScopeProfile -in @('Commercial', 'CommercialManaged') }).Count -gt 0
$hostsWithEol  = @($hostRows | Where-Object { $_.EolExposure -gt 0 }).Count
$hostsReboot   = @($hostRows | Where-Object { $_.RebootRequired -gt 0 }).Count
$hostsWithStaleEvidence = @($hostRows | Where-Object { $_.Stale -or $_.StalenessReview -gt 0 }).Count
$hostsWithConfirmedSecurity = @($hostRows | Where-Object { $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.NvdCritical -gt 0 -or $_.SLABreaches -gt 0 }).Count
$hostsWithSecurity = @($hostRows | Where-Object { $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.NvdCritical -gt 0 -or $_.NvdHigh -gt 0 -or $_.SLABreaches -gt 0 }).Count
$healthyHosts  = @($hostRows | Where-Object {
    -not $_.Stale -and $_.StalenessReview -eq 0 -and $_.ProvidersExecuted -and $_.Failed -eq 0 -and $_.KEVMatches -eq 0 -and $_.InventoryKEV -eq 0 -and $_.SLABreaches -eq 0 -and $_.Errors -eq 0 -and $_.RebootRequired -eq 0 -and (-not ($_.EolExposure -gt 0)) -and (-not ($_.NvdCritical -gt 0)) -and (-not ($_.NvdHigh -gt 0))
}).Count

$securityTone  = if ($hostsWithConfirmedSecurity -gt 0) { 'danger' } elseif ($hostsWithNvdHigh -gt 0) { 'attention' } else { 'good' }
$executionTone = if ($hostsWithFail -gt 0 -or $deferredHosts -gt 0 -or $hostsWithErrors -gt 0) { 'danger' } else { 'good' }
$currencyTone  = if ($hostsWithStaleEvidence -gt 0) { 'attention' } else { 'good' }
$lifecycleTone = if ($hostsWithEol -gt 0) { 'danger' } else { 'good' }
$completionTone = if ($hostsReboot -gt 0) { 'attention' } else { 'good' }
$fleetTone = if ($securityTone -eq 'danger' -or $executionTone -eq 'danger' -or $lifecycleTone -eq 'danger') {
    'danger'
} elseif ($securityTone -eq 'attention' -or $currencyTone -eq 'attention' -or $completionTone -eq 'attention') {
    'attention'
} else {
    'good'
}
$attentionHosts = @($hostRows | Where-Object {
    $_.Stale -or $_.StalenessReview -gt 0 -or -not $_.ProvidersExecuted -or $_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0 -or $_.RebootRequired -gt 0 -or ($_.EolExposure -gt 0) -or ($_.NvdCritical -gt 0) -or ($_.NvdHigh -gt 0)
}).Count
$fleetVerdictTitle = if ($attentionHosts -eq 0) {
    'Fleet reporting is current.'
} elseif ($hostsWithConfirmedSecurity -gt 0) {
    'Fleet exposure needs action.'
} else {
    'Fleet needs review.'
}
$fleetVerdictCopy = if ($attentionHosts -eq 0) {
    if ($slaRelevant) {
        'Every latest host report is fresh and free of failure, KEV, NVD Critical, NVD High, SLA, end-of-life, script error, and reboot signals.'
    } else {
        'Every latest host report is fresh and free of failure, KEV, NVD Critical, NVD High, end-of-life, script error, and reboot signals.'
    }
} elseif ($hostsWithConfirmedSecurity -gt 0) {
    if ($slaRelevant) {
        'Prioritise hosts with KEV, inventory KEV, NVD Critical, or SLA exposure before treating the estate as current.'
    } else {
        'Prioritise hosts with KEV, inventory KEV, or NVD Critical exposure before treating the estate as current.'
    }
} else {
    'Review stale hosts, deferred provider runs, failures, end-of-life exposure, script errors, and reboot-required rows before closing the fleet view.'
}
$securitySummaryLabel = 'Security hosts'
$securitySummaryValue = [string]$hostsWithSecurity
$securityLaneDetail = if ($slaRelevant) { 'KEV · Critical/High · SLA' } else { 'KEV · Critical/High' }

function Get-FleetRiskRank {
    param($Row)
    if ($Row.KEVMatches -gt 0 -or $Row.InventoryKEV -gt 0 -or $Row.NvdCritical -gt 0 -or $Row.SLABreaches -gt 0) { return 1 }
    if ($Row.Failed -gt 0 -or $Row.Errors -gt 0 -or -not $Row.ProvidersExecuted) { return 2 }
    if ($Row.Stale -or $Row.EolExposure -gt 0 -or $Row.NvdHigh -gt 0 -or $Row.StalenessReview -gt 0 -or $Row.RebootRequired -gt 0) { return 3 }
    return 4
}

function Get-FleetPosture {
    param($Row)
    $rank = Get-FleetRiskRank $Row
    if ($rank -le 2 -or $Row.EolExposure -gt 0) { return 'attention' }
    if ($Row.Stale) { return 'stale' }
    if ($rank -eq 3) { return 'review' }
    return 'healthy'
}

$tableRows = ($hostRows | Sort-Object @{ Expression = { Get-FleetRiskRank $_ } },
    @{ Expression = { if ($null -ne $_.ReportAgeDays) { [double]$_.ReportAgeDays } else { [double]::MaxValue } }; Descending = $true },
    Hostname | ForEach-Object {
    $riskRank = Get-FleetRiskRank $_
    $rowPosture = Get-FleetPosture $_
    $postureTone = $rowPosture
    $rowClass = if ($riskRank -le 2) { 'attention' } elseif ($riskRank -eq 3) { 'review' } else { 'ok' }
    $lastRunText = if ($_.LastRun) { $_.LastRun.ToString('dd MMM yyyy HH:mm') } else { 'never' }
    $lastRunSort = if ($_.LastRun) { ([datetime]$_.LastRun).Ticks } else { 0 }
    $ageSort = if ($null -ne $_.ReportAgeDays) { $_.ReportAgeDays } else { 999999 }
    $staleText = if ($_.Stale) { "STALE ($($_.ReportAgeDays)d)" } elseif ($null -ne $_.ReportAgeDays) { "$($_.ReportAgeDays)d ago" } else { '' }
    $noteText = if ($_.Note) { $_.Note } else { '-' }

    $riskTokens = [System.Collections.Generic.List[string]]::new()
    if ($_.Stale -or $_.StalenessReview -gt 0) { $riskTokens.Add('stale') }
    if ($_.Failed -gt 0 -or $_.Errors -gt 0 -or -not $_.ProvidersExecuted) { $riskTokens.Add('failure') }
    if ($_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.NvdCritical -gt 0 -or $_.NvdHigh -gt 0 -or $_.SLABreaches -gt 0) { $riskTokens.Add('security') }
    if ($_.EolExposure -gt 0) { $riskTokens.Add('eol') }
    if ($_.RebootRequired -gt 0) { $riskTokens.Add('reboot') }

    $hostNameHtml = ConvertTo-FleetHtml $_.Hostname
    $hostMarkup = if ($reportLinks.ContainsKey([string]$_.Hostname)) {
        $reportUri = [string]$reportLinks[[string]$_.Hostname]
        "<a class='host-link' href='$(ConvertTo-FleetHtml $reportUri)' aria-label='Open latest device report for $hostNameHtml'>$hostNameHtml</a>"
    } else {
        "<strong>$hostNameHtml</strong><span class='cell-detail'>HTML report unavailable</span>"
    }
    $postureLabel = switch ($postureTone) { 'healthy' { 'Healthy' } 'stale' { 'Stale' } 'review' { 'Review' } default { 'Attention' } }
    $signalItems = [System.Collections.Generic.List[string]]::new()
    if ($_.KEVMatches -gt 0) { $signalItems.Add("<span class='signal danger'>$($_.KEVMatches) KEV</span>") }
    if ($_.InventoryKEV -gt 0) { $signalItems.Add("<span class='signal danger'>$($_.InventoryKEV) inventory KEV</span>") }
    if ($_.NvdCritical -gt 0) { $signalItems.Add("<span class='signal danger'>$($_.NvdCritical) NVD critical</span>") }
    if ($_.NvdHigh -gt 0) { $signalItems.Add("<span class='signal attention'>$($_.NvdHigh) NVD high</span>") }
    if ($_.SLABreaches -gt 0) { $signalItems.Add("<span class='signal danger'>$($_.SLABreaches) SLA</span>") }
    if ($_.EolExposure -gt 0) { $signalItems.Add("<span class='signal danger'>$($_.EolExposure) EOL</span>") }
    if ($_.StalenessReview -gt 0) { $signalItems.Add("<span class='signal attention'>$($_.StalenessReview) stale finding</span>") }
    $signalsMarkup = if ($signalItems.Count) { $signalItems -join '' } else { "<span class='signal clear'>No exposure signals</span>" }
    $outcomeMarkup = "<strong>$($_.Applied) applied</strong><span class='cell-detail'>$($_.Failed) failed / $($_.Errors) errors</span>"
    $rebootMarkup = if ($_.RebootRequired -gt 0) { "<span class='signal attention'>$($_.RebootRequired) pending</span>" } else { "<span class='signal clear'>Clear</span>" }
    $searchText = "$(ConvertTo-FleetHtml $_.Hostname) $(ConvertTo-FleetHtml $_.Ring) $(ConvertTo-FleetHtml $_.ScopeProfile) $(ConvertTo-FleetHtml $_.Version) $(ConvertTo-FleetHtml $noteText)"
    "<tr class='fleet-row $rowClass' data-search='$searchText' data-posture='$rowPosture' data-risk='$($riskTokens -join ' ')' data-riskrank='$riskRank' data-ring='$(ConvertTo-FleetHtml $_.Ring)' data-profile='$(ConvertTo-FleetHtml $_.ScopeProfile)' data-host='$hostNameHtml' data-last='$lastRunSort' data-age='$ageSort' data-applied='$(ConvertTo-FleetHtml $_.Applied)'><td>$hostMarkup<span class='posture $rowPosture'>$postureLabel</span></td><td class='nowrap'>$(ConvertTo-FleetHtml $lastRunText)<span class='cell-detail'>$(ConvertTo-FleetHtml $staleText)</span></td><td>$(ConvertTo-FleetHtml $_.Ring)<span class='cell-detail'>$(ConvertTo-FleetHtml $_.ScopeProfile) · v$(ConvertTo-FleetHtml $_.Version)</span></td><td class='signals'>$signalsMarkup</td><td>$outcomeMarkup</td><td>$rebootMarkup</td><td class='details'>$(ConvertTo-FleetHtml $noteText)</td><td class='details'><details><summary>All metrics</summary><dl class='metric-list'><dt>Skipped</dt><dd>$($_.Skipped)</dd><dt>NVD High</dt><dd>$($_.NvdHigh)</dd><dt>Attention items</dt><dd>$($_.AttentionItems)</dd><dt>Providers ran</dt><dd>$($_.ProvidersExecuted)</dd></dl></details></td></tr>"
}) -join "`n"

$generatedAt = ConvertTo-FleetHtml (Get-Date -Format 'dd MMM yyyy HH:mm:ss')
$centralEsc  = ConvertTo-FleetHtml $CentralReportPath
$brandMark = @'
<svg class="brand-mark" viewBox="0 0 64 64" aria-hidden="true" focusable="false"><rect width="64" height="64" rx="14" fill="#f6f2e8"/><path d="M32 7 53 15v15c0 13.5-8.5 22-21 28C19.5 52 11 43.5 11 30V15L32 7Z" fill="#111513"/><path d="M32 12.5 47 18v12c0 9.5-5.5 16.5-15 21.5C22.5 46.5 17 39.5 17 30V18l15-5.5Z" fill="#f6f2e8"/><path d="M24.5 18h11.5l6.5 6.5V42h-18V18Z" fill="#fff" stroke="#18324a" stroke-width="2" stroke-linejoin="round"/><path d="M36 18v7h6.5" fill="none" stroke="#18324a" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M24 34 29.5 39.5 41 27.5" fill="none" stroke="#24744f" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"/><path d="M19 46.5c3.5 4 8 7 13 9.5 5-2.5 9.5-5.5 13-9.5" fill="none" stroke="#c49a3d" stroke-width="2" stroke-linecap="round"/></svg>
'@

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>PatchManager fleet report</title>
<style>
  /* PatchManager evidence ledger - fleet view.
     Self-contained, print-safe, and aligned with docs/brand/BRAND.md. */
  :root{--charcoal:#111513;--charcoal-2:#1a201c;--paper:#f6f2e8;--paper-soft:#efe8d9;--card:#fcfaf3;--ink:#111513;--muted:#5f6a62;--line:#ddd5c2;--line-strong:#c8bfa6;--blue:#18324a;--blue-soft:#e8edf2;--green:#24744f;--green-bg:#e9f2ea;--red:#a53b35;--red-bg:#f7e6e1;--amber:#955d20;--amber-curve:#c49a3d;--amber-bg:#faf0d8;--steel:#365f72;--steel-bg:#e6eef1;--card-shadow:0 1px 2px rgba(17,21,19,.05),0 10px 32px rgba(17,21,19,.07)}
  *{box-sizing:border-box}
  html{scroll-behavior:smooth;background:var(--paper)}
  body{margin:0;overflow-x:hidden;background:var(--paper);color:var(--ink);font:14px/1.55 "Segoe UI Variable Text","Aptos","Segoe UI",system-ui,-apple-system,sans-serif;font-variant-numeric:tabular-nums}
  .skip-link{position:absolute;left:-999px;top:8px;background:#fff;color:#000;padding:8px 10px;border-radius:6px;z-index:20}.skip-link:focus{left:8px}
  .brand-lockup{display:inline-flex;align-items:center;gap:10px}.brand-mark{width:30px;height:30px;flex:0 0 auto}.brand-word{font-weight:820}.hero-brand{margin-bottom:16px;color:#f6f2e8;font-weight:760}.hero-brand .brand-mark{width:34px;height:34px}.footer-brand .brand-mark{width:24px;height:24px}
  .fleet-nav{position:sticky;top:0;z-index:12;display:grid;grid-template-columns:auto minmax(260px,1fr);gap:14px;align-items:start;padding:10px 32px;background:rgba(17,21,19,.98);border-bottom:1px solid rgba(246,242,232,.12);color:#fff}.nav-brand{font-weight:820}.nav-links{display:flex;gap:8px;flex-wrap:wrap}.nav-links a{color:#cfd8d1;text-decoration:none;border:1px solid rgba(246,242,232,.16);border-radius:999px;padding:7px 11px;font-size:.82rem}.nav-links a:hover{color:#fff;border-color:rgba(246,242,232,.4);background:rgba(246,242,232,.07)}.fleet-toolbar{display:grid;grid-template-columns:minmax(240px,1fr) auto auto;gap:8px;align-items:end;grid-column:1/-1}.filter-fields{display:grid;grid-template-columns:135px 135px 155px auto;gap:8px;align-items:end}.filter-toggle{display:none}
  label{display:block;color:#a9b4ab;font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.07em;margin-bottom:4px}input,select,button{font:inherit}input,select{width:100%;height:44px;border:1px solid rgba(246,242,232,.22);border-radius:7px;background:rgba(246,242,232,.08);color:#fff;padding:0 10px;outline:none;transition:border-color .18s ease,box-shadow .18s ease,background .18s ease}select option{color:#111513;background:#fff}input::placeholder{color:#96a29a}input:focus,select:focus,button:focus-visible{outline:3px solid rgba(196,154,61,.35);border-color:var(--amber-curve)}button{min-height:44px;height:auto;border:1px solid rgba(246,242,232,.25);border-radius:7px;background:var(--paper);color:var(--ink);padding:8px 13px;cursor:pointer;font-weight:760;transition:transform .18s ease,background .18s ease,box-shadow .18s ease}button:hover{background:#fff;box-shadow:0 8px 22px rgba(0,0,0,.28)}button:active{transform:translateY(1px)}
  .hero{position:relative;color:#fff;padding:32px;background:var(--charcoal);border-bottom:2px solid var(--amber-curve)}.hero-inner{position:relative;max-width:1440px;margin:0 auto;display:grid;grid-template-columns:minmax(0,1fr) minmax(300px,420px);gap:32px;align-items:center}.hero-copy{min-width:0;max-width:72rem}.eyebrow{margin:0 0 6px;color:var(--muted);font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.08em}h1,h2,p{margin-top:0}h1{font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(2rem,3.4vw,3.2rem);line-height:1.02;margin:0 0 12px;font-weight:800;text-wrap:balance;overflow-wrap:anywhere}h2{font-size:1.12rem;line-height:1.2;margin:0 0 4px;font-weight:760;text-wrap:balance}.hero-summary{max-width:68ch;color:#d5ddd7;font-size:1.02rem;margin:0;text-wrap:pretty}.hero-panel{min-width:0;align-self:stretch;display:grid;grid-template-columns:minmax(0,1fr);align-content:center;gap:8px}.hero-proof{min-width:0;border:1px solid rgba(246,242,232,.13);background:rgba(246,242,232,.05);border-radius:12px;padding:10px 12px}.hero-proof span{display:block;color:#b8c4bc;font-size:.72rem;font-weight:720}.hero-proof strong{display:block;margin-top:2px;color:#fff;overflow-wrap:anywhere;line-height:1.3}
  main{max-width:1440px;margin:0 auto;padding:0 32px 56px;overflow-x:hidden}.fleet-status{display:grid;grid-template-columns:repeat(4,1fr);margin:24px 0;border:1px solid var(--line-strong);border-radius:14px;background:var(--card);overflow:hidden;box-shadow:var(--card-shadow)}.fleet-status-cell{display:grid;grid-template-columns:1fr auto;align-items:center;gap:16px;padding:15px 18px;border-right:1px solid var(--line)}.fleet-status-cell:last-child{border-right:0}.fleet-status-cell span{color:var(--muted);font-weight:740}.fleet-status-cell strong{font-size:1.24rem}.fleet-status-cell.good strong{color:var(--green)}.fleet-status-cell.attention strong{color:var(--amber)}.fleet-status-cell.danger strong{color:var(--red)}
  .fleet-lanes{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:24px}.lane{height:auto;min-width:0;text-align:left;color:#fff;border-radius:12px;padding:14px;background:var(--charcoal);border:1px solid rgba(246,242,232,.14);box-shadow:none}.lane:hover{background:var(--charcoal-2);box-shadow:none}.lane[aria-pressed="true"]{border-color:var(--amber-curve);background:var(--blue)}.lane span{display:block;color:#b9c4bc;font-size:.78rem;font-weight:760}.lane strong{display:block;font-size:1.45rem;line-height:1.1;margin-top:4px}.lane small{display:block;margin-top:5px;color:#d7dfd9;font-weight:500}
  .fleet-layout{display:grid;gap:18px}.fleet-evidence{background:var(--charcoal);color:#fff;border-radius:14px;padding:18px}.fleet-evidence h2{margin-bottom:10px}.scrub-copy{margin:0;display:flex;gap:18px;flex-wrap:wrap}.scrub-copy span{color:#dce5df}.evidence-meta{display:grid;grid-template-columns:2fr 1fr 1fr;gap:9px;margin-top:14px}.evidence-meta div{border:1px solid rgba(246,242,232,.15);border-radius:12px;padding:9px 10px}.evidence-meta span{display:block;color:#a9b4ab;font-size:.72rem;font-weight:740}.evidence-meta strong{display:block;color:#fff;word-break:break-word}.reveal{opacity:1;transform:none}
  .panel{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px;margin-bottom:0;box-shadow:var(--card-shadow)}.section-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:14px}.section-head p{margin:5px 0 0;color:var(--muted);max-width:70ch}.count{display:inline-flex;min-width:36px;justify-content:center;border-radius:7px;padding:4px 9px;font-weight:820;background:#e7dfcc;color:#332f29}.result-count{color:var(--muted);font-size:.86rem;margin-top:10px}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:12px;background:#fffdf6}.table-wrap:focus-visible{outline:3px solid rgba(24,50,74,.3);outline-offset:2px}table{width:100%;min-width:1040px;border-collapse:separate;border-spacing:0;font-size:.89rem}th,td{padding:11px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}th{position:sticky;top:0;background:#efe8d7;color:#4a453c;font-size:.71rem;font-weight:800;text-transform:uppercase;letter-spacing:.06em;white-space:nowrap;user-select:none;box-shadow:0 1px 0 var(--line)}.sort-button{height:auto;border:0;border-radius:4px;background:transparent;color:inherit;padding:2px 18px 2px 0;box-shadow:none;text-transform:inherit;letter-spacing:inherit;position:relative}.sort-button:hover{background:transparent;box-shadow:none;color:var(--ink)}.sort-button:after{content:"↕";position:absolute;right:0;color:#817767}.sort-button[aria-label$="ascending"]:after{content:"↑"}.sort-button[aria-label$="descending"]:after{content:"↓"}
  tbody tr:last-child td{border-bottom:none}
  tbody tr{transition:background .18s ease}tbody tr:hover td{background:#fdf9ee}
  tr.ok td{box-shadow:inset 1px 0 0 var(--green)}
  tr.attention td{box-shadow:inset 1px 0 0 var(--red)}
  tr.review td{box-shadow:inset 1px 0 0 var(--amber-curve)}
  tr.ok td:not(:first-child),tr.attention td:not(:first-child),tr.review td:not(:first-child){box-shadow:none}
  .mono{font-family:"Cascadia Mono","Consolas",monospace;font-size:.84rem}
  .nowrap{white-space:nowrap}
  .details{color:var(--muted);font-size:.82rem;max-width:360px}.details summary{cursor:pointer;color:var(--blue);font-weight:760}.host-link{display:block;color:var(--blue);font-weight:820;text-underline-offset:3px}.cell-detail{display:block;margin-top:4px;color:var(--muted);font-size:.76rem;white-space:normal}.posture,.signal{display:inline-flex;width:max-content;border-radius:6px;padding:3px 7px;font-size:.73rem;font-weight:800}.posture{margin-top:7px}.posture.healthy,.signal.clear{background:var(--green-bg);color:var(--green)}.posture.attention,.signal.danger{background:var(--red-bg);color:var(--red)}.posture.stale,.posture.review,.signal.attention{background:var(--amber-bg);color:var(--amber)}.signals{min-width:190px}.signal{margin:0 5px 5px 0}.metric-list{display:grid;grid-template-columns:auto auto;gap:3px 12px;margin:8px 0 0}.metric-list dt{color:var(--muted)}.metric-list dd{margin:0;font-weight:760}
  .footer{margin-top:34px;padding:26px 28px;border-radius:8px;background:var(--charcoal);color:#c8d2ca;display:flex;justify-content:space-between;gap:18px;align-items:center;box-shadow:inset 0 -3px var(--amber-curve)}.footer a{color:#fff;text-decoration-color:rgba(196,154,61,.7);text-underline-offset:3px}.footer a:hover{text-decoration-color:var(--amber-curve)}
  @media (max-width:1180px){.fleet-nav{grid-template-columns:minmax(0,1fr)}.fleet-toolbar{grid-template-columns:minmax(220px,1fr) auto auto}.fleet-layout{grid-template-columns:1fr}.fleet-evidence{position:static}.fleet-lanes{grid-template-columns:repeat(5,minmax(160px,1fr));overflow-x:auto;padding-bottom:4px}}
  @media (max-width:980px){.fleet-toolbar{grid-template-columns:minmax(0,1fr) auto}.fleet-toolbar .search-field{min-width:0;grid-column:1/-1}.filter-toggle{display:inline-flex}.filter-fields{display:none;grid-column:1/-1;grid-template-columns:minmax(0,1fr) minmax(0,1fr)}.filter-fields.is-open{display:grid}}
  @media (max-width:760px){.fleet-nav,.hero,main{padding-left:max(18px,env(safe-area-inset-left));padding-right:max(18px,env(safe-area-inset-right))}.fleet-nav>*{min-width:0}.nav-links{min-width:0;flex-wrap:nowrap;overflow-x:auto;max-width:100%;padding-bottom:4px}.fleet-toolbar{min-width:0;grid-template-columns:minmax(0,1fr) auto}.filter-fields{min-width:0}input,select,button{font-size:16px}.hero-inner{min-width:0;grid-template-columns:minmax(0,1fr)}.hero-panel{max-width:none}.fleet-status{grid-template-columns:1fr 1fr}.panel{padding:16px}.section-head{display:block}.count{display:block;margin-top:8px}.footer{display:block;padding-bottom:max(26px,env(safe-area-inset-bottom))}.table-wrap{border-radius:7px}}
  @media (max-width:440px){.filter-fields,.fleet-status{grid-template-columns:1fr}h1{font-size:clamp(1.9rem,9vw,2.6rem)}}
  @media print{body{background:#fff;color:#000}.fleet-nav,button,.skip-link{display:none}.hero{background:#fff;color:#000;padding:18px 0;border-bottom:2px solid #000}.hero-summary,.hero-proof span{color:#333}.hero-panel,.hero-proof,.panel,.fleet-evidence{box-shadow:none;background:#fff;color:#000}.fleet-status,.fleet-layout{display:block}.fleet-status-cell{display:inline-block;width:23%;border:1px solid #777}.fleet-lanes{display:none}main{padding:18px 0}.table-wrap{overflow:visible}.panel{break-inside:auto}tr{break-inside:avoid}.details[open] .metric-list,details>:not(summary){display:grid}}
  @media (forced-colors:active){.fleet-status-cell,.lane,.panel,.table-wrap,.posture,.signal{border:1px solid CanvasText}.brand-mark{forced-color-adjust:auto}}
  @media (prefers-reduced-motion: reduce){html{scroll-behavior:auto}*{transition:none !important}}
  /* Systems Health Map composition — estate topology with functional risk paths. */
  ::selection{background:#18324a;color:#fff}*{scrollbar-color:var(--line-strong) #eee7d7;scrollbar-width:thin}input{caret-color:var(--amber-curve)}
  .fleet-nav{grid-template-columns:auto minmax(0,1fr);align-items:center;padding-block:8px}.nav-brand>span{display:grid;line-height:1.05}.nav-brand small{margin-top:4px;color:#aeb9b1;font-size:.69rem;font-weight:560}.nav-links{justify-self:end}.fleet-toolbar{grid-template-columns:minmax(260px,1fr) auto auto;align-items:end}.filter-fields{grid-template-columns:repeat(3,minmax(120px,1fr)) auto}
  .fleet-masthead{max-width:1440px;margin:0 auto;padding:18px 32px 14px;display:flex;align-items:end;justify-content:space-between;gap:32px;border-bottom:1px solid var(--line-strong)}.fleet-masthead h1{font-size:1.45rem;line-height:1.15;margin:0 0 4px;letter-spacing:-.02em}.fleet-masthead p{margin:0;color:var(--muted);max-width:70ch}.fleet-run-identity{display:grid;grid-template-columns:repeat(3,auto);gap:0;margin:0}.fleet-run-identity div{min-width:0;padding:0 16px;border-left:1px solid var(--line)}.fleet-run-identity dt,.fleet-verdict-state>div>span,.fleet-verdict-fact>span{color:var(--muted);font-size:.68rem;font-weight:800;letter-spacing:.07em;text-transform:uppercase}.fleet-run-identity dd{max-width:34ch;margin:2px 0 0;font-weight:760;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  main{padding-top:16px}.fleet-verdict{display:grid;grid-template-columns:minmax(290px,1.7fr) repeat(3,minmax(130px,.72fr)) minmax(220px,.9fr);align-items:stretch;margin:0 0 14px;border:1px solid var(--line-strong);border-radius:12px;background:var(--card);overflow:hidden}.fleet-verdict.danger{border-color:#e0b0a8}.fleet-verdict.attention{border-color:var(--amber-curve)}.fleet-verdict-state,.fleet-verdict-fact{min-width:0;padding:14px 16px;border-right:1px solid var(--line)}.fleet-verdict-state{display:grid;grid-template-columns:auto minmax(0,1fr);gap:12px;align-items:start}.fleet-verdict-state strong{display:block;font-size:1.08rem;line-height:1.18;margin:2px 0 3px}.fleet-verdict-state small,.fleet-verdict-fact small{display:block;color:var(--muted);line-height:1.35}.fleet-verdict-fact{display:flex;flex-direction:column;justify-content:center}.fleet-verdict-fact strong{display:block;margin:3px 0;font-size:.94rem;line-height:1.2}.primary-action{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:14px 16px;background:var(--blue);color:#fff;text-decoration:none;font-weight:800;transition:background .18s cubic-bezier(.16,1,.3,1)}.primary-action:hover{background:var(--blue)}.primary-action:focus-visible,.lane:focus-visible{outline:3px solid var(--amber-curve);outline-offset:-4px}
  .state-dot{display:inline-block;width:10px;height:10px;border-radius:50%;background:var(--steel);box-shadow:0 0 0 3px var(--steel-bg);flex:0 0 auto}.state-dot.good{background:var(--green);box-shadow:0 0 0 3px var(--green-bg)}.state-dot.attention,.state-dot.review{background:var(--amber);box-shadow:0 0 0 3px var(--amber-bg)}.state-dot.danger{background:var(--red);box-shadow:0 0 0 3px var(--red-bg)}
  .panel{border-radius:12px;padding:18px;box-shadow:none}.fleet-health-map{margin:0 0 14px}.map-head{display:flex;justify-content:space-between;gap:18px;align-items:start;padding-bottom:11px;border-bottom:1px solid var(--line)}.map-head p{margin:4px 0 0;color:var(--muted);max-width:70ch}.map-legend{display:flex;gap:13px;flex-wrap:wrap;justify-content:flex-end;color:var(--muted);font-size:.75rem}.map-legend span{display:flex;align-items:center;gap:7px;white-space:nowrap}.map-legend .state-dot{width:8px;height:8px}
  .estate-topology{display:grid;grid-template-columns:minmax(180px,.65fr) minmax(0,2.8fr);gap:42px;align-items:center;padding:18px 0 2px}.estate-root{position:relative;display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:10px;align-items:center;border:1px solid var(--line-strong);border-radius:8px;background:#fffdf6;padding:12px}.estate-root:after{content:"";position:absolute;left:100%;top:50%;width:43px;border-top:1px solid var(--line-strong)}.estate-root strong{display:block}.estate-root small{display:block;color:var(--muted);font-size:.72rem;margin-top:2px}.estate-root>b{display:grid;place-items:center;min-width:27px;height:27px;border-radius:6px;background:var(--paper-soft)}
  .fleet-lanes{position:relative;display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:8px;margin:0}.fleet-lanes:before{content:"";position:absolute;right:calc(100% + 21px);top:9%;bottom:9%;border-left:1px solid var(--line-strong)}.lane{position:relative;display:grid;grid-template-columns:auto auto minmax(0,1fr);gap:9px;align-items:center;min-height:70px;margin:0;padding:10px 11px;border:1px solid var(--line-strong);border-radius:8px;background:#fffdf6;color:var(--ink);box-shadow:none}.lane:before{content:"";position:absolute;right:100%;top:50%;width:22px;border-top:1px solid var(--line-strong)}.lane:hover{background:#fff;border-color:var(--line-strong);box-shadow:none}.lane[aria-pressed="true"]{background:var(--blue);border-color:var(--blue);color:#fff}.lane span.state-dot{display:block;margin:0;color:inherit}.lane b{display:grid;line-height:1.05}.lane b strong{display:block;margin:0;font-size:1.18rem;color:inherit}.lane b small{display:block;margin-top:5px;color:var(--muted);font-size:.7rem;font-weight:800;text-transform:uppercase;letter-spacing:.05em}.lane em{display:block;color:var(--muted);font-size:.72rem;font-style:normal;line-height:1.3}.lane[aria-pressed="true"] b small,.lane[aria-pressed="true"] em{color:#fff}
  .fleet-layout{gap:14px}.fleet-evidence{border-radius:12px}.section-head{margin-bottom:12px;padding-bottom:11px}.table-wrap{border-radius:8px}.footer{border-radius:12px}
  @media(max-width:1180px){.fleet-verdict{grid-template-columns:minmax(270px,1.5fr) repeat(3,minmax(120px,1fr))}.primary-action{grid-column:1/-1;min-height:48px}.estate-topology{grid-template-columns:1fr;gap:15px}.estate-root:after,.fleet-lanes:before,.lane:before{display:none}.fleet-lanes{grid-template-columns:repeat(5,minmax(170px,1fr));overflow-x:auto;padding-bottom:5px}.fleet-run-identity{grid-template-columns:repeat(2,auto)}.fleet-run-identity div:nth-child(3){grid-column:1/-1;border-left:0;margin-top:8px;padding-left:0}}
  @media(max-width:820px){.fleet-nav{grid-template-columns:minmax(0,1fr)}.nav-links{justify-self:start;max-width:100%;overflow-x:auto;flex-wrap:nowrap}.fleet-toolbar{grid-template-columns:minmax(0,1fr) auto}.fleet-toolbar .search-field{grid-column:1/-1}.fleet-masthead{padding-inline:20px;display:block}.fleet-run-identity{margin-top:14px;grid-template-columns:1fr 1fr}.fleet-verdict{grid-template-columns:1fr 1fr}.fleet-verdict-state{grid-column:1/-1}.fleet-verdict-fact:nth-of-type(3){border-right:0}.primary-action{grid-column:1/-1}.map-head{display:block}.map-legend{justify-content:flex-start;margin-top:10px}}
  @media(max-width:620px){.fleet-nav,main{padding-inline:max(16px,env(safe-area-inset-left))}.fleet-masthead{padding-inline:max(16px,env(safe-area-inset-left))}.filter-fields{grid-template-columns:1fr 1fr}.fleet-verdict{grid-template-columns:1fr}.fleet-verdict-state,.fleet-verdict-fact{border-right:0;border-bottom:1px solid var(--line)}.primary-action{grid-column:auto}.fleet-run-identity{grid-template-columns:1fr}.fleet-run-identity div,.fleet-run-identity div:nth-child(3){grid-column:auto;padding:0;border-left:0;margin-top:8px}.fleet-lanes{grid-template-columns:1fr;overflow:visible}.panel{padding:15px}#fleetTable{min-width:0}#fleetTable thead{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}#fleetTable,#fleetTable tbody,#fleetTable tr,#fleetTable td{display:block;width:100%}#fleetTable tr{padding:9px 0;border-bottom:1px solid var(--line)}#fleetTable td{display:grid;grid-template-columns:92px minmax(0,1fr);gap:10px;padding:7px 5px;border:0;box-shadow:none;max-width:none}#fleetTable td:before{color:var(--muted);font-size:.67rem;font-weight:800;letter-spacing:.06em;text-transform:uppercase}#fleetTable td:nth-child(1):before{content:"Host"}#fleetTable td:nth-child(2):before{content:"Last report"}#fleetTable td:nth-child(3):before{content:"Scope"}#fleetTable td:nth-child(4):before{content:"Signals"}#fleetTable td:nth-child(5):before{content:"Outcome"}#fleetTable td:nth-child(6):before{content:"Reboot"}#fleetTable td:nth-child(7):before{content:"Notes"}#fleetTable td:nth-child(8):before{content:"More"}#fleetTable .signals{min-width:0}.fleet-evidence{padding:15px}.evidence-meta{grid-template-columns:1fr}}
  @media print{.fleet-masthead{padding:10px 0}.fleet-verdict,.estate-topology{display:block}.primary-action{display:none}.fleet-health-map,.estate-root,.lane{border:1px solid #777}.fleet-lanes{display:grid;grid-template-columns:repeat(3,1fr);overflow:visible}.lane{color:#000;background:#fff}.fleet-lanes:before,.estate-root:after,.lane:before{display:none}}
  @media(forced-colors:active){.fleet-verdict,.estate-root,.lane,.state-dot,.primary-action{border:1px solid CanvasText}.state-dot{box-shadow:none}.primary-action{background:Canvas;color:CanvasText}}
  @media(max-width:620px){.fleet-verdict>.primary-action{grid-row:2}}
  /* Mockup-fidelity pass — compact estate evidence instrument, September 2026. */
  body{background:#f7f6f1;font-size:13px;line-height:1.42}
  .fleet-nav{position:static;display:grid;grid-template-columns:minmax(210px,.85fr) minmax(520px,1.7fr) auto;align-items:center;gap:20px;min-height:54px;padding:7px 24px;background:#fffdf8;color:var(--ink);border-bottom:1px solid #d8d7d0}
  .nav-brand{color:var(--ink)}.nav-brand>span{display:flex;align-items:baseline;gap:12px;white-space:nowrap}.nav-brand small{margin:0;color:var(--muted);font-size:.67rem}.nav-brand .brand-mark{width:32px;height:32px}
  .nav-run-identity{justify-self:end;grid-template-columns:repeat(3,minmax(100px,auto));align-items:center}.nav-run-identity div{padding:0 14px;border-left:1px solid #deddd6}.nav-run-identity dt{font-size:.62rem}.nav-run-identity dd{font-size:.75rem;margin-top:1px;max-width:28ch}
  .nav-print{min-height:34px;height:34px;padding:0 13px;border:1px solid #c9c8c1;border-radius:3px;background:#fff;color:var(--ink);font-size:.75rem}.nav-print:hover{background:#f2f1eb;box-shadow:none}
  main{max-width:1536px;padding:10px 24px 42px}.fleet-masthead{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0 0 0 0);white-space:nowrap;border:0}
  .fleet-verdict{grid-template-columns:minmax(310px,1.75fr) repeat(3,minmax(135px,.8fr)) minmax(230px,1.05fr);min-height:78px;margin:0 0 9px;border-radius:5px;background:#fffdf8;box-shadow:none}.fleet-verdict-state,.fleet-verdict-fact{padding:10px 14px}.fleet-verdict-state{align-items:center;gap:11px}.fleet-verdict-state strong{font-size:1.04rem;margin:1px 0 2px}.fleet-verdict-state small,.fleet-verdict-fact small{font-size:.72rem}.fleet-verdict-fact strong{font-size:.88rem;margin:2px 0}
  .fleet-verdict-state>.state-dot{width:30px;height:30px;border-radius:50%;box-shadow:none;border:10px solid currentColor;background:#fff}.fleet-verdict.danger .fleet-verdict-state>.state-dot{color:var(--red)}.fleet-verdict.attention .fleet-verdict-state>.state-dot{color:var(--amber)}.fleet-verdict.good .fleet-verdict-state>.state-dot{color:var(--green)}
  .primary-action{align-self:center;min-height:38px;margin:10px 13px;padding:8px 12px;border:1px solid var(--blue);border-radius:3px;background:#fff;color:var(--blue);font-size:.76rem}.fleet-verdict.danger .primary-action{border-color:var(--red);color:var(--red)}.fleet-verdict.attention .primary-action{border-color:var(--amber);color:var(--amber)}.primary-action:hover{background:#f4f3ed}.primary-action:focus-visible,.lane:focus-visible{outline:2px solid var(--blue);outline-offset:2px}
  .panel{border-radius:5px;padding:12px;background:#fffdf8;border-color:#d8d7d0}.fleet-health-map{margin-bottom:9px}.map-head,.section-head{padding-bottom:8px;margin-bottom:8px}.map-head h2,.section-head h2{font-size:.84rem}.map-head p,.section-head p{margin-top:2px;font-size:.72rem}.map-legend{gap:10px;font-size:.66rem}.map-legend .state-dot{width:6px;height:6px;box-shadow:none}
  .estate-topology{grid-template-columns:minmax(155px,.62fr) minmax(0,3fr);gap:34px;min-height:104px;padding:10px 0 0}.estate-root{gap:8px;padding:8px 9px;border-radius:3px;background:#fff;border-color:#d4d3cc}.estate-root:after{width:35px}.estate-root strong{font-size:.76rem;text-transform:uppercase}.estate-root small{font-size:.66rem}.estate-root>b{min-width:23px;height:23px;border-radius:3px;font-size:.68rem}
  .fleet-lanes{gap:6px}.fleet-lanes:before{right:calc(100% + 17px)}.lane{grid-template-columns:auto auto minmax(0,1fr);gap:7px;min-height:58px;padding:7px 8px;border-radius:3px;background:#fff;border-color:#d4d3cc}.lane:before{width:18px}.lane b strong{font-size:.9rem}.lane b small{margin-top:3px;font-size:.64rem}.lane em{font-size:.66rem}.lane .state-dot{width:7px;height:7px;box-shadow:none}
  .fleet-layout{gap:9px}.fleet-layout>.panel{padding:12px}.count{min-width:30px;padding:3px 7px;border-radius:3px;font-size:.7rem}
  .ledger-toolbar{display:grid;grid-template-columns:minmax(250px,1.6fr) minmax(420px,2fr);gap:8px;align-items:end;margin:0 0 8px;padding:7px 8px;border:1px solid #deddd6;border-radius:3px;background:#f2f1eb}.ledger-toolbar .filter-toggle{display:none}.ledger-toolbar .filter-fields{grid-template-columns:repeat(3,minmax(110px,1fr)) auto;gap:6px}.ledger-toolbar label{margin-bottom:2px;color:var(--muted);font-size:.6rem}.ledger-toolbar input,.ledger-toolbar select{height:32px;border:1px solid #cbc9c0;border-radius:3px;background:#fff;color:var(--ink);font-size:.73rem}.ledger-toolbar button{min-height:32px;padding:5px 10px;border:1px solid #cbc9c0;border-radius:3px;background:#fff;font-size:.71rem}.ledger-toolbar button:hover{background:#ecebe5;box-shadow:none}
  .table-wrap{border-radius:3px;background:#fff}table{font-size:.73rem}th,td{padding:7px 9px}th{background:#f0eee5;font-size:.6rem;letter-spacing:.055em}.sort-button{min-height:auto;font-size:inherit}.cell-detail{margin-top:2px;font-size:.64rem}.details{font-size:.68rem}.posture,.signal{border-radius:2px;padding:2px 5px;font-size:.62rem}.posture{margin-top:4px}.signals{min-width:170px}.fleet-evidence{border-radius:4px;padding:12px;background:#202521}.fleet-evidence h2{font-size:.82rem}.evidence-meta div{border-radius:3px}.footer{margin-top:20px;padding:15px 18px;border-radius:4px}
  @media(max-width:1180px){.fleet-nav{grid-template-columns:auto 1fr auto}.nav-run-identity div:nth-child(2){display:none}.nav-run-identity{grid-template-columns:repeat(2,auto)}.fleet-verdict{grid-template-columns:minmax(280px,1.5fr) repeat(3,minmax(115px,1fr))}.primary-action{grid-column:1/-1;margin:8px 12px}.estate-topology{grid-template-columns:1fr;gap:8px}.fleet-lanes{grid-template-columns:repeat(5,minmax(145px,1fr));overflow-x:auto}.ledger-toolbar{grid-template-columns:1fr}}
  @media(max-width:820px){.fleet-nav{padding-inline:16px}.nav-run-identity{grid-template-columns:auto}.nav-run-identity div{padding-right:0}.nav-run-identity div:nth-child(2),.nav-run-identity div:nth-child(3){display:none}.fleet-verdict{grid-template-columns:repeat(3,minmax(0,1fr))}.fleet-verdict-state{grid-column:1/-1}.estate-topology{gap:6px;padding-top:5px}.fleet-lanes{grid-template-columns:repeat(3,minmax(0,1fr));overflow:visible}.fleet-lanes .lane:last-child{grid-column:2/3}.ledger-toolbar .filter-toggle{display:inline-flex}.ledger-toolbar .filter-fields{grid-template-columns:repeat(2,minmax(0,1fr))}.primary-action{min-height:44px}.ledger-toolbar input,.ledger-toolbar select{height:44px}.ledger-toolbar button,.filter-toggle,.sort-button{min-height:44px}#fleetTable{min-width:0}#fleetTable thead{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)}#fleetTable,#fleetTable tbody,#fleetTable tr,#fleetTable td{display:block;width:100%}#fleetTable tr{padding:8px 0;border-bottom:1px solid var(--line)}#fleetTable td{display:grid;grid-template-columns:104px minmax(0,1fr);gap:10px;padding:6px 5px;border:0;box-shadow:none;max-width:none}#fleetTable td:before{color:var(--muted);font-size:.67rem;font-weight:800;letter-spacing:.06em;text-transform:uppercase}#fleetTable td:nth-child(1):before{content:"Host"}#fleetTable td:nth-child(2):before{content:"Last report"}#fleetTable td:nth-child(3):before{content:"Scope"}#fleetTable td:nth-child(4):before{content:"Signals"}#fleetTable td:nth-child(5):before{content:"Outcome"}#fleetTable td:nth-child(6):before{content:"Reboot"}#fleetTable td:nth-child(7):before{content:"Notes"}#fleetTable td:nth-child(8):before{content:"More"}#fleetTable .signals{min-width:0}}
  @media(max-width:620px){body{font-size:13px}.fleet-nav{grid-template-columns:minmax(0,1fr) auto;min-height:50px;padding:6px max(12px,env(safe-area-inset-left))}.nav-brand>span{display:grid;gap:0}.nav-brand small,.nav-run-identity{display:none}.nav-brand .brand-mark{width:29px;height:29px}.nav-print{height:44px}.fleet-masthead{position:absolute}.fleet-verdict{grid-template-columns:1fr 1fr;margin-bottom:8px}.fleet-verdict-state{grid-column:1/-1}.fleet-verdict-state,.fleet-verdict-fact{padding:9px 11px}.fleet-verdict-fact:last-of-type{grid-column:1/-1}.fleet-verdict>.primary-action{grid-row:2;grid-column:1/-1;margin:8px 10px}.fleet-lanes{grid-template-columns:1fr 1fr;overflow:visible}.fleet-lanes .lane:last-child{grid-column:1/-1}.lane{grid-template-columns:auto minmax(0,1fr);min-height:50px}.lane em{grid-column:2}.panel{padding:11px}.ledger-toolbar{padding:6px}.ledger-toolbar .filter-fields{grid-template-columns:1fr 1fr}.table-wrap{border-radius:2px}#fleetTable td{grid-template-columns:92px minmax(0,1fr)}.fleet-evidence{padding:11px}.footer{padding-bottom:max(15px,env(safe-area-inset-bottom))}}
  @media(pointer:coarse){.primary-action,.nav-print,.ledger-toolbar input,.ledger-toolbar select,.ledger-toolbar button,.filter-toggle,.sort-button{min-height:44px}}
  @media print{body{font-size:10pt}.fleet-nav{display:none}.fleet-masthead{position:static;width:auto;height:auto;margin:0 0 10px;padding:0;overflow:visible;clip:auto;white-space:normal;border-bottom:1px solid #777}.fleet-masthead h1{font-size:17pt}.ledger-toolbar{display:none}.fleet-verdict,.panel,.table-wrap{border-radius:0;background:#fff}.fleet-lanes{overflow:visible}}
</style>
<noscript><style>.reveal{opacity:1;transform:none}details>:not(summary){display:block}.filter-toggle{display:none}.ledger-toolbar .filter-fields{display:grid !important}</style></noscript>
</head>
<body>
<!--
THESIS: Fleet posture is a connected evidence system; replace the generic hero and metric grid with a topology that exposes the riskiest path.
OWN-WORLD: Warm ivory evidence paper, white ledgers, fine charcoal rules, compact squared nodes, and sage/amber/red/blue states remain recognizable without copy.
STORY: The operator sees the estate verdict, selects a risk path, finds the highest-priority host, and opens its latest evidence.
FIRST VIEWPORT: A 52px evidence header and compact verdict rail lead into the estate root and five functional risk filters; the prioritized host ledger and report actions remain visible on desktop without decorative chrome.
FORM: Systems Health Map, position 7 in the ordered surface set, seed a79596f6.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
-->
<a class="skip-link" href="#fleetTable">Skip to host table</a>
<nav class="fleet-nav" aria-label="Fleet command bar">
  <div class="nav-brand brand-lockup">$brandMark<span><b class="brand-word">PatchManager Fleet</b><small>Patch. Verify. Prove it.</small></span></div>
  <dl class="fleet-run-identity nav-run-identity"><div><dt>Generated</dt><dd>$generatedAt</dd></div><div><dt>Source</dt><dd>$centralEsc</dd></div><div><dt>Stale after</dt><dd>$StaleDays day(s)</dd></div></dl>
  <button type="button" class="nav-print" id="printFleetReport">Print report</button>
</nav><main>
  <header class="fleet-masthead"><h1>Estate patch evidence</h1><p>$fleetVerdictCopy</p></header>  <section class="fleet-verdict $fleetTone" id="summary" aria-label="Fleet verdict">
    <div class="fleet-verdict-state"><span class="state-dot $fleetTone" aria-hidden="true"></span><div><span>Estate verdict</span><strong>$fleetVerdictTitle</strong><small>$attentionHosts of $totalHosts host(s) need review</small></div></div>
    <div class="fleet-verdict-fact"><span>Healthy</span><strong>$healthyHosts / $totalHosts</strong><small>Latest report per host</small></div>
    <div class="fleet-verdict-fact"><span>$securitySummaryLabel</span><strong>$securitySummaryValue</strong><small>Confirmed exposure pressure</small></div>
    <div class="fleet-verdict-fact"><span>Failed / deferred</span><strong>$hostsWithFail failed / $deferredHosts deferred</strong><small>Provider work needing follow-up</small></div>
    <a class="primary-action" href="#hosts">Open prioritized host queue<span aria-hidden="true">→</span></a>
  </section>
  <section class="panel fleet-health-map" id="risk" aria-labelledby="fleetMapTitle">
    <div class="map-head"><div><h2 id="fleetMapTitle">Estate health map</h2><p>Select a connected risk path to filter the host ledger. Select it again to clear.</p></div><div class="map-legend"><span><i class="state-dot danger"></i>Action</span><span><i class="state-dot attention"></i>Review</span><span><i class="state-dot good"></i>Verified</span></div></div>
    <div class="estate-topology">
      <div class="estate-root $fleetTone"><span class="state-dot $fleetTone" aria-hidden="true"></span><div><strong>$totalHosts host(s)</strong><small>$attentionHosts attention · $healthyHosts healthy</small></div><b>$attentionHosts</b></div>
      <div class="fleet-lanes" aria-label="Filter hosts by risk">
        <button type="button" class="lane $securityTone" data-risk-filter="security" aria-pressed="false"><span class="state-dot $securityTone"></span><b><strong>$securitySummaryValue</strong><small>Security</small></b><em>$securityLaneDetail</em></button>
        <button type="button" class="lane $executionTone" data-risk-filter="failure" aria-pressed="false"><span class="state-dot $executionTone"></span><b><strong>$hostsWithFail / $deferredHosts</strong><small>Execution</small></b><em>Failure · error · defer</em></button>
        <button type="button" class="lane $currencyTone" data-risk-filter="stale" aria-pressed="false"><span class="state-dot $currencyTone"></span><b><strong>$hostsWithStaleEvidence</strong><small>Currency</small></b><em>Old report · stale evidence</em></button>
        <button type="button" class="lane $lifecycleTone" data-risk-filter="eol" aria-pressed="false"><span class="state-dot $lifecycleTone"></span><b><strong>$hostsWithEol</strong><small>Lifecycle</small></b><em>End-of-life</em></button>
        <button type="button" class="lane $completionTone" data-risk-filter="reboot" aria-pressed="false"><span class="state-dot $completionTone"></span><b><strong>$hostsReboot</strong><small>Completion</small></b><em>Reboot pending</em></button>
      </div>
    </div>
  </section>
  <div class="fleet-layout">

    <section class="panel" id="hosts">
      <div class="section-head"><div><h2>Prioritized host ledger</h2><p>Security exposure first, then failed or deferred execution, then stale, lifecycle, and reboot evidence.</p></div><span class="count">$totalHosts total</span></div>
      <div class="fleet-toolbar ledger-toolbar" aria-label="Fleet controls">
        <div class="search-field"><label for="fleetSearch">Find a host</label><input id="fleetSearch" type="search" placeholder="Hostname, ring, profile, version, note"></div>
        <button type="button" class="filter-toggle" id="fleetFilterToggle" aria-expanded="true" aria-controls="fleetSecondaryFilters">Filters</button>
        <div class="filter-fields" id="fleetSecondaryFilters">
          <div><label for="postureFilter">Posture</label><select id="postureFilter"><option value="">All hosts</option><option value="healthy">Healthy</option><option value="review">Review</option><option value="stale">Stale</option><option value="attention">Attention</option></select></div>
          <div><label for="ringFilter">Ring</label><select id="ringFilter"><option value="">All rings</option></select></div>
          <div><label for="profileFilter">Profile</label><select id="profileFilter"><option value="">All profiles</option></select></div>
          <div><label>&nbsp;</label><button type="button" id="clearFleetFilters">Clear filters</button></div>
        </div>
      </div>
    <div class="table-wrap" tabindex="0" role="region" aria-label="Prioritized fleet hosts">
      <table id="fleetTable">
        <thead><tr><th scope="col" data-sort="host" aria-sort="none"><button class="sort-button" type="button">Host / priority</button></th><th scope="col" data-sort="last" aria-sort="none"><button class="sort-button" type="button">Last report</button></th><th scope="col" data-sort="ring" aria-sort="none"><button class="sort-button" type="button">Scope</button></th><th scope="col">Risk signals</th><th scope="col" data-sort="applied" aria-sort="none"><button class="sort-button" type="button">Outcome</button></th><th scope="col">Reboot</th><th scope="col">Notes</th><th scope="col">Details</th></tr></thead>
        <tbody>$tableRows</tbody>
      </table>
    </div>
    <div class="result-count" id="fleetResultCount" role="status" aria-live="polite"></div>
    </section>
    <aside class="fleet-evidence" id="provenance" aria-label="Fleet evidence">
      <h2>Evidence provenance</h2>
      <p class="scrub-copy"><span>Only each host's newest JSON report is counted.</span><span>Use the risk queue and filters to isolate the next action.</span><span>CSV columns remain unchanged for downstream ingestion.</span></p>
      <div class="evidence-meta"><div><span>Source</span><strong>$centralEsc</strong></div><div><span>Stale threshold</span><strong>${StaleDays} day(s)</strong></div><div><span>Generated</span><strong>$generatedAt</strong></div></div>
    </aside>
  </div>
  <div class="footer"><span class="footer-brand brand-lockup">$brandMark<span>Generated by Get-FleetReport.ps1 for <a href="https://github.com/ciaranwhiteside/PatchManager" target="_blank" rel="noopener">PatchManager</a>.</span></span><span>Rows use each host's most recent JSON report only; stale rows may hide newer local state.</span></div>
</main>
<script>
(function(){
  var rows = Array.prototype.slice.call(document.querySelectorAll('#fleetTable tbody tr.fleet-row'));
  var search = document.getElementById('fleetSearch');
  var postureFilter = document.getElementById('postureFilter');
  var ringFilter = document.getElementById('ringFilter');
  var profileFilter = document.getElementById('profileFilter');
  var clearFilters = document.getElementById('clearFleetFilters');
  var printReport = document.getElementById('printFleetReport');
  var resultCount = document.getElementById('fleetResultCount');
  var riskFilter = '';
  var riskLanes = Array.prototype.slice.call(document.querySelectorAll('[data-risk-filter]'));
  var filterToggle = document.getElementById('fleetFilterToggle');
  var secondaryFilters = document.getElementById('fleetSecondaryFilters');
  var numericSorts = ['riskrank','last','age','applied'];
  function appendOption(select, value){if(!select || !value){return;}var exists = Array.prototype.some.call(select.options,function(option){return option.value === value;});if(exists){return;}var option = document.createElement('option');option.value = value;option.textContent = value;select.appendChild(option);}
  rows.forEach(function(row){appendOption(ringFilter, row.getAttribute('data-ring') || '');appendOption(profileFilter, row.getAttribute('data-profile') || '');});
  Array.prototype.slice.call(ringFilter.options).slice(1).sort(function(a,b){return a.value.localeCompare(b.value);}).forEach(function(option){ringFilter.appendChild(option);});
  Array.prototype.slice.call(profileFilter.options).slice(1).sort(function(a,b){return a.value.localeCompare(b.value);}).forEach(function(option){profileFilter.appendChild(option);});
  function applyFilters(){var query = (search.value || '').toLowerCase();var posture = postureFilter.value;var ring = ringFilter.value;var profile = profileFilter.value;var visible = 0;rows.forEach(function(row){var rowText = (row.getAttribute('data-search') || '').toLowerCase();var risks = ' ' + (row.getAttribute('data-risk') || '') + ' ';var show = (!query || rowText.indexOf(query) !== -1) && (!posture || row.getAttribute('data-posture') === posture) && (!ring || row.getAttribute('data-ring') === ring) && (!profile || row.getAttribute('data-profile') === profile) && (!riskFilter || risks.indexOf(' ' + riskFilter + ' ') !== -1);row.hidden = !show;if(show){visible += 1;}});if(resultCount){resultCount.textContent = visible + ' of ' + rows.length + ' host row(s) visible' + (riskFilter ? ' for ' + riskFilter + ' risk' : '');}}
  function getSortValue(row, key){var value = row.getAttribute('data-' + key) || '';if(numericSorts.indexOf(key) !== -1){var number = parseFloat(value);return isNaN(number) ? -1 : number;}return value.toLowerCase();}
  document.querySelectorAll('#fleetTable th[data-sort]').forEach(function(th){var button = th.querySelector('button');if(!button){return;}button.addEventListener('click', function(){var key = th.getAttribute('data-sort');var tbody = th.closest('table').querySelector('tbody');var direction = th.getAttribute('aria-sort') === 'ascending' ? 'descending' : 'ascending';document.querySelectorAll('#fleetTable th[data-sort]').forEach(function(other){other.setAttribute('aria-sort','none');var otherButton=other.querySelector('button');if(otherButton){otherButton.removeAttribute('aria-label');}});th.setAttribute('aria-sort', direction);button.setAttribute('aria-label', button.textContent + ', sorted ' + direction);rows.sort(function(a,b){var av = getSortValue(a, key);var bv = getSortValue(b, key);if(typeof av === 'number' && typeof bv === 'number'){return direction === 'ascending' ? av - bv : bv - av;}return direction === 'ascending' ? av.localeCompare(bv, undefined, {numeric:true}) : bv.localeCompare(av, undefined, {numeric:true});});rows.forEach(function(row){tbody.appendChild(row);});applyFilters();});});
  [search,postureFilter,ringFilter,profileFilter].forEach(function(control){if(control){control.addEventListener('input', applyFilters);control.addEventListener('change', applyFilters);}});
  riskLanes.forEach(function(lane){lane.addEventListener('click',function(){var selected=lane.getAttribute('data-risk-filter');riskFilter=riskFilter===selected?'':selected;riskLanes.forEach(function(other){other.setAttribute('aria-pressed',String(other.getAttribute('data-risk-filter')===riskFilter));});applyFilters();document.getElementById('hosts').scrollIntoView({block:'start'});});});
  if(clearFilters){clearFilters.addEventListener('click', function(){search.value = '';postureFilter.value = '';ringFilter.value = '';profileFilter.value = '';riskFilter='';riskLanes.forEach(function(lane){lane.setAttribute('aria-pressed','false');});applyFilters();search.focus();});}
  if(filterToggle && secondaryFilters){var syncFilterDrawer=function(){var narrow=window.matchMedia('(max-width:980px)').matches;if(!narrow){secondaryFilters.classList.add('is-open');filterToggle.setAttribute('aria-expanded','true');}else if(!secondaryFilters.dataset.initialized){secondaryFilters.classList.remove('is-open');filterToggle.setAttribute('aria-expanded','false');secondaryFilters.dataset.initialized='true';}};filterToggle.addEventListener('click',function(){var open=!secondaryFilters.classList.contains('is-open');secondaryFilters.classList.toggle('is-open',open);filterToggle.setAttribute('aria-expanded',String(open));});window.addEventListener('resize',syncFilterDrawer);syncFilterDrawer();}
  if(printReport){printReport.addEventListener('click', function(){window.print();});}
  applyFilters();
})();
</script>
</body>
</html>
"@

Set-Content -Path $htmlPath -Value $html -Encoding UTF8

Write-Host ''
Write-Host "Fleet summary: $totalHosts host(s) | healthy: $healthyHosts | stale: $staleHosts | failures: $hostsWithFail | deferred: $deferredHosts | KEV: $hostsWithKev | SLA: $hostsWithSla | EOL: $hostsWithEol" -ForegroundColor Cyan
Write-Host "CSV : $csvPath" -ForegroundColor Green
Write-Host "HTML: $htmlPath" -ForegroundColor Green

if ($OpenReport) {
    Start-Process -FilePath $htmlPath | Out-Null
}
