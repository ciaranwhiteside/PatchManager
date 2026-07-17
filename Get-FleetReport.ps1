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
    $errors   = @(Get-JsonProperty $stats 'Errors' @())
    $reboot   = @(Get-JsonProperty $report 'RebootRequiredItems' @())
    $attention = @(Get-JsonProperty $report 'AttentionItems' @())
    # Inventory KEV exposure = candidates NVD confirmed affected, or could not clear.
    # A 'NotAffected' candidate is evidence the check ran, not a reason to flag a host.
    # Reports written before exposure resolution existed have no ExposureState; those
    # are counted, matching the old (conservative) behaviour.
    $invKev   = @(@(Get-JsonProperty $report 'InventoryKEVMatches' @()) | Where-Object {
        ([string](Get-JsonProperty $_ 'ExposureState' 'Unknown')) -ne 'NotAffected'
    })
    # End-of-life exposure = findings needing action: out of support, nearing support,
    # or behind the latest patch of a still-supported release line.
    # 'info'/Supported findings are evidence, not exposure, so they are not counted.
    $eol      = @(Get-JsonProperty $report 'EndOfLifeFindings' @())
    $eolExposure = @($eol | Where-Object { [string]$_.Severity -eq 'review' }).Count
    # Staleness review items (stale Defender signatures, feature-update lag). Shown
    # per host for visibility but NOT part of the healthy/attention posture: these
    # thresholds are advisory, unlike a vendor-declared end-of-life boundary.
    $stalenessFindings = @(Get-JsonProperty $report 'StalenessFindings' @())
    $stalenessReview = @($stalenessFindings | Where-Object { [string]$_.Severity -eq 'review' }).Count

    $hostRows.Add([PSCustomObject]@{
        Hostname        = [string](Get-JsonProperty $metadata 'Hostname' $hostDir.Name)
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
$hostsWithSla  = @($hostRows | Where-Object { $_.SLABreaches -gt 0 }).Count
$hostsWithEol  = @($hostRows | Where-Object { $_.EolExposure -gt 0 }).Count
$hostsReboot   = @($hostRows | Where-Object { $_.RebootRequired -gt 0 }).Count
$totalApplied  = ($hostRows | Measure-Object -Property Applied -Sum).Sum
$healthyHosts  = @($hostRows | Where-Object {
    -not $_.Stale -and $_.ProvidersExecuted -and $_.Failed -eq 0 -and $_.KEVMatches -eq 0 -and $_.InventoryKEV -eq 0 -and $_.SLABreaches -eq 0 -and $_.Errors -eq 0 -and $_.RebootRequired -eq 0 -and (-not ($_.EolExposure -gt 0)) -and (-not ($_.NvdCritical -gt 0))
}).Count

$staleTone  = if ($staleHosts -gt 0) { 'danger' } else { 'good' }
$failTone   = if ($hostsWithFail -gt 0 -or $deferredHosts -gt 0) { 'danger' } else { 'good' }
$securityTone = if ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) { 'danger' } else { 'good' }
$eolTone    = if ($hostsWithEol -gt 0) { 'danger' } else { 'good' }
$rebootTone = if ($hostsReboot -gt 0) { 'danger' } else { 'good' }
$attentionHosts = @($hostRows | Where-Object {
    $_.Stale -or -not $_.ProvidersExecuted -or $_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0 -or $_.RebootRequired -gt 0 -or ($_.EolExposure -gt 0) -or ($_.NvdCritical -gt 0)
}).Count
$fleetVerdictTitle = if ($attentionHosts -eq 0) {
    'Fleet reporting is current.'
} elseif ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) {
    'Fleet exposure needs action.'
} else {
    'Fleet needs review.'
}
$fleetVerdictCopy = if ($attentionHosts -eq 0) {
    'Every latest host report is fresh and free of failure, KEV, SLA, end-of-life, script error, and reboot signals.'
} elseif ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) {
    'Prioritise hosts with KEV, inventory KEV, and SLA pressure before treating the estate as current.'
} else {
    'Review stale hosts, deferred provider runs, failures, end-of-life exposure, script errors, and reboot-required rows before closing the fleet view.'
}

$tableRows = ($hostRows | Sort-Object @{Expression='Stale';Descending=$true}, @{Expression='Failed';Descending=$true}, Hostname | ForEach-Object {
    $rowAttention = (-not $_.ProvidersExecuted -or $_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0 -or $_.RebootRequired -gt 0 -or ($_.EolExposure -gt 0) -or ($_.NvdCritical -gt 0))
    $rowPosture = if ($_.Stale) { 'stale' } elseif ($rowAttention) { 'attention' } else { 'healthy' }
    $rowClass = if ($_.Stale) { 'stale' }
                elseif ($rowAttention) { 'attention' }
                else { 'ok' }
    $lastRunText = if ($_.LastRun) { $_.LastRun.ToString('dd MMM yyyy HH:mm') } else { 'never' }
    $lastRunSort = if ($_.LastRun) { ([datetime]$_.LastRun).Ticks } else { 0 }
    $ageSort = if ($null -ne $_.ReportAgeDays) { $_.ReportAgeDays } else { 999999 }
    $staleText = if ($_.Stale) { "STALE ($($_.ReportAgeDays)d)" } elseif ($null -ne $_.ReportAgeDays) { "$($_.ReportAgeDays)d ago" } else { '' }
    $noteText = if ($_.Note) { $_.Note } else { '-' }
    # NVD cell: Critical count drives the posture; High shown alongside for context.
    $nvdCell = if (($_.NvdCritical -gt 0) -or ($_.NvdHigh -gt 0)) { "$($_.NvdCritical)C / $($_.NvdHigh)H" } else { '0' }
    $searchText = "$(ConvertTo-FleetHtml $_.Hostname) $(ConvertTo-FleetHtml $_.Ring) $(ConvertTo-FleetHtml $_.ScopeProfile) $(ConvertTo-FleetHtml $_.Version) $(ConvertTo-FleetHtml $noteText)"
    "<tr class='fleet-row $rowClass' data-search='$searchText' data-posture='$rowPosture' data-ring='$(ConvertTo-FleetHtml $_.Ring)' data-profile='$(ConvertTo-FleetHtml $_.ScopeProfile)' data-host='$(ConvertTo-FleetHtml $_.Hostname)' data-last='$lastRunSort' data-age='$ageSort' data-version='$(ConvertTo-FleetHtml $_.Version)' data-applied='$(ConvertTo-FleetHtml $_.Applied)' data-failed='$(ConvertTo-FleetHtml $_.Failed)' data-kev='$(ConvertTo-FleetHtml $_.KEVMatches)' data-invkev='$(ConvertTo-FleetHtml $_.InventoryKEV)' data-eol='$(ConvertTo-FleetHtml $_.EolExposure)' data-nvd='$(ConvertTo-FleetHtml $_.NvdCritical)' data-stalerev='$(ConvertTo-FleetHtml $_.StalenessReview)' data-sla='$(ConvertTo-FleetHtml $_.SLABreaches)' data-errors='$(ConvertTo-FleetHtml $_.Errors)' data-reboot='$(ConvertTo-FleetHtml $_.RebootRequired)'><td><strong>$(ConvertTo-FleetHtml $_.Hostname)</strong></td><td class='nowrap'>$(ConvertTo-FleetHtml $lastRunText)</td><td class='nowrap'>$(ConvertTo-FleetHtml $staleText)</td><td>$(ConvertTo-FleetHtml $_.Ring)</td><td>$(ConvertTo-FleetHtml $_.ScopeProfile)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Version)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Applied)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Failed)</td><td class='mono'>$(ConvertTo-FleetHtml $_.KEVMatches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.InventoryKEV)</td><td class='mono'>$(ConvertTo-FleetHtml $_.EolExposure)</td><td class='mono'>$(ConvertTo-FleetHtml $nvdCell)</td><td class='mono'>$(ConvertTo-FleetHtml $_.StalenessReview)</td><td class='mono'>$(ConvertTo-FleetHtml $_.SLABreaches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Errors)</td><td class='mono'>$(ConvertTo-FleetHtml $_.RebootRequired)</td><td class='details'>$(ConvertTo-FleetHtml $noteText)</td></tr>"
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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PatchManager fleet report</title>
<style>
  /* PatchManager evidence ledger - fleet view.
     Self-contained, print-safe, and aligned with docs/brand/BRAND.md. */
  :root{--charcoal:#111513;--charcoal-2:#1a201c;--paper:#f6f2e8;--paper-soft:#efe8d9;--card:#fcfaf3;--ink:#111513;--muted:#5f6a62;--line:#ddd5c2;--line-strong:#c8bfa6;--blue:#18324a;--blue-soft:#e8edf2;--green:#24744f;--green-bg:#e9f2ea;--red:#a53b35;--red-bg:#f7e6e1;--amber:#9b6324;--amber-curve:#c49a3d;--amber-bg:#faf0d8;--steel:#365f72;--steel-bg:#e6eef1;--card-shadow:0 1px 2px rgba(17,21,19,.05),0 10px 32px rgba(17,21,19,.07)}
  *{box-sizing:border-box}
  html{scroll-behavior:smooth;background:var(--paper)}
  body{margin:0;overflow-x:hidden;background:var(--paper);color:var(--ink);font:14px/1.55 "Segoe UI Variable Text","Aptos","Segoe UI",system-ui,-apple-system,sans-serif;font-variant-numeric:tabular-nums}
  .skip-link{position:absolute;left:-999px;top:8px;background:#fff;color:#000;padding:8px 10px;border-radius:6px;z-index:20}.skip-link:focus{left:8px}
  .brand-lockup{display:inline-flex;align-items:center;gap:10px}.brand-mark{width:30px;height:30px;flex:0 0 auto}.brand-word{font-weight:820}.hero-brand{margin-bottom:16px;color:#f6f2e8;font-weight:760}.hero-brand .brand-mark{width:34px;height:34px}.footer-brand .brand-mark{width:24px;height:24px}
  .fleet-nav{position:sticky;top:0;z-index:12;display:grid;grid-template-columns:auto minmax(260px,1fr);gap:18px;align-items:start;padding:12px 32px;background:rgba(17,21,19,.96);backdrop-filter:blur(14px);border-bottom:1px solid rgba(246,242,232,.12);color:#fff}.nav-brand{font-weight:820}.nav-links{display:flex;gap:8px;flex-wrap:wrap}.nav-links a{color:#cfd8d1;text-decoration:none;border:1px solid rgba(246,242,232,.16);border-radius:999px;padding:7px 11px;font-size:.82rem;transition:color .18s ease,border-color .18s ease,background .18s ease}.nav-links a:hover{color:#fff;border-color:rgba(246,242,232,.4);background:rgba(246,242,232,.07)}.fleet-toolbar{display:grid;grid-template-columns:minmax(220px,1fr) 135px 135px 155px auto auto;gap:8px;align-items:end;grid-column:1/-1}
  label{display:block;color:#a9b4ab;font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.07em;margin-bottom:4px}input,select,button{font:inherit}input,select{width:100%;height:38px;border:1px solid rgba(246,242,232,.22);border-radius:7px;background:rgba(246,242,232,.08);color:#fff;padding:0 10px;outline:none;transition:border-color .18s ease,box-shadow .18s ease,background .18s ease}select option{color:#111513;background:#fff}input::placeholder{color:#96a29a}input:focus,select:focus,button:focus-visible{outline:3px solid rgba(196,154,61,.35);border-color:var(--amber-curve)}button{height:38px;border:1px solid rgba(246,242,232,.25);border-radius:7px;background:var(--paper);color:var(--ink);padding:0 13px;cursor:pointer;font-weight:760;transition:transform .18s ease,background .18s ease,box-shadow .18s ease}button:hover{background:#fff;box-shadow:0 8px 22px rgba(0,0,0,.28)}button:active{transform:translateY(1px)}
  .hero{position:relative;color:#fff;padding:56px 32px 60px;background:linear-gradient(180deg,var(--charcoal-2),var(--charcoal));border-bottom:3px solid var(--amber-curve)}.hero-inner{position:relative;max-width:1440px;margin:0 auto;display:grid;grid-template-columns:minmax(0,1fr) minmax(280px,420px);gap:42px;align-items:end}.hero-copy{max-width:72rem}.eyebrow{margin:0 0 8px;color:var(--muted);font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.08em}.hero .eyebrow{color:#a9b4ab}h1,h2,p{margin-top:0}h1{font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(2.1rem,3.8vw,3.4rem);line-height:1.04;margin:0 0 14px;font-weight:800;text-wrap:balance}h2{font-size:1.12rem;line-height:1.2;margin:0 0 4px;font-weight:760;text-wrap:balance}.hero-summary{max-width:62rem;color:#c8d2ca;font-size:1.05rem;margin:0;text-wrap:pretty}.hero-panel{align-self:stretch;display:grid;align-content:end;gap:12px;padding:16px;border:1px solid rgba(246,242,232,.16);border-radius:8px;background:rgba(246,242,232,.05)}.hero-proof{border:1px solid rgba(246,242,232,.13);background:rgba(7,9,8,.35);border-radius:7px;padding:12px}.hero-proof span{display:block;color:#a9b4ab;font-size:.72rem;font-weight:720;text-transform:uppercase;letter-spacing:.06em}.hero-proof strong{display:block;margin-top:3px;color:#fff;word-break:break-word;line-height:1.3}
  main{max-width:1440px;margin:0 auto;padding:0 32px 56px;overflow-x:hidden}.fleet-bento{display:grid;grid-template-columns:repeat(12,1fr);grid-auto-flow:dense;gap:14px;margin:44px 0 52px}.bento-card{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--blue);border-radius:8px;padding:20px 20px 22px;box-shadow:var(--card-shadow);transition:box-shadow .25s ease,transform .25s ease}.bento-card:hover{box-shadow:0 2px 4px rgba(17,21,19,.06),0 18px 44px rgba(17,21,19,.12);transform:translateY(-2px)}.bento-card strong{display:block;font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(1.9rem,2.8vw,3rem);line-height:1;margin:10px 0 8px;color:var(--ink)}.bento-card p{margin:0;color:var(--muted);max-width:38rem;text-wrap:pretty}.bento-kicker{font-size:.72rem;font-weight:780;text-transform:uppercase;letter-spacing:.08em;color:var(--blue)}.bento-primary{grid-column:span 5}.bento-stale{grid-column:span 3}.bento-fail{grid-column:span 4}.bento-security,.bento-eol,.bento-reboot,.bento-coverage{grid-column:span 3}.bento-card.danger{border-left-color:var(--red)}.bento-card.danger .bento-kicker{color:var(--red)}.bento-card.good{border-left-color:var(--green)}.bento-card.good .bento-kicker{color:var(--green)}
  .fleet-lanes{display:grid;grid-template-columns:1.5fr 1fr 1fr 1fr 1fr;gap:14px;margin-bottom:48px}.lane{display:flex;flex-direction:column;justify-content:flex-end;min-width:0;text-decoration:none;color:#fff;border-radius:8px;padding:18px;min-height:132px;background:linear-gradient(150deg,var(--charcoal-2),var(--charcoal));border:1px solid rgba(246,242,232,.1);border-bottom:3px solid var(--amber-curve);transition:transform .22s ease,border-color .22s ease,box-shadow .22s ease}.lane:hover{transform:translateY(-2px);border-color:rgba(246,242,232,.28);box-shadow:0 16px 40px rgba(17,21,19,.28)}.lane span{color:#a9b4ab;font-size:.72rem;font-weight:760;text-transform:uppercase;letter-spacing:.08em}.lane strong{font-size:2.1rem;line-height:1.1;margin-top:6px}.lane p{margin:6px 0 0;color:#c8d2ca;font-size:.88rem;max-width:30rem;text-wrap:pretty}
  .fleet-layout{display:grid;grid-template-columns:minmax(260px,340px) minmax(0,1fr);gap:22px;align-items:start}.fleet-evidence{position:sticky;top:126px;background:var(--charcoal);color:#fff;border:1px solid rgba(246,242,232,.12);border-radius:8px;padding:22px;border-bottom:3px solid var(--amber-curve)}.fleet-evidence h2{margin-bottom:12px}.scrub-copy{margin:0}.scrub-copy span{display:block;color:#dce5df;margin:10px 0}.evidence-meta{display:grid;gap:9px;margin-top:18px}.evidence-meta div{border:1px solid rgba(246,242,232,.15);border-radius:7px;padding:9px 10px}.evidence-meta span{display:block;color:#a9b4ab;font-size:.72rem;font-weight:740;text-transform:uppercase;letter-spacing:.06em}.evidence-meta strong{display:block;color:#fff;word-break:break-word}.reveal{opacity:1;transform:none}
  .panel{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:22px;margin-bottom:18px;box-shadow:var(--card-shadow)}.section-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:14px}.count{display:inline-flex;min-width:36px;justify-content:center;border-radius:7px;padding:4px 9px;font-weight:820;background:#e7dfcc;color:#332f29}.count.good{background:var(--green-bg);color:var(--green)}.count.danger{background:var(--red-bg);color:var(--red)}.result-count{color:var(--muted);font-size:.86rem;margin-top:10px}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px;background:#fffdf6}table{width:100%;border-collapse:separate;border-spacing:0;font-size:.89rem}th,td{padding:11px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}th{position:sticky;top:0;background:#efe8d7;color:#4a453c;font-size:.71rem;font-weight:800;text-transform:uppercase;letter-spacing:.06em;white-space:nowrap;user-select:none;box-shadow:0 1px 0 var(--line)}th[data-sort]{cursor:pointer}th[data-sort]:hover{color:var(--ink)}th[data-sort]:after{content:" sort";color:#9a9081;font-weight:700;text-transform:none;letter-spacing:0;margin-left:4px}
  tbody tr:last-child td{border-bottom:none}
  tbody tr{transition:background .18s ease}tbody tr:hover td{background:#fdf9ee}
  tr.ok td{box-shadow:inset 3px 0 0 var(--green)}
  tr.attention td{box-shadow:inset 3px 0 0 var(--red)}
  tr.stale td{box-shadow:inset 3px 0 0 var(--amber-curve)}
  tr.ok td:not(:first-child),tr.attention td:not(:first-child),tr.stale td:not(:first-child){box-shadow:none}
  .mono{font-family:"Cascadia Mono","Consolas",monospace;font-size:.84rem}
  .nowrap{white-space:nowrap}
  .details{color:var(--muted);font-size:.82rem;max-width:420px}
  .footer{margin-top:34px;padding:26px 28px;border-radius:8px;background:var(--charcoal);color:#c8d2ca;display:flex;justify-content:space-between;gap:18px;align-items:center;border-bottom:3px solid var(--amber-curve)}.footer a{color:#fff;text-decoration-color:rgba(196,154,61,.7);text-underline-offset:3px}.footer a:hover{text-decoration-color:var(--amber-curve)}
  @media (max-width:1180px){.fleet-bento{grid-template-columns:repeat(6,1fr)}.bento-primary,.bento-stale,.bento-fail,.bento-security,.bento-eol,.bento-reboot,.bento-coverage{grid-column:span 3}.fleet-layout{grid-template-columns:1fr}.fleet-evidence{position:static}}@media (max-width:980px){.fleet-nav{grid-template-columns:1fr}.fleet-toolbar{grid-template-columns:1fr 1fr}.fleet-toolbar .search-field{grid-column:1/-1}.hero-inner{grid-template-columns:1fr}.hero-panel{max-width:620px}.fleet-lanes{grid-template-columns:1fr 1fr}}@media (max-width:620px){.fleet-nav,.hero,main{padding-left:18px;padding-right:18px}.fleet-toolbar,.fleet-lanes{grid-template-columns:1fr}.fleet-bento{grid-template-columns:1fr;margin-top:28px}.bento-primary,.bento-stale,.bento-fail,.bento-security,.bento-eol,.bento-reboot,.bento-coverage{grid-column:span 1}h1{font-size:clamp(1.9rem,9vw,2.6rem)}.panel{padding:16px}.section-head{display:block}.count{margin-top:8px}.footer{display:block}.table-wrap{border-radius:7px}}@media print{body{background:#fff;color:#000}.fleet-nav,button,.skip-link{display:none}.hero{background:#fff;color:#000;padding:18px 0;border-bottom:2px solid #000}.hero-summary,.hero-proof span{color:#333}.bento-card,.hero-panel,.hero-proof,.panel,.fleet-evidence{box-shadow:none;background:#fff;color:#000}.fleet-bento,.fleet-layout{display:block}.fleet-lanes{display:none}main{padding:18px 0}.table-wrap{overflow:visible}.panel{break-inside:avoid}.reveal{opacity:1 !important;transform:none !important;transition:none !important}}
  @media (prefers-reduced-motion: reduce){html{scroll-behavior:auto}*{transition:none !important}}
</style>
<noscript><style>.reveal{opacity:1;transform:none}</style></noscript>
</head>
<body>
<a class="skip-link" href="#fleetTable">Skip to host table</a>
<nav class="fleet-nav" aria-label="Fleet command bar">
  <div class="nav-brand brand-lockup">$brandMark<span class="brand-word">PatchManager Fleet</span></div>
  <div class="nav-links"><a href="#summary">Summary</a><a href="#risk">Risk lanes</a><a href="#hosts">Hosts</a><a href="#provenance">Provenance</a></div>
  <div class="fleet-toolbar" aria-label="Fleet controls">
    <div class="search-field"><label for="fleetSearch">Search hosts</label><input id="fleetSearch" type="search" placeholder="Hostname, ring, profile, version, note"></div>
    <div><label for="postureFilter">Posture</label><select id="postureFilter"><option value="">All hosts</option><option value="healthy">Healthy</option><option value="stale">Stale</option><option value="attention">Attention</option></select></div>
    <div><label for="ringFilter">Ring</label><select id="ringFilter"><option value="">All rings</option></select></div>
    <div><label for="profileFilter">Profile</label><select id="profileFilter"><option value="">All profiles</option></select></div>
    <div><label>&nbsp;</label><button type="button" id="clearFleetFilters">Clear</button></div>
    <div><label>&nbsp;</label><button type="button" id="printFleetReport">Print</button></div>
  </div>
</nav>
<header class="hero">
  <div class="hero-inner">
    <div class="hero-copy"><div class="hero-brand brand-lockup">$brandMark<span>Patch. Verify. Prove it.</span></div><p class="eyebrow">PatchManager fleet report</p><h1>$fleetVerdictTitle<br>$totalHosts host(s)</h1><p class="hero-summary">$fleetVerdictCopy</p></div>
    <div class="hero-panel"><div class="hero-proof"><span>Central source</span><strong>$centralEsc</strong></div><div class="hero-proof"><span>Generated</span><strong>$generatedAt</strong></div><div class="hero-proof"><span>Stale threshold</span><strong>$StaleDays day(s)</strong></div></div>
  </div>
</header>
<main>
  <section class="fleet-bento reveal" id="summary" aria-label="Fleet summary">
    <article class="bento-card bento-primary good"><span class="bento-kicker">Healthy hosts</span><strong>$healthyHosts</strong><p>$fleetVerdictCopy</p></article>
    <article class="bento-card bento-stale $staleTone"><span class="bento-kicker">Stale hosts</span><strong>$staleHosts</strong><p>Hosts whose newest report is older than ${StaleDays} day(s), or folders without readable JSON.</p></article>
    <article class="bento-card bento-fail $failTone"><span class="bento-kicker">Failures / deferred</span><strong>$hostsWithFail / $deferredHosts</strong><p>Hosts with failed update activity or a latest attempt that ended before providers ran.</p></article>
    <article class="bento-card bento-security $securityTone"><span class="bento-kicker">KEV / SLA</span><strong>$hostsWithKev / $hostsWithSla</strong><p>Hosts with actionable KEV, inventory KEV, or SLA pressure.</p></article>
    <article class="bento-card bento-eol $eolTone"><span class="bento-kicker">End-of-life</span><strong>$hostsWithEol</strong><p>Hosts running software past (or nearing) end-of-support, from endoflife.date. Plan major-version upgrades.</p></article>
    <article class="bento-card bento-reboot $rebootTone"><span class="bento-kicker">Reboot pending</span><strong>$hostsReboot</strong><p>Latest host reports that include reboot-required evidence.</p></article>
    <article class="bento-card bento-coverage"><span class="bento-kicker">Latest-run coverage</span><strong>$totalApplied</strong><p>Updates applied across the newest JSON report per host.</p></article>
  </section>
  <section class="fleet-lanes reveal" id="risk" aria-label="Fleet risk lanes">
    <a href="#hosts" class="lane lane-wide"><span>Stale reporting</span><strong>$staleHosts</strong><p>Hosts that may be offline, misconfigured, or unable to write to the share.</p></a>
    <a href="#hosts" class="lane"><span>Failures / deferred</span><strong>$hostsWithFail / $deferredHosts</strong><p>Patch activity or terminal attempts requiring operator follow-up.</p></a>
    <a href="#hosts" class="lane"><span>KEV / SLA</span><strong>$hostsWithKev / $hostsWithSla</strong><p>Security-driven priority lanes.</p></a>
    <a href="#hosts" class="lane"><span>End-of-life</span><strong>$hostsWithEol</strong><p>Hosts on out-of-support software.</p></a>
    <a href="#hosts" class="lane"><span>Reboot</span><strong>$hostsReboot</strong><p>Pending restart signals in latest runs.</p></a>
  </section>
  <div class="fleet-layout">
    <aside class="fleet-evidence" id="provenance" aria-label="Fleet evidence">
      <p class="eyebrow">Fleet evidence</p>
      <h2>$fleetVerdictTitle</h2>
      <p class="scrub-copy"><span>Only each host's newest JSON report is counted.</span><span>Use filters to isolate stale, risky, and ring-specific rows.</span><span>CSV output remains unchanged for downstream ingestion.</span></p>
      <div class="evidence-meta"><div><span>Source</span><strong>$centralEsc</strong></div><div><span>Stale threshold</span><strong>${StaleDays} day(s)</strong></div><div><span>Generated</span><strong>$generatedAt</strong></div></div>
    </aside>
    <section class="panel reveal" id="hosts">
      <div class="section-head"><div><p class="eyebrow">Host estate</p><h2>Latest report per host</h2></div><span class="count">$totalHosts total</span></div>
    <div class="table-wrap">
      <table id="fleetTable">
        <thead><tr><th data-sort="host">Host</th><th data-sort="last">Last run</th><th data-sort="age">Age</th><th data-sort="ring">Ring</th><th data-sort="profile">Profile</th><th data-sort="version">Version</th><th data-sort="applied">Applied</th><th data-sort="failed">Failed</th><th data-sort="kev">KEV</th><th data-sort="invkev">Inv. KEV</th><th data-sort="eol">EOL</th><th data-sort="nvd">NVD</th><th data-sort="stalerev">Staleness</th><th data-sort="sla">SLA</th><th data-sort="errors">Errors</th><th data-sort="reboot">Reboot</th><th>Notes</th></tr></thead>
        <tbody>$tableRows</tbody>
      </table>
    </div>
    <div class="result-count" id="fleetResultCount"></div>
  </section>
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
  var numericSorts = ['last','age','applied','failed','kev','invkev','eol','nvd','stalerev','sla','errors','reboot'];
  function appendOption(select, value){if(!select || !value){return;}var exists = Array.prototype.some.call(select.options,function(option){return option.value === value;});if(exists){return;}var option = document.createElement('option');option.value = value;option.textContent = value;select.appendChild(option);}
  rows.forEach(function(row){appendOption(ringFilter, row.getAttribute('data-ring') || '');appendOption(profileFilter, row.getAttribute('data-profile') || '');});
  Array.prototype.slice.call(ringFilter.options).slice(1).sort(function(a,b){return a.value.localeCompare(b.value);}).forEach(function(option){ringFilter.appendChild(option);});
  Array.prototype.slice.call(profileFilter.options).slice(1).sort(function(a,b){return a.value.localeCompare(b.value);}).forEach(function(option){profileFilter.appendChild(option);});
  function applyFilters(){var query = (search.value || '').toLowerCase();var posture = postureFilter.value;var ring = ringFilter.value;var profile = profileFilter.value;var visible = 0;rows.forEach(function(row){var rowText = (row.getAttribute('data-search') || '').toLowerCase();var show = (!query || rowText.indexOf(query) !== -1) && (!posture || row.getAttribute('data-posture') === posture) && (!ring || row.getAttribute('data-ring') === ring) && (!profile || row.getAttribute('data-profile') === profile);row.style.display = show ? '' : 'none';if(show){visible += 1;}});if(resultCount){resultCount.textContent = visible + ' of ' + rows.length + ' host row(s) visible';}}
  function getSortValue(row, key){var value = row.getAttribute('data-' + key) || '';if(numericSorts.indexOf(key) !== -1){var number = parseFloat(value);return isNaN(number) ? -1 : number;}return value.toLowerCase();}
  document.querySelectorAll('#fleetTable th[data-sort]').forEach(function(th){th.addEventListener('click', function(){var key = th.getAttribute('data-sort');var tbody = th.closest('table').querySelector('tbody');var direction = th.getAttribute('data-direction') === 'asc' ? 'desc' : 'asc';document.querySelectorAll('#fleetTable th[data-sort]').forEach(function(other){other.removeAttribute('data-direction');});th.setAttribute('data-direction', direction);rows.sort(function(a,b){var av = getSortValue(a, key);var bv = getSortValue(b, key);if(typeof av === 'number' && typeof bv === 'number'){return direction === 'asc' ? av - bv : bv - av;}return direction === 'asc' ? av.localeCompare(bv, undefined, {numeric:true}) : bv.localeCompare(av, undefined, {numeric:true});});rows.forEach(function(row){tbody.appendChild(row);});applyFilters();});});
  [search,postureFilter,ringFilter,profileFilter].forEach(function(control){if(control){control.addEventListener('input', applyFilters);control.addEventListener('change', applyFilters);}});
  if(clearFilters){clearFilters.addEventListener('click', function(){search.value = '';postureFilter.value = '';ringFilter.value = '';profileFilter.value = '';applyFilters();search.focus();});}
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
