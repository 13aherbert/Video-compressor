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

function Get-CrfValue {
    # HandBrake-style quality number. x264 needs a CRF about 6 lower than x265 for a similar look.
    param([Parameter(Mandatory = $true)]$Plan, [Parameter(Mandatory = $true)]$Settings)
    $q = [double]$Settings.quality
    if ($Plan.Codec -eq 'h264') { $q = [math]::Max(14.0, $q - 6.0) }
    return [math]::Round($q, 1)
}

function New-FFmpegArguments {
    # Two-pass bitrate mode: -PassNumber 1 or 2 with -VideoKbps.
    # Quality mode (single pass): -Crf <value>; -FileSizeLimit makes ffmpeg stop writing at that size.
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Plan,
        [int]$PassNumber = 0,
        [int]$VideoKbps = 0,
        [double]$Crf = 0,
        [long]$FileSizeLimit = 0,
        [string]$OutputPath
    )
    $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-progress', 'pipe:1', '-nostats',
           '-i', $Info.Path, '-map', '0:v:0', '-map', '0:a:0?', '-sn', '-dn')
    # -fps_mode cfr in every pass: without it pass 1 (null output, variable frame rate) and pass 2
    # (mp4, constant frame rate) can see different frame counts, and x264 then aborts with
    # "Incomplete MB-tree stats file". This happens with real files whose audio starts early.
    $a += @('-vf', (Get-VideoFilterChain $Plan), '-fps_mode', 'cfr', '-pix_fmt', 'yuv420p')

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Crf -gt 0) {
        $crfText = $Crf.ToString($inv)
        if ($Plan.Codec -eq 'h264') {
            $a += @('-c:v', 'libx264', '-preset', $Plan.Preset, '-profile:v', 'high', '-crf', $crfText)
        } else {
            $a += @('-c:v', 'libx265', '-preset', $Plan.Preset, '-tag:v', 'hvc1', '-crf', $crfText,
                    '-x265-params', 'log-level=error')
        }
    } else {
        $a += @('-b:v', "${VideoKbps}k")
        if ($Plan.Codec -eq 'h264') {
            $a += @('-c:v', 'libx264', '-preset', $Plan.Preset, '-profile:v', 'high',
                    '-pass', "$PassNumber", '-passlogfile', 'ffpass')
        } else {
            $a += @('-c:v', 'libx265', '-preset', $Plan.Preset, '-tag:v', 'hvc1',
                    '-x265-params', "pass=${PassNumber}:log-level=error")
        }
    }

    if ($Crf -le 0 -and $PassNumber -eq 1) {
        $a += @('-an', '-f', 'null', (Get-NullDevice))
    } else {
        if ($Plan.AudioKbps -gt 0) {
            $a += @('-c:a', 'aac', '-b:a', "$($Plan.AudioKbps)k", '-ac', "$($Plan.AudioChannels)")
        } else {
            $a += '-an'
        }
        if ($FileSizeLimit -gt 0) { $a += @('-fs', "$FileSizeLimit") }
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

    $passState = @{ Percent = 0.0; OutTimeSec = 0.0; Speed = ''; Cancelled = $false; Errors = (New-Object System.Collections.Generic.List[string]) }
    $progressKeys = '^(frame|fps|stream_\d+_\d+_q|bitrate|total_size|out_time_us|out_time_ms|out_time|dup_frames|drop_frames|speed|progress)='

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'    # native stderr must not throw
    Push-Location -LiteralPath $WorkingDir
    try {
        & $ffmpeg @Arguments 2>&1 | ForEach-Object {
            $line = "$_"
            if ($line -like 'out_time_us=*') {
                $us = 0.0
                if ([double]::TryParse($line.Substring(12), [System.Globalization.NumberStyles]::Float,
                                       [System.Globalization.CultureInfo]::InvariantCulture, [ref]$us) -and $DurationSec -gt 0) {
                    $passState.OutTimeSec = $us / 1000000.0
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
        ExitCode   = $exit
        Cancelled  = $passState.Cancelled
        OutTimeSec = $passState.OutTimeSec
        ErrorText  = $errText
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

function Invoke-QualityEncode {
    # Single-pass constant-quality encode (HandBrake "RF" style). ffmpeg is told to stop writing at
    # the size limit, so an attempt that cannot fit is cut short instead of running to the end.
    # Returns Fits = $true only if the whole video was encoded and the file is within the limit.
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)]$Settings,
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )
    $crf = Get-CrfValue -Plan $Plan -Settings $Settings
    $temp = New-JobTempDir
    $size = 0
    $fits = $false
    $cancelled = $false
    try {
        $arguments = New-FFmpegArguments -Info $Info -Plan $Plan -Crf $crf -FileSizeLimit $Plan.LimitBytes -OutputPath $OutputPath
        # Pass number 0 tells the progress callback this is the single quality pass.
        $r = Invoke-FFmpegPass -Arguments $arguments -DurationSec $Info.DurationSec -PassNumber 0 `
                               -WorkingDir $temp -OnProgress $OnProgress -ShouldCancel $ShouldCancel
        if ($r.Cancelled) {
            $cancelled = $true
        } elseif ($r.ExitCode -ne 0) {
            throw "ffmpeg quality encode failed (exit code $($r.ExitCode)).`n$($r.ErrorText)"
        } elseif (Test-Path -LiteralPath $OutputPath) {
            $size = (Get-Item -LiteralPath $OutputPath).Length
            $slack = [math]::Max(1.0, 0.02 * [double]$Info.DurationSec)
            $complete = ($r.OutTimeSec -ge ([double]$Info.DurationSec - $slack))
            $fits = ($complete -and $size -le $Plan.LimitBytes)
            Write-Log ("Quality attempt RF $crf`: $size bytes, encoded $([math]::Round($r.OutTimeSec, 1))s of " +
                       "$([math]::Round([double]$Info.DurationSec, 1))s, limit $($Plan.LimitBytes), fits=$fits")
        }
    } finally {
        Remove-JobTempDir $temp
        if (-not $fits) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
    }
    return [PSCustomObject]@{ Fits = $fits; Cancelled = $cancelled; SizeBytes = $size; Crf = $crf }
}

function Invoke-CompressVideo {
    # Entry point used by the window and the console: picks the path from Settings.mode.
    #   quality: try the HandBrake-style RF encode first; keep it if it fits, otherwise fall back to
    #            the two-pass encode at the bitrate that exactly fills the limit.
    #   fill:    always the two-pass encode.
    # The result is the same shape as Invoke-TwoPassEncode, plus Method ('quality' or 'twopass') and Crf.
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Plan,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)]$Settings,
        [scriptblock]$OnProgress,
        [scriptblock]$ShouldCancel
    )
    $crf = Get-CrfValue -Plan $Plan -Settings $Settings
    if ("$($Settings.mode)".ToLowerInvariant() -ne 'fill') {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Log "Encoding '$($Info.Path)' -> '$OutputPath' in quality mode (RF $crf), fallback: $(Format-PlanSummary -Info $Info -Plan $Plan)"
        $q = Invoke-QualityEncode -Info $Info -Plan $Plan -OutputPath $OutputPath -Settings $Settings `
                                  -OnProgress $OnProgress -ShouldCancel $ShouldCancel
        if ($q.Cancelled) {
            return [PSCustomObject]@{ Status = 'Cancelled'; OutputPath = $OutputPath; SizeBytes = 0; VideoKbps = 0
                                      Attempts = 1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Method = 'quality'; Crf = $crf }
        }
        if ($q.Fits) {
            return [PSCustomObject]@{ Status = 'Done'; OutputPath = $OutputPath; SizeBytes = $q.SizeBytes; VideoKbps = 0
                                      Attempts = 1; ElapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1); Method = 'quality'; Crf = $crf }
        }
        Write-Log "RF $crf does not fit the limit; falling back to two-pass at $($Plan.VideoKbps) kbps."
    }
    $result = Invoke-TwoPassEncode -Info $Info -Plan $Plan -OutputPath $OutputPath -Settings $Settings `
                                   -OnProgress $OnProgress -ShouldCancel $ShouldCancel
    $result | Add-Member -MemberType NoteProperty -Name Method -Value 'twopass' -Force
    $result | Add-Member -MemberType NoteProperty -Name Crf -Value $crf -Force
    return $result
}
