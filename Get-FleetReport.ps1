#Requires -Version 5.1

<#
.SYNOPSIS
    Fleet compliance dashboard for PatchManager v1.0.0.

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
    -not $_.Stale -and $_.Failed -eq 0 -and $_.KEVMatches -eq 0 -and $_.SLABreaches -eq 0 -and $_.Errors -eq 0
}).Count

$staleTone  = if ($staleHosts -gt 0) { 'danger' } else { 'good' }
$failTone   = if ($hostsWithFail -gt 0) { 'danger' } else { 'good' }
$kevTone    = if ($hostsWithKev -gt 0) { 'danger' } else { 'good' }
$slaTone    = if ($hostsWithSla -gt 0) { 'danger' } else { 'good' }
$rebootTone = if ($hostsReboot -gt 0) { 'danger' } else { 'good' }

$tableRows = ($hostRows | Sort-Object @{Expression='Stale';Descending=$true}, @{Expression='Failed';Descending=$true}, Hostname | ForEach-Object {
    $rowClass = if ($_.Stale) { 'stale' }
                elseif ($_.Failed -gt 0 -or $_.KEVMatches -gt 0 -or $_.SLABreaches -gt 0 -or $_.Errors -gt 0) { 'fail' }
                else { 'ok' }
    $lastRunText = if ($_.LastRun) { $_.LastRun.ToString('dd MMM yyyy HH:mm') } else { 'never' }
    $staleText = if ($_.Stale) { "STALE ($($_.ReportAgeDays)d)" } elseif ($null -ne $_.ReportAgeDays) { "$($_.ReportAgeDays)d ago" } else { '' }
    $noteText = if ($_.Note) { $_.Note } else { '-' }
    "<tr class='$rowClass'><td><strong>$(ConvertTo-FleetHtml $_.Hostname)</strong></td><td class='nowrap'>$(ConvertTo-FleetHtml $lastRunText)</td><td class='nowrap'>$(ConvertTo-FleetHtml $staleText)</td><td>$(ConvertTo-FleetHtml $_.Ring)</td><td>$(ConvertTo-FleetHtml $_.ScopeProfile)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Version)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Applied)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Failed)</td><td class='mono'>$(ConvertTo-FleetHtml $_.KEVMatches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.InventoryKEV)</td><td class='mono'>$(ConvertTo-FleetHtml $_.SLABreaches)</td><td class='mono'>$(ConvertTo-FleetHtml $_.Errors)</td><td class='mono'>$(ConvertTo-FleetHtml $_.RebootRequired)</td><td class='details'>$(ConvertTo-FleetHtml $noteText)</td></tr>"
}) -join "`n"

$generatedAt = ConvertTo-FleetHtml (Get-Date -Format 'dd MMM yyyy HH:mm:ss')
$centralEsc  = ConvertTo-FleetHtml $CentralReportPath

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PatchManager fleet report</title>
<style>
  :root{--bg:#eef1f4;--paper:#fbfcfd;--ink:#18212b;--muted:#667483;--line:#dce3ea;--charcoal:#202b36;--green:#237a57;--green-bg:#eaf6ef;--red:#b73a35;--red-bg:#fbebe9;--amber:#9a641d;--amber-bg:#fff4df;--shadow:0 18px 50px rgba(31,43,55,.12)}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.55 "Aptos","Segoe UI",system-ui,sans-serif;font-variant-numeric:tabular-nums}
  .hero{background:linear-gradient(135deg,var(--charcoal),#111820);color:#fff;padding:28px 32px}
  .hero-inner{max-width:1400px;margin:0 auto}
  .eyebrow{margin:0 0 8px;color:#9fb4c9;text-transform:uppercase;letter-spacing:.12em;font-size:.72rem;font-weight:700}
  h1{font-size:clamp(1.6rem,3vw,2.6rem);margin:0 0 8px;font-weight:750}
  .hero p{color:#c6d0da;margin:0}
  main{max-width:1400px;margin:0 auto;padding:24px 32px 34px}
  .stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:18px}
  .stat{background:var(--paper);border:1px solid var(--line);border-radius:8px;padding:15px 14px}
  .stat .n{font-size:2rem;line-height:1;font-weight:760;color:var(--charcoal)}
  .stat .l{margin-top:8px;color:var(--muted);font-size:.72rem;text-transform:uppercase;letter-spacing:.1em;font-weight:800}
  .stat.good .n{color:var(--green)}.stat.danger .n{color:var(--red)}
  .panel{background:var(--paper);border:1px solid var(--line);border-radius:8px;padding:20px;box-shadow:var(--shadow)}
  .table-wrap{overflow:auto;border:1px solid var(--line);border-radius:8px;background:#fff}
  table{width:100%;border-collapse:separate;border-spacing:0;font-size:.9rem}
  th,td{padding:10px 12px;text-align:left;border-bottom:1px solid var(--line);vertical-align:middle}
  th{position:sticky;top:0;background:#f6f8fa;color:#3c4956;font-size:.72rem;text-transform:uppercase;letter-spacing:.09em;font-weight:800;white-space:nowrap}
  tbody tr:last-child td{border-bottom:none}
  tr.ok td{background:linear-gradient(90deg,var(--green-bg),#fff 30%)}
  tr.fail td{background:linear-gradient(90deg,var(--red-bg),#fff 30%)}
  tr.stale td{background:linear-gradient(90deg,var(--amber-bg),#fff 30%)}
  .mono{font-family:"Cascadia Mono","Consolas",monospace;font-size:.84rem}
  .nowrap{white-space:nowrap}
  .details{color:var(--muted);font-size:.82rem;max-width:420px}
  .footer{color:#6d7b89;font-size:.8rem;margin-top:18px}
</style>
</head>
<body>
<header class="hero"><div class="hero-inner">
  <p class="eyebrow">PatchManager fleet report</p>
  <h1>$totalHosts host(s) reporting</h1>
  <p>Source: $centralEsc &middot; Stale threshold: ${StaleDays} day(s) &middot; Generated $generatedAt</p>
</div></header>
<main>
  <div class="stats">
    <div class="stat good"><div class="n">$healthyHosts</div><div class="l">Healthy hosts</div></div>
    <div class="stat $staleTone"><div class="n">$staleHosts</div><div class="l">Stale hosts</div></div>
    <div class="stat $failTone"><div class="n">$hostsWithFail</div><div class="l">Hosts with failures</div></div>
    <div class="stat $kevTone"><div class="n">$hostsWithKev</div><div class="l">Hosts with KEV</div></div>
    <div class="stat $slaTone"><div class="n">$hostsWithSla</div><div class="l">Hosts past SLA</div></div>
    <div class="stat $rebootTone"><div class="n">$hostsReboot</div><div class="l">Reboot pending</div></div>
    <div class="stat"><div class="n">$totalApplied</div><div class="l">Updates applied (latest runs)</div></div>
  </div>
  <section class="panel">
    <div class="table-wrap">
      <table>
        <thead><tr><th>Host</th><th>Last run</th><th>Age</th><th>Ring</th><th>Profile</th><th>Version</th><th>Applied</th><th>Failed</th><th>KEV</th><th>Inv. KEV</th><th>SLA</th><th>Errors</th><th>Reboot</th><th>Notes</th></tr></thead>
        <tbody>$tableRows</tbody>
      </table>
    </div>
  </section>
  <div class="footer">Generated by Get-FleetReport.ps1 (PatchManager). Rows use each host's most recent JSON report only; stale rows may hide newer local state.</div>
</main>
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
