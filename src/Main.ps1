<#
.SYNOPSIS
    Portable video compressor: shrinks videos under a size limit with two-pass HEVC/H.264.

.DESCRIPTION
    Entry point used by Compress-Videos.bat. Opens the window when it can
    (Windows, full-language PowerShell, WinForms available) and otherwise runs in
    the console with the defaults from settings.json. Nothing is installed; ffmpeg
    is read from the bin folder next to this script.

.PARAMETER Files
    Video files or folders to compress (the launcher passes dropped items here).
.PARAMETER NoGui
    Force console mode.
.PARAMETER TargetMB, Codec, Speed, Quality, Mode
    Override settings.json for this run (console mode). Quality is the HandBrake-style RF number
    (default 32, lower = better); Mode is 'quality' (default) or 'fill' (always use the full limit).
.PARAMETER NoPause
    Do not wait for Enter at the end of console mode.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Files,
    [switch]$NoGui,
    [double]$TargetMB = 0,
    [string]$Codec = '',
    [string]$Speed = '',
    [double]$Quality = 0,
    [string]$Mode = '',
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$coreDir = Join-Path $PSScriptRoot 'Core'
. (Join-Path $coreDir 'Paths.ps1')
. (Join-Path $coreDir 'Probe.ps1')
. (Join-Path $coreDir 'Plan.ps1')
. (Join-Path $coreDir 'Encode.ps1')

function Test-GuiAvailable {
    if (-not (Test-IsWindows)) { return $false }
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
        Write-Log "PowerShell language mode is $($ExecutionContext.SessionState.LanguageMode); using console mode."
        return $false
    }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        return $true
    } catch {
        Write-Log "Windows Forms not available ($($_.Exception.Message)); using console mode."
        return $false
    }
}

function Confirm-FFmpegInstalled {
    # One-step setup: if ffmpeg is not in bin\ yet, download it now (needs internet, once).
    try { Get-FFmpegPath | Out-Null; Get-FFprobePath | Out-Null; return $true } catch { }

    $downloader = Join-Path (Join-Path (Get-ToolRoot) 'tools') 'Get-FFmpeg.ps1'
    if (-not (Test-IsWindows) -or -not (Test-Path -LiteralPath $downloader)) { return $false }

    Write-Host ''
    Write-Host 'First run: ffmpeg is not in the "bin" folder yet, so it will be downloaded now (about 115 MB, once).' -ForegroundColor Cyan
    Write-Host 'Keep this window open. It only needs internet this one time.'
    Write-Log 'ffmpeg missing, running tools\Get-FFmpeg.ps1'
    # Child process: the downloader ends with `exit`, which must not end this script.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $downloader
    try { Get-FFmpegPath | Out-Null; Get-FFprobePath | Out-Null; return $true } catch { return $false }
}

function Invoke-ConsoleMode {
    param([string[]]$Files, $Settings)

    $limit = Get-LimitBytes $Settings
    Write-Host ''
    $how = "quality RF $($Settings.quality), fitted to the limit if needed"
    if ($Settings.mode -eq 'fill') { $how = 'using the full limit (two-pass)' }
    Write-Host "Video compressor  |  limit $(Format-Bytes $limit)  |  $(Get-CodecLabel $Settings.codec)  |  speed: $($Settings.speed)  |  $how" -ForegroundColor Cyan
    Write-Host ("ffmpeg: " + (Get-FFmpegPath))
    Write-Host ''

    if (-not $Files -or $Files.Count -eq 0) {
        Write-Host 'No videos given. Drop video files (or a folder of them) onto Compress-Videos.bat,'
        Write-Host 'or run:  Compress-Videos.bat "C:\path\to\video.mp4" "C:\another one.mov"'
        return 0
    }

    $failures = 0
    $index = 0
    foreach ($file in $Files) {
        $index++
        Write-Host "[$index/$($Files.Count)] $file" -ForegroundColor White
        try {
            $info = Get-VideoInfo -Path $file
            $plan = New-EncodePlan -Info $info -Settings $Settings
            Write-Host ('    source: {0}, {1}x{2}, {3}' -f (Format-Bytes $info.SizeBytes), $info.Width, $info.Height, (Format-Duration $info.DurationSec))
            Write-Host ('    plan:   ' + (Format-PlanSummary -Info $info -Plan $plan))
            foreach ($n in $plan.Notes) { Write-Host "            $n" -ForegroundColor DarkGray }
            if ($plan.Skip) { continue }

            $out = Get-OutputPath -InputPath $file -Settings $Settings
            $activity = "Compressing $($info.FileName)"
            $progress = {
                param($pct, $pass, $speed)
                $label = 'pass 1 of 2 (analysing)'
                if ($pass -eq 0) { $label = 'encoding at your quality setting' }
                if ($pass -eq 2) { $label = 'pass 2 of 2 (encoding)' }
                Write-Progress -Activity $activity -Status "$label  $([math]::Round($pct))%  $speed" -PercentComplete ([int]$pct)
            }.GetNewClosure()

            $result = Invoke-CompressVideo -Info $info -Plan $plan -OutputPath $out -Settings $Settings -OnProgress $progress
            Write-Progress -Activity $activity -Completed

            switch ($result.Status) {
                'Done'      {
                    $how = "fitted by two-pass at $($result.VideoKbps) kbps"
                    if ($result.Method -eq 'quality') { $how = "quality RF $($result.Crf)" }
                    Write-Host ('    done:   {0} ({1}) in {2}s -> {3}' -f (Format-Bytes $result.SizeBytes), $how, $result.ElapsedSec, $result.OutputPath) -ForegroundColor Green
                }
                'OverLimit' { Write-Host ('    WARNING: still {0} after {1} attempts -> {2}' -f (Format-Bytes $result.SizeBytes), $result.Attempts, $result.OutputPath) -ForegroundColor Yellow }
                default     { Write-Host "    $($result.Status)" -ForegroundColor Yellow }
            }
        } catch {
            $failures++
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "FAILED '$file': $($_.Exception.Message)"
        }
        Write-Host ''
    }
    Write-Host "Log: $(Get-LogPath)"
    return $failures
}

# ------------------------------------------------------------------ main

Initialize-Log | Out-Null
$settings = Get-Settings
if ($TargetMB -gt 0) { $settings.targetMB = $TargetMB }
if ($Codec)          { $settings.codec = $Codec }
if ($Speed)          { $settings.speed = $Speed }
if ($Quality -gt 0)  { $settings.quality = $Quality }
if ($Mode)           { $settings.mode = $Mode }

$inputs = Resolve-VideoInputs -Paths $Files
$exitCode = 0

try {
    if (-not (Confirm-FFmpegInstalled)) {
        Write-Host ''
        Write-Host 'ffmpeg is missing and could not be downloaded.' -ForegroundColor Red
        Write-Host 'On a computer with internet access, run this program once so it can download ffmpeg,'
        Write-Host 'then copy the whole folder (including "bin") to this computer or your flash drive.'
        Write-Host 'Or download Video-compressor-win64.zip from the GitHub Releases page, which already includes it.'
        $exitCode = 1
    } elseif (-not $NoGui -and (Test-GuiAvailable)) {
        . (Join-Path $PSScriptRoot 'Gui.ps1')
        Show-CompressorWindow -Files $inputs -Settings $settings
    } else {
        $exitCode = Invoke-ConsoleMode -Files $inputs -Settings $settings
        if (-not $NoPause -and (Test-IsWindows)) {
            Write-Host 'Press Enter to close.'
            Read-Host | Out-Null
        }
    }
} catch {
    Write-Log "Fatal: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Details: $(Get-LogPath)"
    $exitCode = 1
}

exit $exitCode
