# tests/Run-Tests.ps1
# Unit checks for the planner plus end-to-end encodes against the synthetic fixtures.
# Usage:  pwsh tests/Run-Tests.ps1            (full)
#         pwsh tests/Run-Tests.ps1 -SkipEncode (planner only, no ffmpeg encodes)
[CmdletBinding()]
param([switch]$SkipEncode)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$srcCore = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'Core'
. (Join-Path $srcCore 'Paths.ps1')
. (Join-Path $srcCore 'Probe.ps1')
. (Join-Path $srcCore 'Plan.ps1')
. (Join-Path $srcCore 'Encode.ps1')

$script:Pass = 0
$script:Fail = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Pass++; Write-Host "  ok    $Message" -ForegroundColor Green }
    else            { $script:Fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

function New-TestSettings {
    param([hashtable]$Overrides = @{})
    $d = Get-DefaultSettings
    $o = New-Object PSObject
    foreach ($k in $d.Keys) { $o | Add-Member -MemberType NoteProperty -Name $k -Value $d[$k] }
    foreach ($k in $Overrides.Keys) { $o.$k = $Overrides[$k] }
    return $o
}

function New-FakeInfo {
    param([int]$W = 1920, [int]$H = 1080, [double]$Fps = 30, [double]$Duration = 60, [long]$Size = 500000000,
          [long]$VideoBitrate = 0, [bool]$HasAudio = $true, [int]$Channels = 2, [bool]$Is10Bit = $false)
    if ($VideoBitrate -le 0 -and $Duration -gt 0) { $VideoBitrate = [long]($Size * 8 / $Duration) }
    return [PSCustomObject]@{
        Path = 'fake.mp4'; FileName = 'fake.mp4'; SizeBytes = $Size; DurationSec = $Duration
        Width = $W; Height = $H; Rotation = 0; Fps = $Fps; VideoCodec = 'h264'; VideoBitrate = $VideoBitrate
        PixFmt = 'yuv420p'; Is10Bit = $Is10Bit; Container = 'mov,mp4'; HasAudio = $HasAudio
        AudioCodec = 'aac'; AudioChannels = $Channels; AudioBitrate = 128000
    }
}

Write-Host "`n== Planner unit tests" -ForegroundColor Cyan
$s = New-TestSettings

Write-Host 'short 1080p clip keeps its resolution'
$p = New-EncodePlan -Info (New-FakeInfo -Duration 60) -Settings $s
Assert-True (-not $p.Skip) 'not skipped'
Assert-True ($p.OutShortSide -eq 0 -and $p.OutHeight -eq 1080) 'stays 1080p'
Assert-True ($p.OutFps -eq 0) 'keeps frame rate'
Assert-True ($p.VideoKbps -ge 4900 -and $p.VideoKbps -le 5200) "video bitrate ~5000 kbps (got $($p.VideoKbps))"
Assert-True ($p.AudioKbps -eq 96 -and $p.AudioChannels -eq 2) 'audio 96 kbps stereo'
Assert-True ($p.Grade -eq 'Good') "grade Good (got $($p.Grade))"
Assert-True ($p.EstimatedBytes -le $p.LimitBytes) 'estimate under the limit'
Assert-True ($p.Codec -eq 'hevc' -and $p.Preset -eq 'medium') 'hevc / medium by default'

Write-Host '20-minute 1080p60 goes to 30 fps and a lower resolution, audio steps down'
$p = New-EncodePlan -Info (New-FakeInfo -Fps 60 -Duration 1200 -Size 3000000000) -Settings $s
Assert-True ($p.OutFps -eq 30) "fps capped to 30 (got $($p.OutFps))"
Assert-True ($p.OutShortSide -eq 720) "downscaled to the 720p floor, not lower (got $($p.OutShortSide))"
Assert-True ($p.OutWidth % 2 -eq 0 -and $p.OutHeight % 2 -eq 0) 'even output dimensions'
Assert-True ($p.AudioChannels -eq 1 -and $p.AudioKbps -le 64) "audio reduced (got $($p.AudioKbps) kbps, $($p.AudioChannels) ch)"
Assert-True ($p.Grade -ne '') 'has a grade'

Write-Host '50 fps source halves to 25 fps'
$p = New-EncodePlan -Info (New-FakeInfo -Fps 50 -Duration 600 -Size 3000000000) -Settings $s
Assert-True ($p.OutFps -eq 25) "fps 50 -> 25 (got $($p.OutFps))"

Write-Host 'portrait video scales on its width'
$p = New-EncodePlan -Info (New-FakeInfo -W 1080 -H 1920 -Duration 600 -Size 3000000000) -Settings $s
Assert-True ($p.Portrait) 'portrait detected'
Assert-True ($p.OutShortSide -gt 0 -and $p.OutWidth -eq $p.OutShortSide -and $p.OutHeight -gt $p.OutWidth) "output $($p.OutWidth)x$($p.OutHeight)"
Assert-True ((Get-VideoFilterChain $p) -like "scale=$($p.OutShortSide):-2*") "filter '$(Get-VideoFilterChain $p)'"

Write-Host 'no audio and mono audio'
$p = New-EncodePlan -Info (New-FakeInfo -HasAudio $false) -Settings $s
Assert-True ($p.AudioKbps -eq 0 -and $p.AudioChannels -eq 0) 'no audio -> 0 kbps'
$p = New-EncodePlan -Info (New-FakeInfo -Channels 1) -Settings $s
Assert-True ($p.AudioKbps -le 64 -and $p.AudioChannels -eq 1) 'mono source -> mono <= 64 kbps'

Write-Host 'files already under the limit'
$small = New-FakeInfo -Duration 30 -Size 20000000
$p = New-EncodePlan -Info $small -Settings $s
Assert-True ($p.Skip) 'skipped by default'
$p = New-EncodePlan -Info $small -Settings (New-TestSettings @{ skipIfAlreadyUnderLimit = $false })
Assert-True (-not $p.Skip) 'not skipped when re-encoding is allowed'
Assert-True ($p.VideoKbps -le [int]($small.VideoBitrate / 1000)) "bitrate capped at source ($($p.VideoKbps) <= $([int]($small.VideoBitrate / 1000)))"

Write-Host 'codec and speed settings'
$pH = New-EncodePlan -Info (New-FakeInfo -Duration 300 -Size 3000000000) -Settings (New-TestSettings @{ codec = 'h264'; speed = 'best' })
$pX = New-EncodePlan -Info (New-FakeInfo -Duration 300 -Size 3000000000) -Settings (New-TestSettings @{ speed = 'fast' })
Assert-True ($pH.Codec -eq 'h264' -and $pH.Preset -eq 'slow' -and $pH.CodecLabel -eq 'H.264') 'h264 / slow'
Assert-True ($pX.Preset -eq 'fast') 'fast preset'
Assert-True ($pH.OutShortSide -le $pX.OutShortSide -or $pX.OutShortSide -eq 0) 'H.264 downscales at least as much as HEVC'
$p = New-EncodePlan -Info (New-FakeInfo -Duration 60) -Settings (New-TestSettings @{ maxHeight = 720 })
Assert-True ($p.OutShortSide -eq 720) 'max resolution setting applies'

Write-Host 'resolution floor: never below 720p, bitrate falls instead'
$p = New-EncodePlan -Info (New-FakeInfo -Duration 3600 -Size 4000000000) -Settings $s
Assert-True ($p.OutShortSide -eq 720) "60-minute 1080p stays at 720p (got $($p.OutShortSide))"
Assert-True ($p.Grade -eq 'Poor' -and $p.VideoKbps -lt 100) "graded Poor with a very low bitrate ($($p.VideoKbps) kbps, $($p.Grade))"
Assert-True ($p.Notes -join ' ' -match 'Trim') 'tells the user to trim or raise the limit'
$p = New-EncodePlan -Info (New-FakeInfo -W 854 -H 480 -Duration 1800 -Size 900000000) -Settings $s
Assert-True ($p.OutShortSide -eq 0 -and $p.OutHeight -eq 480) 'a 480p source is left alone (never upscaled, never reduced further)'
$p = New-EncodePlan -Info (New-FakeInfo -W 3840 -H 2160 -Duration 180 -Size 2000000000) -Settings $s
Assert-True ($p.OutShortSide -eq 1080 -or $p.OutShortSide -eq 720 -or $p.OutShortSide -eq 1440) "4K lands on a normal rung (got $($p.OutShortSide))"
$lowest = 99999
foreach ($minutes in 1, 2, 3, 5, 8, 10, 15, 20, 30, 45, 60, 120) {
    foreach ($codecName in 'hevc', 'h264') {
        $p = New-EncodePlan -Info (New-FakeInfo -Duration ($minutes * 60) -Size 8000000000) -Settings (New-TestSettings @{ codec = $codecName })
        $short = [math]::Min($p.OutWidth, $p.OutHeight)
        if ($short -lt $lowest) { $lowest = $short }
    }
}
Assert-True ($lowest -ge 720) "no 1080p input ever planned below 720 across 1 to 120 minutes (lowest $lowest)"
$p = New-EncodePlan -Info (New-FakeInfo -Duration 60) -Settings (New-TestSettings @{ maxHeight = 480 })
Assert-True ($p.OutShortSide -eq 720) 'a 480p max-resolution setting is raised to 720p'

Write-Host 'quality (RF) settings'
$hevcPlan = New-EncodePlan -Info (New-FakeInfo -Duration 300 -Size 3000000000) -Settings $s
$h264Plan = New-EncodePlan -Info (New-FakeInfo -Duration 300 -Size 3000000000) -Settings (New-TestSettings @{ codec = 'h264' })
Assert-True ((Get-CrfValue -Plan $hevcPlan -Settings $s) -eq 32) 'HEVC uses the RF number as is (32)'
Assert-True ((Get-CrfValue -Plan $h264Plan -Settings (New-TestSettings @{ codec = 'h264' })) -eq 26) 'H.264 uses RF minus 6 (26)'
$q = New-FFmpegArguments -Info (New-FakeInfo) -Plan $hevcPlan -Crf 32 -FileSizeLimit 40000000 -OutputPath 'out.mp4'
Assert-True (($q -contains '-crf') -and ($q -contains '32') -and ($q -contains '-fs') -and ($q -contains '40000000')) 'quality arguments: -crf and -fs'
Assert-True ((-not ($q -contains '-b:v')) -and (-not ($q -contains '-pass')) -and ($q[-1] -eq 'out.mp4') -and ($q -contains 'hvc1')) 'quality arguments: single pass, no target bitrate'

Write-Host 'helpers'
Assert-True ((ConvertTo-Fps '30000/1001') -eq 29.97) 'fps 30000/1001'
Assert-True ((ConvertTo-Fps '0/0') -eq 0) 'fps 0/0'
Assert-True ((Get-LimitBytes $s) -eq 40000000) 'limit 40,000,000 bytes'
$fake = New-FakeInfo; $fake.Fps = 29.97
$pf = New-EncodePlan -Info (New-FakeInfo -Fps 59.94 -Duration 1200 -Size 3000000000) -Settings $s
Assert-True ((Get-VideoFilterChain $pf) -match '^fps=29\.97,scale=') "fps filter uses invariant decimals ('$(Get-VideoFilterChain $pf)')"
$a1 = New-FFmpegArguments -Info (New-FakeInfo) -Plan $p -PassNumber 1 -VideoKbps 1000
$a2 = New-FFmpegArguments -Info (New-FakeInfo) -Plan $p -PassNumber 2 -VideoKbps 1000 -OutputPath 'out.mp4'
Assert-True (($a1 -contains '-an') -and ($a1 -contains 'null') -and ($a1 -contains 'pass=1:log-level=error')) 'pass 1 arguments'
Assert-True (($a1 -contains '-fps_mode') -and ($a2 -contains '-fps_mode') -and ($q -contains '-fps_mode')) 'constant frame rate forced in every pass (keeps two-pass frame counts equal)'
Assert-True (($a2 -contains 'aac') -and ($a2 -contains '+faststart') -and ($a2[-1] -eq 'out.mp4') -and ($a2 -contains 'hvc1')) 'pass 2 arguments'

if ($SkipEncode) {
    Write-Host "`nPassed: $script:Pass  Failed: $script:Fail"
    if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
}

Write-Host "`n== End-to-end encodes (3 MB limit, fast preset)" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Make-Fixtures.ps1')
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$outDir = Join-Path $PSScriptRoot 'out'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null
Initialize-Log | Out-Null

function Test-Encode {
    # -Via twopass runs the fill-the-limit encoder directly; -Via compress runs the app entry point
    # (quality first, falls back to two-pass). -ExpectMethod checks which path produced the file.
    param([string]$Name, [hashtable]$Overrides = @{}, [string]$Via = 'twopass', [string]$ExpectMethod = '')
    $merged = @{ targetMB = 3; speed = 'fast'; outputMode = 'folder'; outputFolder = $outDir }
    foreach ($key in $Overrides.Keys) { $merged[$key] = $Overrides[$key] }   # overrides win
    $settings = New-TestSettings $merged
    $path = Join-Path $fixtures $Name
    Write-Host "$Name  [$($settings.codec), $Via, mode $($settings.mode)]"
    $info = Get-VideoInfo -Path $path
    $plan = New-EncodePlan -Info $info -Settings $settings
    Write-Host "  plan: $(Format-PlanSummary -Info $info -Plan $plan)" -ForegroundColor DarkGray
    if ($plan.Skip) { return @{ Info = $info; Plan = $plan; Result = $null } }
    $out = Get-OutputPath -InputPath $path -Settings $settings
    $last = @{ Pass = -1; Pct = 0 }
    $cb = { param($pct, $pass, $speed) $last.Pass = $pass; $last.Pct = $pct }
    if ($Via -eq 'compress') {
        $result = Invoke-CompressVideo -Info $info -Plan $plan -OutputPath $out -Settings $settings -OnProgress $cb
    } else {
        $result = Invoke-TwoPassEncode -Info $info -Plan $plan -OutputPath $out -Settings $settings -OnProgress $cb
    }
    Assert-True ($result.Status -eq 'Done') "status Done (got $($result.Status), $($result.ElapsedSec)s)"
    if ($ExpectMethod) { Assert-True ($result.Method -eq $ExpectMethod) "method $ExpectMethod (got $($result.Method))" }
    Assert-True ($result.SizeBytes -gt 0 -and $result.SizeBytes -le $plan.LimitBytes) "size $($result.SizeBytes) <= $($plan.LimitBytes)"
    Assert-True ($last.Pct -ge 99) "progress reached 100% (last pass $($last.Pass), $([int]$last.Pct)%)"
    $check = Get-VideoInfo -Path $result.OutputPath
    $expectCodec = 'hevc'; if ($plan.Codec -eq 'h264') { $expectCodec = 'h264' }
    Assert-True ($check.VideoCodec -eq $expectCodec) "output codec $($check.VideoCodec)"
    Assert-True ($check.Width -eq $plan.OutWidth -and $check.Height -eq $plan.OutHeight) "output size $($check.Width)x$($check.Height) matches plan $($plan.OutWidth)x$($plan.OutHeight)"
    $srcShort = [math]::Min($info.Width, $info.Height); $outShort = [math]::Min($check.Width, $check.Height)
    Assert-True ($outShort -ge [math]::Min(720, $srcShort)) "short side $outShort is not below 720 (source $srcShort)"
    if ($plan.OutFps -gt 0) { Assert-True ([math]::Abs($check.Fps - $plan.OutFps) -lt 0.1) "output fps $($check.Fps)" }
    Assert-True ($check.HasAudio -eq ($plan.AudioKbps -gt 0)) 'audio presence matches plan'
    if ($plan.AudioKbps -gt 0) { Assert-True ($check.AudioChannels -eq $plan.AudioChannels) "audio channels $($check.AudioChannels)" }
    Assert-True ([math]::Abs($check.DurationSec - $info.DurationSec) -lt 0.5) "full duration kept ($($check.DurationSec)s of $($info.DurationSec)s)"
    return @{ Info = $info; Plan = $plan; Result = $result }
}

# Fill-the-limit path (two-pass), as before.
$r = Test-Encode 'clip 1080p30 (20s).mp4'
Assert-True ($r.Plan.OutShortSide -eq 720) 'large 1080p clip dropped only to the 720p floor to fit 3 MB'

$r = Test-Encode 'portrait 1080x1920 10s.mp4'
Assert-True ($r.Plan.Portrait) 'portrait plan'

$r = Test-Encode 'silent 720p60 10s.mp4'
Assert-True ($r.Plan.AudioKbps -eq 0) 'silent clip stays silent'

$r = Test-Encode 'tiny already small.mp4'
Assert-True ($r.Plan.Skip) 'tiny clip skipped'
Assert-True (-not (Test-Path -LiteralPath (Join-Path $outDir 'tiny already small.compressed.mp4'))) 'no output written for skipped clip'

$r = Test-Encode "tést vidéo [1] 'quote' & co.mkv" @{ codec = 'h264'; skipIfAlreadyUnderLimit = $false }
Assert-True ($r.Result -and $r.Result.Status -eq 'Done') 'awkward file name + mkv + H.264 encoded (source is below 720p and stays that size)'

# Quality-first path.
Write-Host 'quality mode: fits at RF 32, so the single-pass result is kept'
$r = Test-Encode 'clip 1080p30 (20s).mp4' @{ mode = 'quality' } 'compress' 'quality'
Assert-True ($r.Result.SizeBytes -lt ($r.Plan.LimitBytes * 0.9)) "kept the smaller quality-mode file ($($r.Result.SizeBytes) bytes), not padded to the limit"

Write-Host 'quality mode: noisy clip cannot fit at RF 32, falls back to two-pass'
$r = Test-Encode 'noisy 720p 8s.mp4' @{ mode = 'quality'; targetMB = 1.5 } 'compress' 'twopass'
Assert-True (@(Get-ChildItem -LiteralPath $outDir -Filter 'noisy*').Count -eq 1) 'exactly one output file, no partial leftovers'

Write-Host 'fill mode goes straight to two-pass'
$r = Test-Encode 'silent 720p60 10s.mp4' @{ mode = 'fill'; outputSuffix = '.fill' } 'compress' 'twopass'

Write-Host 'output name collision'
$settings = New-TestSettings @{ outputMode = 'folder'; outputFolder = $outDir }
$p1 = Get-OutputPath -InputPath (Join-Path $fixtures 'clip 1080p30 (20s).mp4') -Settings $settings
Assert-True (([System.IO.Path]::GetFileName($p1) -match '^clip 1080p30 \(20s\)\.compressed \(\d+\)\.mp4$') -and -not (Test-Path -LiteralPath $p1)) "an existing output is never overwritten; next free name is used ($([System.IO.Path]::GetFileName($p1)))"

foreach ($cancelMode in 'fill', 'quality') {
    Write-Host "cancel stops ffmpeg and leaves no output ($cancelMode mode)"
    $settings = New-TestSettings @{ targetMB = 3; speed = 'fast'; mode = $cancelMode; outputMode = 'folder'; outputFolder = $outDir; outputSuffix = ".cancelled-$cancelMode" }
    $info = Get-VideoInfo -Path (Join-Path $fixtures 'clip 1080p30 (20s).mp4')
    $plan = New-EncodePlan -Info $info -Settings $settings
    $out = Get-OutputPath -InputPath $info.Path -Settings $settings
    $ticks = @{ N = 0 }
    $result = Invoke-CompressVideo -Info $info -Plan $plan -OutputPath $out -Settings $settings -ShouldCancel { $ticks.N++; return ($ticks.N -ge 2) }
    Assert-True ($result.Status -eq 'Cancelled') "status Cancelled (got $($result.Status))"
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no partial output left behind'
}

Write-Host "`nPassed: $script:Pass  Failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
