<#
.SYNOPSIS
    One-time setup: downloads a dependency-free Windows ffmpeg build into the bin folder.

.DESCRIPTION
    Run this once on a computer with internet access (your home PC), then copy the
    whole folder to the flash drive. The build is a plain .exe with no installer,
    no .NET and no registry use, so it runs on a locked-down work PC.

    Tries, in order: gyan.dev "release-essentials" (stable URL, ~115 MB), then the
    BtbN GitHub builds. Pass -Url to use a different zip.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Get-FFmpeg.ps1
#>
[CmdletBinding()]
param(
    [string]$Url = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path $root 'bin'
$ffmpegExe  = Join-Path $bin 'ffmpeg.exe'
$ffprobeExe = Join-Path $bin 'ffprobe.exe'

if (-not $Force -and (Test-Path -LiteralPath $ffmpegExe) -and (Test-Path -LiteralPath $ffprobeExe)) {
    Write-Host "ffmpeg.exe and ffprobe.exe are already in $bin (use -Force to re-download)."
    if ($env:OS -eq 'Windows_NT') { & $ffmpegExe -version | Select-Object -First 1 }
    exit 0
}

$candidates = @(
    'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
    'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-n9.0-latest-win64-gpl-9.0.zip',
    'https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip'
)
if ($Url) { $candidates = @($Url) }

# Windows PowerShell 5.1 defaults to old TLS; GitHub and gyan.dev need TLS 1.2.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes Invoke-WebRequest very slow on 5.1

$work = Join-Path ([System.IO.Path]::GetTempPath()) 'VideoCompressor-ffmpeg-download'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work 'ffmpeg.zip'

$downloaded = $false
foreach ($candidate in $candidates) {
    Write-Host "Downloading $candidate ..."
    try {
        Invoke-WebRequest -Uri $candidate -OutFile $zip -UseBasicParsing
        if ((Get-Item -LiteralPath $zip).Length -lt 10000000) { throw 'Download is too small to be an ffmpeg build.' }
        $downloaded = $true
        break
    } catch {
        Write-Warning "Failed: $($_.Exception.Message)"
    }
}
if (-not $downloaded) {
    Write-Error 'Could not download ffmpeg from any source. Check your internet connection, or download a Windows build manually and put ffmpeg.exe and ffprobe.exe into the bin folder.'
    exit 1
}

Write-Host 'Extracting ...'
$extract = Join-Path $work 'extract'
Expand-Archive -Path $zip -DestinationPath $extract -Force

$foundFfmpeg  = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'ffmpeg.exe'  | Select-Object -First 1
$foundFfprobe = Get-ChildItem -LiteralPath $extract -Recurse -Filter 'ffprobe.exe' | Select-Object -First 1
if (-not $foundFfmpeg -or -not $foundFfprobe) {
    Write-Error 'The archive did not contain ffmpeg.exe and ffprobe.exe.'
    exit 1
}

if (-not (Test-Path -LiteralPath $bin)) { New-Item -ItemType Directory -Path $bin -Force | Out-Null }
Copy-Item -LiteralPath $foundFfmpeg.FullName  -Destination $ffmpegExe  -Force
Copy-Item -LiteralPath $foundFfprobe.FullName -Destination $ffprobeExe -Force

# Keep the licence text next to the binaries (GPL build).
$licence = Get-ChildItem -LiteralPath $extract -Recurse -Include 'LICENSE*', 'COPYING*' -File | Select-Object -First 1
if ($licence) { Copy-Item -LiteralPath $licence.FullName -Destination (Join-Path $bin 'FFMPEG-LICENSE.txt') -Force }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Installed into $bin" -ForegroundColor Green
if ($env:OS -eq 'Windows_NT') {
    & $ffmpegExe -version | Select-Object -First 1
    $encoders = & $ffmpegExe -hide_banner -encoders 2>$null
    foreach ($needed in @('libx265', 'libx264', 'aac')) {
        if (-not ($encoders -match "\b$needed\b")) { Write-Warning "This build lacks the $needed encoder; choose a different download with -Url." }
    }
}
Write-Host 'Done. Copy the whole folder to your flash drive.'
