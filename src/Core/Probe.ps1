# Core/Probe.ps1
# Reads a video file with ffprobe and returns a plain object with what the planner needs.

function Get-Prop {
    # Safe property read for ffprobe JSON (works under Set-StrictMode).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value }
    return $Default
}

function ConvertTo-Fps {
    # "30000/1001" -> 29.97, "30/1" -> 30, "0/0" -> 0
    param([string]$Ratio)
    if ([string]::IsNullOrWhiteSpace($Ratio)) { return 0.0 }
    $parts = $Ratio.Split('/')
    $num = [double]::Parse($parts[0], [System.Globalization.CultureInfo]::InvariantCulture)
    $den = 1.0
    if ($parts.Count -gt 1) { $den = [double]::Parse($parts[1], [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($den -le 0 -or $num -le 0) { return 0.0 }
    return [math]::Round($num / $den, 3)
}

function ConvertTo-Double {
    param($Value, [double]$Default = 0)
    if ($null -eq $Value -or "$Value" -eq '' -or "$Value" -eq 'N/A') { return $Default }
    $out = 0.0
    if ([double]::TryParse("$Value", [System.Globalization.NumberStyles]::Float,
                           [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) { return $out }
    return $Default
}

function Get-VideoInfo {
    param([Parameter(Mandatory = $true)][string]$Path)

    $ffprobe = Get-FFprobePath
    $probeArgs = @('-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', $Path)

    $ErrorActionPreference = 'Continue'   # stderr lines must not become terminating errors
    $raw = & $ffprobe @probeArgs 2>&1
    $exit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $text = (@($raw) | ForEach-Object { "$_" }) -join "`n"
    if ($exit -ne 0) { throw "ffprobe could not read '$Path': $text" }

    $json = $text | ConvertFrom-Json
    $streams = @(Get-Prop $json 'streams' @())
    $format = Get-Prop $json 'format'

    $video = $null
    foreach ($s in $streams) {
        if ((Get-Prop $s 'codec_type') -ne 'video') { continue }
        $disp = Get-Prop $s 'disposition'
        if ((ConvertTo-Double (Get-Prop $disp 'attached_pic' 0)) -eq 1) { continue }   # cover art, not video
        $video = $s; break
    }
    if ($null -eq $video) { throw "No video stream found in '$Path'." }

    $audio = $null
    foreach ($s in $streams) {
        if ((Get-Prop $s 'codec_type') -eq 'audio') { $audio = $s; break }
    }

    $duration = ConvertTo-Double (Get-Prop $format 'duration' 0)
    if ($duration -le 0) { $duration = ConvertTo-Double (Get-Prop $video 'duration' 0) }

    $fileSize = (Get-Item -LiteralPath $Path).Length
    $sizeBytes = [long](ConvertTo-Double (Get-Prop $format 'size' $fileSize))

    $width  = [int](ConvertTo-Double (Get-Prop $video 'width' 0))
    $height = [int](ConvertTo-Double (Get-Prop $video 'height' 0))

    # Rotation metadata (phones). ffmpeg auto-rotates on encode, so plan with displayed dimensions.
    $rotation = 0
    foreach ($sd in @(Get-Prop $video 'side_data_list' @())) {
        $r = Get-Prop $sd 'rotation'
        if ($null -ne $r) { $rotation = [int](ConvertTo-Double $r) }
    }
    $tagRotate = Get-Prop (Get-Prop $video 'tags') 'rotate'
    if ($null -ne $tagRotate) { $rotation = [int](ConvertTo-Double $tagRotate) }
    $rotated = (([math]::Abs($rotation) % 180) -eq 90)
    $displayWidth = $width; $displayHeight = $height
    if ($rotated) { $displayWidth = $height; $displayHeight = $width }

    $fps = ConvertTo-Fps (Get-Prop $video 'avg_frame_rate')
    if ($fps -le 0) { $fps = ConvertTo-Fps (Get-Prop $video 'r_frame_rate') }

    $audioBitrate = 0
    $audioChannels = 0
    $audioCodec = ''
    if ($null -ne $audio) {
        $audioBitrate  = [long](ConvertTo-Double (Get-Prop $audio 'bit_rate' 0))
        $audioChannels = [int](ConvertTo-Double (Get-Prop $audio 'channels' 2))
        $audioCodec    = [string](Get-Prop $audio 'codec_name' '')
    }

    $videoBitrate = [long](ConvertTo-Double (Get-Prop $video 'bit_rate' 0))
    if ($videoBitrate -le 0) {
        $formatBitrate = [long](ConvertTo-Double (Get-Prop $format 'bit_rate' 0))
        if ($formatBitrate -gt 0) { $videoBitrate = $formatBitrate - $audioBitrate }
        elseif ($duration -gt 0) { $videoBitrate = [long](($sizeBytes * 8 / $duration) - $audioBitrate) }
        if ($videoBitrate -lt 0) { $videoBitrate = 0 }
    }

    $pixFmt = [string](Get-Prop $video 'pix_fmt' '')

    return [PSCustomObject]@{
        Path          = $Path
        FileName      = [System.IO.Path]::GetFileName($Path)
        SizeBytes     = $sizeBytes
        DurationSec   = $duration
        Width         = $displayWidth
        Height        = $displayHeight
        Rotation      = $rotation
        Fps           = $fps
        VideoCodec    = [string](Get-Prop $video 'codec_name' '')
        VideoBitrate  = $videoBitrate
        PixFmt        = $pixFmt
        Is10Bit       = ($pixFmt -match '10|12|16')
        Container     = [string](Get-Prop $format 'format_name' '')
        HasAudio      = ($null -ne $audio)
        AudioCodec    = $audioCodec
        AudioChannels = $audioChannels
        AudioBitrate  = $audioBitrate
    }
}
