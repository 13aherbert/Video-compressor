<#
.SYNOPSIS
    Builds dist\Video-compressor-win64.zip: everything the flash drive needs, ffmpeg included.

.DESCRIPTION
    Downloads ffmpeg into bin\ if it is not there yet (tools\Get-FFmpeg.ps1), then zips the
    launcher, scripts, settings and binaries into one archive that extracts to a single
    "Video-compressor" folder. Used by the GitHub release workflow and usable by hand.
#>
[CmdletBinding()]
param([string]$OutDir = '')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

if (-not (Test-Path -LiteralPath (Join-Path $root 'bin\ffmpeg.exe')) -or -not (Test-Path -LiteralPath (Join-Path $root 'bin\ffprobe.exe'))) {
    & (Join-Path $PSScriptRoot 'Get-FFmpeg.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'ffmpeg download failed.' }
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) 'VideoCompressor-package'
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
$target = Join-Path $staging 'Video-compressor'
New-Item -ItemType Directory -Path $target -Force | Out-Null

foreach ($entry in @('Compress-Videos.bat', 'settings.json', 'README.md', 'LICENSE', 'src', 'tools', 'bin')) {
    $src = Join-Path $root $entry
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $target $entry) -Recurse -Force }
}
Remove-Item -LiteralPath (Join-Path $target 'bin\.gitkeep') -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $target 'logs') -Force | Out-Null

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$zip = Join-Path $OutDir 'Video-compressor-win64.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $target -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ("Built {0} ({1:N0} MB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1000000)) -ForegroundColor Green
