# Core/Encode.ps1
# Runs the two-pass ffmpeg encode described by a plan, reports progress, verifies the
# output size and retries pass 2 at a lower bitrate if the file came out too big.
#
# ffmpeg is launched with the plain call operator (&) so this also works under
# PowerShell's Constrained Language Mode, where the .NET Process class is unavailable.
# Two-pass stats files are written to the current directory, so each job runs inside
# its own temp folder on the local disk.

function Get-VideoFilterChain {
    param([Parameter(Mandatory = $true)]$Plan)
    $filters = @()
    if ($Plan.OutFps -gt 0) { $filters += ('fps=' + ([double]$Plan.OutFps).ToString([System.Globalization.CultureInfo]::InvariantCulture)) }
    if ($Plan.OutShortSide -gt 0) {
        if ($Plan.Portrait) { $filters += "scale=$($Plan.OutShortSide):-2" }
        else                { $filters += "scale=-2:$($Plan.OutShortSide)" }
    } else {
        # Keep size, but guarantee even dimensions (required for yuv420p).
        $filters += 'scale=trunc(iw/2)*2:trunc(ih/2)*2'
    }
    return ($filters -join ',')
}

function New-FFmpegArguments {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][int]$PassNumber,
        [Parameter(Mandatory = $true)][int]$VideoKbps,
        [string]$OutputPath
    )
    $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats',
           '-i', $Info.Path, '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn')
    $a += @('-vf', (Get-VideoFilterChain $Plan), '-pix_fmt', 'yuv420p', '-b:v', "${VideoKbps}k")

    if ($Plan.Codec -eq 'h264') {
        $a += @('-c:v', 'libx264', '-preset', $Plan.Preset, '-profile:v', 'high',
                '-pass', "$PassNumber", '-passlogfile', 'ffpass')
    } else {
        $a += @('-c:v', 'libx265', '-preset', $Plan.Preset, '-tag:v', 'hvc1',
                '-x265-params', "pass=${PassNumber}:log-level=error")
    }

    if ($PassNumber -eq 1) {
        $a += @('-an', '-f', 'null', (Get-NullDevice))
    } else {
        if ($Plan.AudioKbps -gt 0) {
            $a += @('-c:a', 'aac', '-b:a', "$($Plan.AudioKbps)k", '-ac', "$($Plan.AudioChannels)")
        } else {
            $a += '-an'
        }
        $a += @('-movflags', '+faststart', $OutputPath)
    }
    return $a
}

function Stop-ChildFFmpeg {
    # Kills ffmpeg processes started by this PowerShell process (used by Cancel).
    try {
        if (Test-IsWindows) {
            Get-CimInstance Win32_Process -Filter "ParentProcessId = $PID AND Name = 'ffmpeg.exe'" -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        } else {
            Get-Process -Name ffmpeg -ErrorAction SilentlyContinue |
                Where-Object { $_.Parent -and $_.Parent.Id -eq $PID } |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Invoke-FFmpegPass {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][double]$DurationSec,
        [Parameter(Mandatory = $true)][int]$PassNumber,
        [Parameter(Mandatory = $true)][string]$WorkingDir,
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )
    $ffmpeg = Get-FFmpegPath
    Write-Log ("pass $PassNumber`: ffmpeg " + (($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '))

    $passState = @{ Percent = 0.0; Speed = ''; Cancelled = $false; Errors = (New-Object System.Collections.Generic.List[string]) }
    $progressKeys = '^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|out_time|dup_frames|drop_frames|speed|progress)='

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'    # native stderr must not throw
    Push-Location -LiteralPath $WorkingDir
    try {
        & $ffmpeg @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -like 'out_time_us=*') {
                $us = 0.0
                if ([double]::TryParse($line.Substring(12), [ref]$us) -and $DurationSec -gt 0) {
                    $passState.Percent = [math]::Min(100.0, ($us / 1000000.0) / $DurationSec * 100.0)
                }
            } elseif ($line -like 'speed=*') {
                $passState.Speed = $line.Substring(6).Trim()
            } elseif ($line -like 'progress=*') {
                if ($line -eq 'progress=end') { $passState.Percent = 100.0 }
                if ($OnProgress) { & $OnProgress $passState.Percent $PassNumber $passState.Speed }
                if ($ShouldCancel -and -not $passState.Cancelled -and (& $ShouldCancel)) {
                    $passState.Cancelled = $true
                    Stop-ChildFFmpeg
                }
            } elseif ($line -notmatch $progressKeys -and $line.Trim() -ne '') {
                $passState.Errors.Add($line)
            }
        }
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $previousEap
    }

    $errText = ($passState.Errors | Select-Object -Last 15) -join "`n"
    if ($exit -ne 0 -and -not $passState.Cancelled) { Write-Log "pass $PassNumber exit code $exit`n$errText" }
    return [PSCustomObject]@{
        ExitCode  = $exit
        Cancelled = $passState.Cancelled
        ErrorText = $errText
    }
}

function Invoke-TwoPassEncode {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)]$Settings,
        [scriptblock]$OnProgress,     # called with (percent, passNumber, speedText)
        [scriptblock]$ShouldCancel    # returns $true to abort
    )
    $temp = New-JobTempDir
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $kbps = [int]$Plan.VideoKbps
    $attempts = 0
    $size = 0
    $status = 'Failed'
    Write-Log "Encoding '$($Info.Path)' -> '$OutputPath' ($(Format-PlanSummary -Info $Info -Plan $Plan))"

    try {
        $r = Invoke-FFmpegPass -Arguments (New-FFmpegArguments -Info $Info -Plan $Plan -PassNumber 1 -VideoKbps $kbps) `
                               -DurationSec $Info.DurationSec -PassNumber 1 -WorkingDir $temp `
                               -OnProgress $OnProgress -ShouldCancel $ShouldCancel
        if ($r.Cancelled) { $status = 'Cancelled' }
        elseif ($r.ExitCode -ne 0) { throw "ffmpeg analysis pass failed (exit code $($r.ExitCode)).`n$($r.ErrorText)" }

        if ($status -ne 'Cancelled') {
            $maxAttempts = 1 + [int]$Settings.maxRetries
            while ($true) {
                $attempts++
                $r = Invoke-FFmpegPass -Arguments (New-FFmpegArguments -Info $Info -Plan $Plan -PassNumber 2 -VideoKbps $kbps -OutputPath $OutputPath) `
                                       -DurationSec $Info.DurationSec -PassNumber 2 -WorkingDir $temp `
                                       -OnProgress $OnProgress -ShouldCancel $ShouldCancel
                if ($r.Cancelled) {
                    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
                    $status = 'Cancelled'; break
                }
                if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
                    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
                    throw "ffmpeg encode pass failed (exit code $($r.ExitCode)).`n$($r.ErrorText)"
                }
                $size = (Get-Item -LiteralPath $OutputPath).Length
                Write-Log "Attempt $attempts at $kbps kbps: $size bytes (limit $($Plan.LimitBytes))"
                if ($size -le $Plan.LimitBytes) { $status = 'Done'; break }
                if ($attempts -ge $maxAttempts) { $status = 'OverLimit'; break }
                $ratio = [double]$Plan.LimitBytes / [double]$size
                $kbps = [int][math]::Floor($kbps * $ratio * 0.97)
                if ($kbps -lt 50) { $kbps = 50 }
                Write-Log "Over the limit, re-running pass 2 at $kbps kbps"
            }
        }
    } finally {
        Remove-JobTempDir $temp
    }

    return [PSCustomObject]@{
        Status     = $status
        OutputPath = $OutputPath
        SizeBytes  = $size
        VideoKbps  = $kbps
        Attempts   = $attempts
        ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}
