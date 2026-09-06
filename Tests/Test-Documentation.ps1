#Requires -Version 5.1
# Checks local documentation links and required release metadata without network access.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$docs = @(Get-ChildItem -LiteralPath $root -Filter '*.md' -File)
foreach ($tree in @('docs', '.github')) {
    $docs += @(Get-ChildItem -LiteralPath (Join-Path $root $tree) -Filter '*.md' -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]decks[\\/]' })
}
$linkCount = 0
foreach ($doc in $docs) {
    $content = Get-Content -LiteralPath $doc.FullName -Raw
    if ($content -match '[\x00-\x08\x0B\x0C\x0E-\x1F]') { throw "Control character in $($doc.Name)" }
    foreach ($match in [regex]::Matches($content, '\]\(([^\s)]+)(?:\s+"[^"]*")?\)')) {
        $link = $match.Groups[1].Value.Trim('<', '>')
        if ($link -match '^[a-zA-Z][a-zA-Z0-9+.-]*:|^#|^//') { continue }
        $relative = [uri]::UnescapeDataString(($link -split '[#?]', 2)[0])
        if (-not $relative) { continue }
        $target = Join-Path $doc.DirectoryName $relative
        if (-not (Test-Path -LiteralPath $target)) { throw "Broken local link in $($doc.Name): $link" }
        $linkCount++
    }
}
$script = Get-Content -LiteralPath (Join-Path $root 'Invoke-PatchManager.ps1') -Raw
$version = [regex]::Match($script, "\`$script:VERSION\s*=\s*'([^']+)'").Groups[1].Value
if (-not $version) { throw 'Missing runtime version.' }
foreach ($required in @('docs/RELEASING.md', "docs/releases/$version.md", 'Build-Release.ps1', 'Tests/Report.Usability.Tests.cjs')) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw "Missing release file: $required" }
}
$changelog = Get-Content -LiteralPath (Join-Path $root 'CHANGELOG.md') -Raw
if ($changelog -notmatch '(?m)^## \[Unreleased\]') { throw 'Changelog needs an Unreleased section.' }
$notes = Get-Content -LiteralPath (Join-Path $root "docs/releases/$version.md") -Raw
if ($notes -notmatch [regex]::Escape("PatchManager v$version")) { throw 'Release notes version mismatch.' }
Write-Output "Documentation checks passed: $($docs.Count) Markdown files, $linkCount local links, release $version."