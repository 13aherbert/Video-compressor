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
.PARAMETER OutputFolder, NameTemplate
    Override the output folder and file name templates for this run. Variables such as {source},
    {date}, {codec}, {quality}, {width}, {height} are replaced; a relative folder is relative to each
    original file. Example: -OutputFolder "Encoded\{date}" -NameTemplate "{source}_{height}p".
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
    [string]$OutputFolder = '',
    [string]$NameTemplate = '',
    [switch]$NoPause
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$coreDir = Join-Path $PSScriptRoot 'Core'
. (Join-Path $coreDir 'Paths.ps1')
. (Join-Path $coreDir 'Probe.ps1')
. (Join-Path $coreDir 'Plan.ps1')
. (Join-Path $coreDir 'Encode.ps1')
. (Join-Path $coreDir 'Eta.ps1')

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

    $batchTime = Get-Date    # {date} and {time} in the output names are the same for the whole batch
    $failures = 0

    # Step 1: read and plan every file first, so the length of the whole queue is known for the time estimate.
    $jobs = New-Object System.Collections.ArrayList
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
            if (-not $plan.Skip) {
                $preview = Resolve-OutputLocation -InputPath $file -Settings $Settings -Plan $plan -BatchTime $batchTime
                Assert-KnownTemplateVariables $preview
                Write-Host ('    output: ' + $preview.Path)
                [void]$jobs.Add(@{ File = $file; Info = $info; Plan = $plan })
            }
        } catch {
            $failures++
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
            Write-Log "FAILED '$file': $($_.Exception.Message)"
        }
    }

    if ($jobs.Count -gt 0) {
        # Step 2: compress, with elapsed time and an estimate for this file and for the queue.
        Write-Host ''
        Write-Host "Compressing $($jobs.Count) file(s)..." -ForegroundColor Cyan
        $durations = New-Object System.Collections.Generic.List[double]
        foreach ($job in $jobs) { $durations.Add([double]$job.Info.DurationSec) }
        $tracker = New-EtaTracker -Durations $durations.ToArray() -Mode "$($Settings.mode)"
        $position = 0
        foreach ($job in $jobs) {
            $position++
            $info = $job.Info
            Start-EtaFile -Tracker $tracker -Index ($position - 1)
            Write-Host "[$position/$($jobs.Count)] $($info.FileName)" -ForegroundColor White
            $learn = $false
            try {
                $out = Get-OutputPath -InputPath $job.File -Settings $Settings -Plan $job.Plan -BatchTime $batchTime
                $activity = "Compressing $($info.FileName)"
                $progress = New-ConsoleProgressCallback -Tracker $tracker -Activity $activity -Position $position -Total $jobs.Count
                $result = Invoke-CompressVideo -Info $info -Plan $job.Plan -OutputPath $out -Settings $Settings -OnProgress $progress
                Write-Progress -Activity $activity -Completed
                $learn = ($result.Status -eq 'Done')

                switch ($result.Status) {
                    'Done'      {
                        $how = "fitted by two-pass at $($result.VideoKbps) kbps"
                        if ($result.Method -eq 'quality') { $how = "quality RF $($result.Crf)" }
                        Write-Host ('    done:   {0} ({1}) in {2} -> {3}' -f (Format-Bytes $result.SizeBytes), $how, (Format-Clock $result.ElapsedSec), $result.OutputPath) -ForegroundColor Green
                    }
                    'OverLimit' { Write-Host ('    WARNING: still {0} after {1} attempts -> {2}' -f (Format-Bytes $result.SizeBytes), $result.Attempts, $result.OutputPath) -ForegroundColor Yellow }
                    default     { Write-Host "    $($result.Status)" -ForegroundColor Yellow }
                }
            } catch {
                $failures++
                Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "FAILED '$($job.File)': $($_.Exception.Message)"
            }
            Complete-EtaFile -Tracker $tracker -Learn:$learn
            Write-Host ''
        }
        $total = Get-EtaSnapshot -Tracker $tracker
        Write-Host ("Finished {0} file(s) in {1}." -f $jobs.Count, (Format-Clock $total.QueueElapsed)) -ForegroundColor Cyan
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
if ($PSBoundParameters.ContainsKey('OutputFolder')) { $settings.outputFolder = $OutputFolder }   # an empty value is allowed: same folder as the original
if ($NameTemplate)   { $settings.fileName = $NameTemplate }

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
