#Requires -Version 5.1
<#
.SYNOPSIS
Build a verified public PatchManager release ZIP without running patch providers.
.PARAMETER OutputPath
New package destination. Defaults to release beside this script; existing artifacts are never overwritten.
#>
[CmdletBinding()]
param([string]$OutputPath = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$sourceRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $sourceRoot 'release' }
$source = Get-Content -LiteralPath (Join-Path $sourceRoot 'Invoke-PatchManager.ps1') -Raw
$versionMatch = [regex]::Match($source, "\`$script:VERSION\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
if (-not $versionMatch.Success) { throw 'Cannot resolve the release version.' }
$version = $versionMatch.Groups[1].Value
$notesPath = Join-Path $sourceRoot "docs/releases/$version.md"
if (-not (Test-Path -LiteralPath $notesPath -PathType Leaf)) { throw "Missing release notes: $notesPath" }
$files = @('Invoke-PatchManager.ps1', 'Get-FleetReport.ps1', 'PatchManager.config.example.json',
    'PatchManager.config.schema.json', 'README.md', 'CHANGELOG.md', 'LICENSE',
    'PSScriptAnalyzerSettings.psd1', 'Build-Release.ps1', '.gitignore', '.gitattributes')
foreach ($tree in @('docs', 'Tests', '.github')) {
    $files += @(Get-ChildItem -LiteralPath (Join-Path $sourceRoot $tree) -Recurse -File | ForEach-Object {
        $relative = $_.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        if ($relative -notlike 'docs/decks/*' -and $_.Extension -in @('.md', '.ps1', '.cjs', '.json', '.txt', '.yml', '.yaml', '.svg', '.png')) {
            $relative
        }
    })
}
$files = @($files | Sort-Object -Unique)
$manifest = [System.Collections.Generic.List[string]]::new()
foreach ($relative in $files) {
    $filePath = Join-Path $sourceRoot $relative
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { throw "Missing package input: $relative" }
    if ($relative -match '\.ps1$') {
        $parseTokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($filePath, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw "PowerShell parser failed for $relative" }
    }
    $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest.Add("$hash  $relative")
}
$outputRoot = [IO.Path]::GetFullPath($OutputPath)
[IO.Directory]::CreateDirectory($outputRoot) | Out-Null
$zipPath = Join-Path $outputRoot "PatchManager-v$version.zip"
$checksumPath = "$zipPath.sha256"
$releaseNotesPath = Join-Path $outputRoot "RELEASE_NOTES_v$version.md"
foreach ($artifact in @($zipPath, $checksumPath, $releaseNotesPath)) {
    if (Test-Path -LiteralPath $artifact) { throw "Refusing to overwrite release artifact: $artifact" }
}
$partialPath = "$zipPath.$([guid]::NewGuid().ToString('N')).partial"
try {
    $archive = [IO.Compression.ZipFile]::Open($partialPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @($files) + @('SHA256SUMS.txt')) {
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $stream = $entry.Open()
            try {
                $bytes = if ($relative -eq 'SHA256SUMS.txt') {
                    [Text.Encoding]::UTF8.GetBytes(($manifest -join "`n") + "`n")
                } else { [IO.File]::ReadAllBytes((Join-Path $sourceRoot $relative)) }
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    # Read back every payload; a changed source during packaging fails its hash.
    $archive = [IO.Compression.ZipFile]::OpenRead($partialPath)
    try {
        if ($archive.Entries.Count -ne ($files.Count + 1)) { throw 'Unexpected ZIP entry count.' }
        foreach ($line in $manifest) {
            $parts = $line -split '  ', 2
            $entry = $archive.GetEntry($parts[1])
            if ($null -eq $entry) { throw "Missing ZIP entry: $($parts[1])" }
            $stream = $entry.Open(); $algorithm = [Security.Cryptography.SHA256]::Create()
            try { $actual = [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $algorithm.Dispose(); $stream.Dispose() }
            if ($actual -cne $parts[0]) { throw "ZIP hash mismatch: $($parts[1])" }
        }
    } finally { $archive.Dispose() }
    [IO.File]::Move($partialPath, $zipPath)
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$zipHash  $([IO.Path]::GetFileName($zipPath))`r`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Copy($notesPath, $releaseNotesPath, $false)
    Write-Output "Verified $($files.Count) public files for v$version."
    Write-Output "ZIP: $zipPath"
    Write-Output "SHA256: $zipHash"
} finally {
    if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
}