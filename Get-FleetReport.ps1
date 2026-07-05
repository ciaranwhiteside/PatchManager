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
            SLABreaches     = $null
            Errors          = $null
            RebootRequired  = $null
            AttentionItems  = $null
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
            SLABreaches     = $null
            Errors          = $null
            RebootRequired  = $null
            AttentionItems  = $null
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
    $invKev   = @(Get-JsonProperty $report 'InventoryKEVMatches' @())

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
        SLABreaches     = [int](Get-JsonProperty $stats 'SLABreaches' 0)
        Errors          = $errors.Count
        RebootRequired  = $reboot.Count
        AttentionItems  = $attention.Count
        Note            = ''
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
$hostsWithKev  = @($hostRows | Where-Object { ($_.KEVMatches -gt 0) -or ($_.InventoryKEV -gt 0) }).Count
$hostsWithSla  = @($hostRows | Where-Object { $_.SLABreaches -gt 0 }).Count
$hostsReboot   = @($hostRows | Where-Object { $_.RebootRequired -gt 0 }).Count
$totalApplied  = ($hostRows | Measure-Object -Property Applied -Sum).Sum
$healthyHosts  = @($hostRows | Where-Object {
    -not $_.Stale -and $_.Failed -eq 0 -and $_.KEVMatches -eq 0 -and $_.InventoryKEV -eq 0 -and $_.SLABreaches -eq 0 -and $_.Errors -eq 0 -and $_.RebootRequired -eq 0
}).Count

$staleTone  = if ($staleHosts -gt 0) { 'danger' } else { 'good' }
$failTone   = if ($hostsWithFail -gt 0) { 'danger' } else { 'good' }
$securityTone = if ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) { 'danger' } else { 'good' }
$rebootTone = if ($hostsReboot -gt 0) { 'danger' } else { 'good' }
$attentionHosts = @($hostRows | Where-Object {
    $_.Stale -or $_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0 -or $_.RebootRequired -gt 0
}).Count
$fleetVerdictTitle = if ($attentionHosts -eq 0) {
    'Fleet reporting is current.'
} elseif ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) {
    'Fleet exposure needs action.'
} else {
    'Fleet needs review.'
}
$fleetVerdictCopy = if ($attentionHosts -eq 0) {
    'Every latest host report is fresh and free of failure, KEV, SLA, script error, and reboot signals.'
} elseif ($hostsWithKev -gt 0 -or $hostsWithSla -gt 0) {
    'Prioritise hosts with KEV, inventory KEV, and SLA pressure before treating the estate as current.'
} else {
    'Review stale hosts, failed runs, script errors, and reboot-required rows before closing the fleet view.'
}

$tableRows = ($hostRows | Sort-Object @{Expression='Stale';Descending=$true}, @{Expression='Failed';Descending=$true}, Hostname | ForEach-Object {
    $rowAttention = ($_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.InventoryKEV -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0 -or $_.RebootRequired -gt 0)
    $rowPosture = if ($_.Stale) { 'stale' } elseif ($rowAttention) { 'attention' } else { 'healthy' }
    $rowClass = if ($_.Stale) { 'stale' }
                elseif ($rowAttention) { 'attention' }
                else { 'ok' }
    $lastRunText = if ($_.LastRun) { $_.LastRun.ToString('dd MMM yyyy HH:mm') } else { 'never' }
    $lastRunSort = if ($_.LastRun) { ([datetime]$_.LastRun).Ticks } else { 0 }
    $ageSort = if ($null -ne $_.ReportAgeDays) { $_.ReportAgeDays } else { 999999 }
    $staleText = if ($_.Stale) { "STALE ($($_.ReportAgeDays)d)" } elseif ($null -ne $_.ReportAgeDays) { "$($_.ReportAgeDays)d ago" } else { '' }
    $noteText = if ($_.Note) { $_.Note } else { '-' }
    $searchText = "$(ConvertTo-FleetHtml $_.Hostname) $(ConvertTo-FleetHtml $_.Ring) $(ConvertTo-FleetHtml $_.ScopeProfile) $(ConvertTo-FleetHtml $_.Version) $(ConvertTo-FleetHtml $noteText)"
    "<tr class='fleet-row $rowClass' data-search='$searchText' data-posture='$rowPosture' data-ring='$(ConvertTo-FleetHtml $_.Ring)' data-profile='$(ConvertTo-FleetHtml $_.ScopeProfile)' data-host='$(ConvertTo-FleetHtml $_.Hostname)' data-last='$lastRunSort' data-age='$ageSort' data-version='$(ConvertTo-FleetHtml $_.Version)' data-applied='$(ConvertTo-FleetHtml $_.Applied)' data-failed='$(ConvertTo-FleetHtml $_.Failed)' data-kev='$(ConvertTo-FleetHtml $_.KEVMatches)' data-invkev='$(ConvertTo-FleetHtml $_.InventoryKEV)' data-sla='$(ConvertTo-FleetHtml $_.SLABreaches)' data-errors='$(ConvertTo-FleetHtml $_.Errors)' data-reboot='$(ConvertTo-FleetHtml $_.RebootRequired)'><td><strong>$(ConvertTo-FleetHtml $_.Hostname)</strong></td><td class='nowrap'>$(ConvertTo-FleetHtml $lastRunText)</td><td class='nowrap'>$(ConvertTo-FleetHtml $staleText)</td><td>$(ConvertTo-FleetHtml $_.Ring)</td><td>$(ConvertTo-FleetHtml $_.ScopeProfile)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Version)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Applied)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Failed)</td><td class='mono'>$(ConvertTo-FleetHtml $_.KEVMatches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.InventoryKEV)</td><td class='mono'>$(ConvertTo-FleetHtml $_.SLABreaches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Errors)</td><td class='mono'>$(ConvertTo-FleetHtml $_.RebootRequired)</td><td class='details'>$(ConvertTo-FleetHtml $noteText)</td></tr>"
}) -join "`n"

$generatedAt = ConvertTo-FleetHtml (Get-Date -Format 'dd MMM yyyy HH:mm:ss')
$centralEsc  = ConvertTo-FleetHtml $CentralReportPath
$brandMark = @'
<svg class="brand-mark" viewBox="0 0 64 64" aria-hidden="true" focusable="false"><rect width="64" height="64" rx="14" fill="#f6f2e8"/><path d="M32 7 53 15v15c0 14-8.5 22-21 28C19.5 52 11 44 11 30V15L32 7Z" fill="#111513"/><path d="M32 13 47 18.5V30c0 9.5-5.5 16.5-15 21.5C22.5 46.5 17 39.5 17 30V18.5L32 13Z" fill="#f6f2e8"/><path d="M24.5 23h11.5l6.5 6.5V47h-18V23Z" fill="#fff" stroke="#18324a" stroke-width="2.5" stroke-linejoin="round"/><path d="M36 23v7h6.5" fill="none" stroke="#18324a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M24 39 29.5 44.5 41 32.5" fill="none" stroke="#24744f" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
'@

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PatchManager fleet report</title>
<style>
  :root{--void:#070908;--paper:#f6f2e8;--paper-2:#ece6d8;--ink:#111513;--muted:#6d756f;--soft:#9ba69d;--line:rgba(17,21,19,.14);--line-strong:rgba(17,21,19,.28);--accent:#87d7b0;--accent-deep:#1f6b50;--green:#24744f;--green-bg:#e7f3e9;--red:#a53b35;--red-bg:#f7e4df;--amber:#9b6324;--amber-bg:#fff0d5;--steel:#365f72;--steel-bg:#e5eef1;--shadow:0 28px 80px rgba(0,0,0,.22)}
  *{box-sizing:border-box}
  html{scroll-behavior:smooth;background:var(--void)}
  body{margin:0;overflow-x:hidden;background:radial-gradient(circle at 78% 4%,rgba(135,215,176,.24),transparent 28rem),radial-gradient(circle at 4% 12%,rgba(255,240,213,.1),transparent 24rem),linear-gradient(180deg,#0b0e0d 0,#111612 42rem,#ebe5d7 42.1rem,#f6f2e8 100%);color:var(--ink);font:14px/1.55 "Segoe UI Variable Text","Aptos","Segoe UI",system-ui,-apple-system,sans-serif;font-variant-numeric:tabular-nums}
  body:before{content:"";position:fixed;inset:0;pointer-events:none;background-image:linear-gradient(rgba(255,255,255,.045) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.035) 1px,transparent 1px);background-size:34px 34px;mask-image:linear-gradient(to bottom,rgba(0,0,0,.75),transparent 52rem);z-index:-1}
  .skip-link{position:absolute;left:-999px;top:8px;background:#fff;color:#000;padding:8px 10px;border-radius:6px;z-index:20}.skip-link:focus{left:8px}
  .brand-lockup{display:inline-flex;align-items:center;gap:10px}.brand-mark{width:30px;height:30px;flex:0 0 auto}.brand-word{font-weight:820}.hero-brand{margin-bottom:14px;color:#f6f2e8;font-weight:780}.hero-brand .brand-mark{width:38px;height:38px}.footer-brand .brand-mark{width:24px;height:24px}
  .fleet-nav{position:sticky;top:0;z-index:12;display:grid;grid-template-columns:auto minmax(260px,1fr);gap:18px;align-items:start;max-width:1440px;margin:0 auto;padding:12px 32px;background:rgba(7,9,8,.68);backdrop-filter:blur(18px);border-bottom:1px solid rgba(255,255,255,.09);color:#fff}.nav-brand{font-weight:820;letter-spacing:0}.nav-links{display:flex;gap:8px;flex-wrap:wrap}.nav-links a{color:#dce5df;text-decoration:none;border:1px solid rgba(255,255,255,.12);border-radius:999px;padding:7px 10px;font-size:.82rem}.fleet-toolbar{display:grid;grid-template-columns:minmax(220px,1fr) 135px 135px 155px auto auto;gap:8px;align-items:end;grid-column:1/-1}
  label{display:block;color:#b6c4bc;font-size:.74rem;font-weight:760;letter-spacing:0;margin-bottom:4px}input,select,button{font:inherit}input,select{width:100%;height:38px;border:1px solid rgba(255,255,255,.18);border-radius:7px;background:rgba(255,255,255,.08);color:#fff;padding:0 10px;outline:none;transition:border-color .18s ease,box-shadow .18s ease,background .18s ease}select option{color:#101412;background:#fff}input::placeholder{color:#aab6af}input:focus,select:focus,button:focus-visible{outline:3px solid rgba(135,215,176,.24);border-color:var(--accent)}button{height:38px;border:1px solid rgba(255,255,255,.2);border-radius:7px;background:#f8f4ea;color:#111513;padding:0 13px;cursor:pointer;font-weight:760;transition:transform .18s ease,background .18s ease,border-color .18s ease,box-shadow .18s ease}button:hover{background:#fff;box-shadow:0 14px 35px rgba(0,0,0,.18)}button:active{transform:translateY(1px)}
  .hero{position:relative;color:#fff;min-height:560px;padding:72px 32px 84px;overflow:hidden}.hero:before{content:"";position:absolute;right:-7vw;bottom:36px;width:min(48vw,600px);height:min(48vw,600px);border-radius:42% 58% 48% 52%;background:radial-gradient(circle at 32% 24%,rgba(135,215,176,.72),transparent 0 14%,rgba(135,215,176,.18) 15% 28%,transparent 29%),linear-gradient(135deg,rgba(255,255,255,.12),rgba(255,255,255,.02));border:1px solid rgba(255,255,255,.12);box-shadow:0 50px 160px rgba(0,0,0,.45)}.hero-inner{position:relative;max-width:1440px;margin:0 auto;display:grid;grid-template-columns:minmax(0,1fr) minmax(280px,430px);gap:48px;align-items:end}.hero-copy{max-width:min(92vw,1080px)}.eyebrow{margin:0 0 8px;color:var(--soft);font-size:.76rem;font-weight:730;letter-spacing:0}.hero .eyebrow{color:#a8b9b1}h1,h2,p{margin-top:0}h1{font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;max-width:min(92vw,1080px);font-size:clamp(2.7rem,5.6vw,5.4rem);line-height:.9;margin:0 0 20px;font-weight:820;letter-spacing:0;text-wrap:balance}h2{font-size:1.15rem;line-height:1.15;margin:0 0 4px;font-weight:760;letter-spacing:0;text-wrap:balance}.hero-summary{max-width:64rem;color:#d2ddd7;font-size:1.08rem;margin:0;text-wrap:pretty}.hero-panel{align-self:stretch;display:grid;align-content:end;gap:14px}.hero-proof{border:1px solid rgba(255,255,255,.13);background:rgba(255,255,255,.055);border-radius:8px;padding:14px}.hero-proof span{display:block;color:#a8b9b1;font-size:.75rem;font-weight:700}.hero-proof strong{display:block;margin-top:4px;color:#fff;word-break:break-word}.hero-visual{min-height:180px;border:1px solid rgba(255,255,255,.11);border-radius:8px;background:linear-gradient(135deg,rgba(255,255,255,.12),rgba(255,255,255,.03));padding:16px;box-shadow:inset 0 1px 0 rgba(255,255,255,.1);overflow:hidden}
  .telemetry-strip{display:flex;align-items:end;gap:8px;height:80px}.telemetry-strip i{display:block;flex:1;min-width:16px;border-radius:999px;background:linear-gradient(180deg,rgba(135,215,176,.95),rgba(135,215,176,.12));transform-origin:bottom;animation:pulseBars 4.8s ease-in-out infinite}.telemetry-strip i:nth-child(1){height:34%;animation-delay:.1s}.telemetry-strip i:nth-child(2){height:72%;animation-delay:.4s}.telemetry-strip i:nth-child(3){height:48%;animation-delay:.2s}.telemetry-strip i:nth-child(4){height:92%;animation-delay:.6s}.telemetry-strip i:nth-child(5){height:58%;animation-delay:.3s}@keyframes pulseBars{0%,100%{transform:scaleY(.82);opacity:.65}50%{transform:scaleY(1);opacity:1}}
  main{max-width:1440px;margin:0 auto;padding:0 32px 56px;overflow-x:hidden}.fleet-bento{display:grid;grid-template-columns:repeat(12,1fr);grid-auto-flow:dense;grid-auto-rows:minmax(150px,auto);gap:12px;margin:44px 0 52px;position:relative;z-index:3}.bento-card{background:rgba(246,242,232,.96);border:1px solid rgba(255,255,255,.4);border-radius:8px;padding:20px;box-shadow:var(--shadow);transition:transform .35s ease,box-shadow .35s ease}.bento-card:hover{transform:translateY(-4px);box-shadow:0 32px 100px rgba(0,0,0,.27)}.bento-card strong{display:block;font-family:"Segoe UI Variable Display","Aptos Display","Segoe UI",system-ui,sans-serif;font-size:clamp(2rem,4vw,4.2rem);line-height:.92;margin:8px 0;color:var(--ink)}.bento-card p{margin:0;color:var(--muted);max-width:42rem}.bento-kicker{font-weight:780;color:var(--accent-deep)}.bento-primary{grid-column:span 5;grid-row:span 2}.bento-stale{grid-column:span 3;grid-row:span 2}.bento-fail{grid-column:span 4;grid-row:span 2}.bento-security,.bento-reboot,.bento-coverage{grid-column:span 4;grid-row:span 2}.bento-card.danger{background:linear-gradient(135deg,var(--red-bg),#fff6ef)}.bento-card.good{background:linear-gradient(135deg,var(--green-bg),#fffdf7)}
  .fleet-lanes{display:flex;gap:10px;margin-bottom:42px;min-height:180px}.lane{flex:1;display:flex;flex-direction:column;justify-content:flex-end;min-width:0;overflow:hidden;text-decoration:none;color:#fff;border-radius:8px;padding:18px;background:linear-gradient(145deg,#161c19,#0d100f);border:1px solid rgba(255,255,255,.1);transition:flex .45s ease,transform .35s ease}.lane:hover{flex:2.3;transform:translateY(-3px)}.lane span{color:#a8b9b1;font-weight:760}.lane strong{font-size:2.8rem;line-height:1}.lane p{margin:6px 0 0;color:#dce5df;max-width:28rem}.lane-wide{flex:1.6}
  .fleet-layout{display:grid;grid-template-columns:minmax(260px,360px) minmax(0,1fr);gap:22px;align-items:start}.fleet-evidence{position:sticky;top:128px;background:#101411;color:#fff;border:1px solid rgba(255,255,255,.1);border-radius:8px;padding:22px;box-shadow:0 24px 80px rgba(0,0,0,.26)}.fleet-evidence h2{margin-bottom:12px}.scrub-copy span{display:block;color:#dce5df;opacity:calc(.34 + (var(--scroll-progress,0) * .66));margin:10px 0}.evidence-meta{display:grid;gap:9px;margin-top:18px}.evidence-meta div{border:1px solid rgba(255,255,255,.12);border-radius:7px;padding:9px 10px}.evidence-meta span{display:block;color:#a8b9b1;font-size:.73rem;font-weight:760}.evidence-meta strong{display:block;color:#fff;word-break:break-word}.reveal{opacity:0;transform:translateY(28px);transition:opacity .7s ease,transform .7s ease}.reveal.is-visible{opacity:1;transform:translateY(0)}
  .panel{background:rgba(246,242,232,.98);border:1px solid var(--line);border-radius:8px;padding:22px;margin-bottom:18px;box-shadow:var(--shadow)}.section-head{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;border-bottom:1px solid var(--line);padding-bottom:14px;margin-bottom:14px}.count{display:inline-flex;min-width:36px;justify-content:center;border-radius:7px;padding:4px 9px;font-weight:820;background:#e6dfd0;color:#332f29}.result-count{color:var(--muted);font-size:.86rem;margin-top:10px}.table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px;background:#fffaf0;box-shadow:inset 0 1px 0 rgba(255,255,255,.78)}table{width:100%;border-collapse:separate;border-spacing:0;font-size:.89rem}th,td{padding:11px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}th{position:sticky;top:0;background:#eee7d8;color:#4a453c;font-size:.73rem;font-weight:820;letter-spacing:0;white-space:nowrap;user-select:none;box-shadow:0 1px 0 var(--line)}th[data-sort]{cursor:pointer}th[data-sort]:after{content:" sort";color:#8f8678;font-weight:700;letter-spacing:0;margin-left:4px}
  tbody tr:last-child td{border-bottom:none}
  tbody tr{transition:transform .2s ease,filter .2s ease}tbody tr:hover td{background:#fffdf8}tbody tr:hover{transform:translateX(3px)}
  tr.ok td{background:linear-gradient(90deg,var(--green-bg),#fffaf0 34%)}
  tr.attention td{background:linear-gradient(90deg,var(--red-bg),#fffaf0 34%)}
  tr.stale td{background:linear-gradient(90deg,var(--amber-bg),#fffaf0 34%)}
  .mono{font-family:"Cascadia Mono","Consolas",monospace;font-size:.84rem}
  .nowrap{white-space:nowrap}
  .details{color:var(--muted);font-size:.82rem;max-width:420px}
  .footer{margin-top:30px;padding:28px;border-radius:8px;background:#0d100f;color:#dce5df;display:flex;justify-content:space-between;gap:18px;align-items:center}.footer a{color:#fff;text-decoration-color:rgba(135,215,176,.65);text-underline-offset:3px}.footer a:hover{color:var(--accent)}
  @media (max-width:1180px){.fleet-bento{grid-template-columns:repeat(6,1fr)}.bento-primary,.bento-stale,.bento-fail,.bento-security,.bento-reboot,.bento-coverage{grid-column:span 3}.fleet-layout{grid-template-columns:1fr}.fleet-evidence{position:static}}@media (max-width:980px){.fleet-nav{grid-template-columns:1fr}.fleet-toolbar{grid-template-columns:1fr 1fr}.fleet-toolbar .search-field{grid-column:1/-1}.hero-inner{grid-template-columns:1fr}.hero-panel{max-width:620px}.fleet-lanes{display:grid;grid-template-columns:1fr 1fr}.lane:hover{flex:1;transform:none}}@media (max-width:620px){.fleet-nav,.hero,main{padding-left:18px;padding-right:18px}.fleet-toolbar,.fleet-lanes{grid-template-columns:1fr}.fleet-bento{grid-template-columns:1fr;margin-top:28px}.bento-primary,.bento-stale,.bento-fail,.bento-security,.bento-reboot,.bento-coverage{grid-column:span 1;grid-row:auto}h1{font-size:clamp(2.45rem,14vw,3.4rem)}.panel{padding:16px}.section-head{display:block}.count{margin-top:8px}.footer{display:block}.table-wrap{border-radius:7px}}@media print{body{background:#fff;color:#000}.fleet-nav,.hero:before,.hero-visual,.telemetry-strip,button,.skip-link{display:none}.hero{background:#fff;color:#000;min-height:auto;padding:18px 0;border-bottom:2px solid #000;box-shadow:none}.hero-summary,.hero-proof span{color:#333}.bento-card,.hero-proof,.panel,.fleet-evidence{box-shadow:none;background:#fff;color:#000}.fleet-bento,.fleet-layout{display:block}.fleet-lanes{display:none}main{padding:18px 0}.table-wrap{overflow:visible}.panel{break-inside:avoid}.reveal{opacity:1 !important;transform:none !important;transition:none !important}}
  @media (prefers-reduced-motion: reduce){html{scroll-behavior:auto}.reveal{opacity:1;transform:none;transition:none}}
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
    <div class="hero-panel"><div class="hero-visual"><div class="telemetry-strip" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div></div><div class="hero-proof"><span>Central source</span><strong>$centralEsc</strong></div><div class="hero-proof"><span>Generated</span><strong>$generatedAt</strong></div></div>
  </div>
</header>
<main>
  <section class="fleet-bento reveal" id="summary" aria-label="Fleet summary">
    <article class="bento-card bento-primary good"><span class="bento-kicker">Healthy hosts</span><strong>$healthyHosts</strong><p>$fleetVerdictCopy</p><div class="telemetry-strip" aria-hidden="true"><i></i><i></i><i></i><i></i><i></i></div></article>
    <article class="bento-card bento-stale $staleTone"><span class="bento-kicker">Stale hosts</span><strong>$staleHosts</strong><p>Hosts whose newest report is older than ${StaleDays} day(s), or folders without readable JSON.</p></article>
    <article class="bento-card bento-fail $failTone"><span class="bento-kicker">Failures</span><strong>$hostsWithFail</strong><p>Hosts with failed update activity in their latest imported run.</p></article>
    <article class="bento-card bento-security $securityTone"><span class="bento-kicker">KEV / SLA</span><strong>$hostsWithKev / $hostsWithSla</strong><p>Hosts with actionable KEV, inventory KEV, or SLA pressure.</p></article>
    <article class="bento-card bento-reboot $rebootTone"><span class="bento-kicker">Reboot pending</span><strong>$hostsReboot</strong><p>Latest host reports that include reboot-required evidence.</p></article>
    <article class="bento-card bento-coverage"><span class="bento-kicker">Latest-run coverage</span><strong>$totalApplied</strong><p>Updates applied across the newest JSON report per host.</p></article>
  </section>
  <section class="fleet-lanes reveal" id="risk" aria-label="Fleet risk lanes">
    <a href="#hosts" class="lane lane-wide"><span>Stale reporting</span><strong>$staleHosts</strong><p>Hosts that may be offline, misconfigured, or unable to write to the share.</p></a>
    <a href="#hosts" class="lane"><span>Failures</span><strong>$hostsWithFail</strong><p>Patch activity requiring operator follow-up.</p></a>
    <a href="#hosts" class="lane"><span>KEV / SLA</span><strong>$hostsWithKev / $hostsWithSla</strong><p>Security-driven priority lanes.</p></a>
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
        <thead><tr><th data-sort="host">Host</th><th data-sort="last">Last run</th><th data-sort="age">Age</th><th data-sort="ring">Ring</th><th data-sort="profile">Profile</th><th data-sort="version">Version</th><th data-sort="applied">Applied</th><th data-sort="failed">Failed</th><th data-sort="kev">KEV</th><th data-sort="invkev">Inv. KEV</th><th data-sort="sla">SLA</th><th data-sort="errors">Errors</th><th data-sort="reboot">Reboot</th><th>Notes</th></tr></thead>
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
  var rail = document.querySelector('.fleet-evidence');
  var revealItems = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
  var numericSorts = ['last','age','applied','failed','kev','invkev','sla','errors','reboot'];
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
  if('IntersectionObserver' in window){var observer = new IntersectionObserver(function(entries){entries.forEach(function(entry){if(entry.isIntersecting){entry.target.classList.add('is-visible');observer.unobserve(entry.target);}});},{threshold:.12});revealItems.forEach(function(item){observer.observe(item);});}else{revealItems.forEach(function(item){item.classList.add('is-visible');});}
  function updateScrollProgress(){if(!rail){return;}var total = Math.max(1, document.documentElement.scrollHeight - window.innerHeight);var progress = Math.min(1, Math.max(0, window.scrollY / total));rail.style.setProperty('--scroll-progress', progress.toFixed(3));}
  window.addEventListener('scroll', updateScrollProgress, {passive:true});
  updateScrollProgress();
  applyFilters();
})();
</script>
</body>
</html>
"@

Set-Content -Path $htmlPath -Value $html -Encoding UTF8

Write-Host ''
Write-Host "Fleet summary: $totalHosts host(s) | healthy: $healthyHosts | stale: $staleHosts | failures: $hostsWithFail | KEV: $hostsWithKev | SLA: $hostsWithSla" -ForegroundColor Cyan
Write-Host "CSV : $csvPath" -ForegroundColor Green
Write-Host "HTML: $htmlPath" -ForegroundColor Green

if ($OpenReport) {
    Start-Process -FilePath $htmlPath | Out-Null
}
