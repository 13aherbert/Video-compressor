# Core/Plan.ps1
# Pure planning math: given a probed video and the settings, decide bitrate, audio,
# resolution and frame rate so the output lands under the size limit while looking
# as good as possible. No ffmpeg calls here, so it is fast and unit-testable.

# Shorter side of the frame (height for landscape, width for portrait), highest first.
$script:Ladder = @(2160, 1440, 1080, 720, 540, 480, 360)

# Bits per pixel per frame below which the picture starts to look bad.
# HEVC needs fewer bits than H.264 for the same quality.
$script:BppThreshold = @{ hevc = 0.035; h264 = 0.065 }

$script:PresetMap = @{
    fast     = 'fast'
    balanced = 'medium'
    best     = 'slow'
}

function ConvertTo-CodecId {
    param([string]$Codec)
    switch -Regex ("$Codec".ToLowerInvariant()) {
        '^(h\.?264|avc|x264)$' { return 'h264' }
        default                { return 'hevc' }
    }
}

function Get-CodecLabel {
    param([string]$Codec)
    if ((ConvertTo-CodecId $Codec) -eq 'h264') { return 'H.264' }
    return 'HEVC'
}

function Get-LimitBytes {
    param([Parameter(Mandatory = $true)]$Settings)
    return [long]([double]$Settings.targetMB * [double]$Settings.sizeUnitBytes)
}

function New-EncodePlan {
    param(
        [Parameter(Mandatory = $true)]$Info,
        [Parameter(Mandatory = $true)]$Settings
    )

    $codec = ConvertTo-CodecId $Settings.codec
    $speedKey = "$($Settings.speed)".ToLowerInvariant()
    if (-not $script:PresetMap.ContainsKey($speedKey)) { $speedKey = 'balanced' }
    $preset = $script:PresetMap[$speedKey]

    $limitBytes  = Get-LimitBytes $Settings
    $margin      = [double]$Settings.safetyMarginPercent / 100.0
    $budgetBytes = [long]($limitBytes * (1.0 - $margin))
    $budgetBits  = [double]$budgetBytes * 8.0
    $notes = New-Object System.Collections.Generic.List[string]

    $plan = [PSCustomObject]@{
        Codec          = $codec
        CodecLabel     = Get-CodecLabel $codec
        Preset         = $preset
        LimitBytes     = $limitBytes
        BudgetBytes    = $budgetBytes
        VideoKbps      = 0
        AudioKbps      = 0
        AudioChannels  = 0
        OutShortSide   = 0      # 0 = keep source size
        OutWidth       = $Info.Width
        OutHeight      = $Info.Height
        OutFps         = 0      # 0 = keep source frame rate
        Portrait       = ($Info.Height -gt $Info.Width)
        Bpp            = 0.0
        Grade          = ''
        EstimatedBytes = 0
        Skip           = $false
        SkipReason     = ''
        Notes          = $notes
    }

    if ($Info.DurationSec -le 0) {
        $plan.Skip = $true
        $plan.SkipReason = 'Could not determine the video length.'
        return $plan
    }

    if ([bool]$Settings.skipIfAlreadyUnderLimit -and $Info.SizeBytes -le $limitBytes) {
        $plan.Skip = $true
        $plan.SkipReason = 'Already under the limit (' + (Format-Bytes $Info.SizeBytes) + ')'
        return $plan
    }

    $duration = [double]$Info.DurationSec

    # ---- audio: take the smallest bite out of the budget that still sounds fine
    if ($Info.HasAudio) {
        $srcChannels = [int]$Info.AudioChannels
        if ($srcChannels -lt 1) { $srcChannels = 2 }
        $startKbps = [int]$Settings.audioKbps
        if ($startKbps -lt 32) { $startKbps = 32 }
        $startCh = [math]::Min(2, $srcChannels)
        if ($srcChannels -eq 1 -and $startKbps -gt 64) { $startKbps = 64 }
        $steps = @(
            @{ Kbps = $startKbps; Ch = $startCh },
            @{ Kbps = 64; Ch = 1 },
            @{ Kbps = 48; Ch = 1 },
            @{ Kbps = 32; Ch = 1 }
        )
        $chosen = $steps[0]
        foreach ($step in $steps) {
            $chosen = $step
            if (($step.Kbps * 1000.0 * $duration) -le (0.15 * $budgetBits)) { break }
        }
        $plan.AudioKbps = [int]$chosen.Kbps
        $plan.AudioChannels = [int]$chosen.Ch
        if ($plan.AudioKbps -lt $startKbps -or $plan.AudioChannels -lt $startCh) {
            $notes.Add("Audio reduced to $($plan.AudioKbps) kbps " + $(if ($plan.AudioChannels -eq 1) { 'mono' } else { 'stereo' }) + ' to leave room for video.')
        }
    } else {
        $notes.Add('No audio track.')
    }

    # ---- video bitrate from what is left
    $audioBits = $plan.AudioKbps * 1000.0 * $duration
    $videoBps = ($budgetBits - $audioBits) / $duration
    # Never pad the bitrate above what the budget allows; a very long video simply gets
    # a Poor grade and a note. 20 kbps is the practical floor the encoders accept.
    if ($videoBps -lt 20000) { $videoBps = 20000 }

    $capped = $false
    if ($Info.VideoBitrate -gt 0 -and $videoBps -gt $Info.VideoBitrate) {
        $videoBps = [double]$Info.VideoBitrate
        $capped = $true
        $notes.Add('Source bitrate is the cap; the file will not be inflated.')
    }

    # ---- resolution and frame-rate ladder
    $srcW = [int]$Info.Width; $srcH = [int]$Info.Height
    if ($srcW -le 0 -or $srcH -le 0) { $srcW = 1920; $srcH = 1080 }
    $srcShort = [math]::Min($srcW, $srcH)
    $srcLong  = [math]::Max($srcW, $srcH)
    $aspect   = [double]$srcLong / [double]$srcShort

    $fps = [double]$Info.Fps
    $fpsKnown = ($fps -gt 0)
    if (-not $fpsKnown) { $fps = 30.0 }

    $threshold = [double]$script:BppThreshold[$codec]
    $bppAt = {
        param([double]$short, [double]$frameRate)
        $long = $short * $aspect
        return $videoBps / ($short * $long * $frameRate)
    }

    $outShort = $srcShort
    $maxHeight = [int]$Settings.maxHeight
    if ($maxHeight -gt 0 -and $outShort -gt $maxHeight) {
        $outShort = $maxHeight
        $notes.Add("Limited to ${maxHeight}p by your settings.")
    }

    $outFps = $fps
    if ($fps -gt 32 -and (& $bppAt $outShort $fps) -lt $threshold) {
        $outFps = $fps / 2.0
        if ($outFps -gt 32) { $outFps = 30.0 }
        $outFps = [math]::Round($outFps, 3)
        $notes.Add("Frame rate reduced from $([math]::Round($fps, 2)) to $outFps fps.")
    }

    foreach ($rung in $script:Ladder) {
        if ((& $bppAt $outShort $outFps) -ge $threshold) { break }
        if ($rung -lt $outShort) { $outShort = $rung }
    }

    if ($outShort -lt $srcShort) {
        $plan.OutShortSide = $outShort
        $scaled = [int][math]::Round($outShort * $aspect / 2) * 2
        if ($plan.Portrait) { $plan.OutWidth = $outShort; $plan.OutHeight = $scaled }
        else                { $plan.OutWidth = $scaled;   $plan.OutHeight = $outShort }
        $notes.Add("Downscaled from ${srcW}x${srcH} to $($plan.OutWidth)x$($plan.OutHeight).")
    }
    if ($fpsKnown -and $outFps -lt $fps) { $plan.OutFps = $outFps }

    $plan.Bpp = [math]::Round((& $bppAt $outShort $outFps), 4)
    $plan.VideoKbps = [int][math]::Floor($videoBps / 1000.0)

    if ($plan.Bpp -ge $threshold)             { $plan.Grade = 'Good' }
    elseif ($plan.Bpp -ge ($threshold * 0.6)) { $plan.Grade = 'OK' }
    else                                      { $plan.Grade = 'Poor' }
    if ($plan.Grade -eq 'Poor') {
        $notes.Add('Very little data per frame: expect visible blockiness. Trim the video or raise the limit.')
    }

    $totalBps = ($plan.VideoKbps + $plan.AudioKbps) * 1000.0
    $est = [long]($totalBps * $duration / 8.0 * 1.01)
    if (-not $capped -and $est -gt $budgetBytes) { $est = $budgetBytes }
    $plan.EstimatedBytes = $est

    if ($Info.Is10Bit) { $notes.Add('10-bit source will be converted to standard 8-bit colour.') }

    return $plan
}

function Format-PlanSummary {
    param([Parameter(Mandatory = $true)]$Info, [Parameter(Mandatory = $true)]$Plan)
    if ($Plan.Skip) { return "Skipped: $($Plan.SkipReason)" }
    $srcFps = [math]::Round([double]$Info.Fps, 2)
    $outFps = $srcFps
    if ($Plan.OutFps -gt 0) { $outFps = $Plan.OutFps }
    $audio = 'no audio'
    if ($Plan.AudioKbps -gt 0) {
        $ch = 'stereo'; if ($Plan.AudioChannels -eq 1) { $ch = 'mono' }
        $audio = "AAC $($Plan.AudioKbps) kbps $ch"
    }
    return ('{0}x{1}@{2} -> {3}x{4}@{5}, {6} {7} kbps + {8}, est. {9}, quality: {10}' -f
        $Info.Width, $Info.Height, $srcFps, $Plan.OutWidth, $Plan.OutHeight, $outFps,
        $Plan.CodecLabel, $Plan.VideoKbps, $audio, (Format-Bytes $Plan.EstimatedBytes), $Plan.Grade)
}
