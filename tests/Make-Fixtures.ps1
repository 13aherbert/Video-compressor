# tests/Make-Fixtures.ps1
# Generates small synthetic videos (no downloads) used by Run-Tests.ps1.
# Needs ffmpeg in bin/ or on PATH. Existing fixtures are kept unless -Force.
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
. (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') (Join-Path 'Core' 'Paths.ps1'))

$ffmpeg = Get-FFmpegPath
$dir = Join-Path $PSScriptRoot 'fixtures'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

function New-Fixture {
    # Arguments are everything before the output file name; they are passed to ffmpeg as one array.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [Parameter(Mandatory = $true, Position = 1)][string[]]$Arguments
    )
    $path = Join-Path $dir $Name
    if (-not $Force -and (Test-Path -LiteralPath $path)) { Write-Host "exists  $Name"; return }
    Write-Host "making  $Name"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $log = & $ffmpeg -hide_banner -loglevel error -y @Arguments $path 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = $previous
    if ($exit -ne 0) {
        @($log) | ForEach-Object { Write-Host "  $_" }
        throw "ffmpeg failed for $Name"
    }
}

# Video settings shared by all fixtures: fast to make, high quality so there is something to compress.
function Get-VideoArgs { param([int]$Crf) return @('-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p', '-crf', "$Crf") }

# 1080p30 with audio, deliberately large.
New-Fixture 'clip 1080p30 (20s).mp4' (
    @('-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '20') +
    (Get-VideoArgs 10) + @('-c:a', 'aac', '-b:a', '128k'))

# Portrait phone-style clip with stereo audio.
New-Fixture 'portrait 1080x1920 10s.mp4' (
    @('-f', 'lavfi', '-i', 'testsrc2=size=1080x1920:rate=30', '-f', 'lavfi', '-i', 'sine=frequency=330:sample_rate=48000', '-t', '10') +
    (Get-VideoArgs 12) + @('-c:a', 'aac', '-b:a', '128k', '-ac', '2'))

# 60 fps screen-recording style clip, no audio.
New-Fixture 'silent 720p60 10s.mp4' (
    @('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=60', '-t', '10') + (Get-VideoArgs 12) + @('-an'))

# Tiny file that is already under any sensible limit.
New-Fixture 'tiny already small.mp4' (
    @('-f', 'lavfi', '-i', 'testsrc2=size=320x240:rate=15', '-t', '3') + (Get-VideoArgs 30) + @('-an'))

# Heavy-noise clip: cannot fit a small limit at normal quality, so it forces the two-pass fallback.
New-Fixture 'noisy 720p 8s.mp4' (
    @('-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30,noise=alls=60:allf=t', '-t', '8') + (Get-VideoArgs 14) + @('-an'))

# Awkward file name, below 720p, Matroska container, MP3 audio.
New-Fixture "tést vidéo [1] 'quote' & co.mkv" (
    @('-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=25', '-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=44100', '-t', '5') +
    (Get-VideoArgs 8) + @('-c:a', 'libmp3lame', '-b:a', '128k'))

Write-Host 'Fixtures ready.'
