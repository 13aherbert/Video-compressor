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
. (Join-Path $srcCore 'Eta.ps1')
. (Join-Path (Split-Path -Parent $srcCore) 'Gui.ps1')   # only defines functions; no window is created

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

Write-Host 'output folder and file name templates'
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('vc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$srcDir = Join-Path $tmpRoot 'Holiday'
$workDir = Join-Path $tmpRoot 'Work'
New-Item -ItemType Directory -Path $srcDir, $workDir -Force | Out-Null
$src = Join-Path $srcDir 'Beach.mov'
$fixedTime = [datetime]'2026-10-02T17:45:09'
$tplPlan = [PSCustomObject]@{ OutWidth = 1280; OutHeight = 720 }
function Get-Loc { param([hashtable]$Overrides = @{}, [string]$Path = $src, $Plan = $tplPlan)
    return Resolve-OutputLocation -InputPath $Path -Settings (New-TestSettings $Overrides) -Plan $Plan -BatchTime $fixedTime }
$sep = [string][System.IO.Path]::DirectorySeparatorChar

Assert-True ((Get-DefaultSettings).outputFolder -eq 'Encoded' -and (Get-DefaultSettings).fileName -eq '{source}') 'defaults: Encoded folder, {source} name'
Assert-True ((Get-Loc).Path -eq (Join-Path (Join-Path $srcDir 'Encoded') 'Beach.mp4')) "default goes to an Encoded folder next to the original ($((Get-Loc).Path))"
Assert-True ((Get-Loc @{ outputFolder = '' }).Path -eq (Join-Path $srcDir 'Beach.mp4')) 'empty folder template means next to the original'
$vars = '{source}_{sourcefolder}_{date}_{time}_{datetime}_{codec}_{quality}_{mode}_{limit}_{width}x{height}'
Assert-True ((Get-Loc @{ fileName = $vars }).BaseName -eq 'Beach_Holiday_2026-10-02_17-45-09_2026-10-02_17-45-09_hevc_32_quality_40MB_1280x720') 'every variable resolves'
Assert-True ((Get-Loc @{ fileName = '{codec}_{quality}_{mode}_{limit}'; codec = 'h264'; quality = 28; mode = 'fill'; targetMB = 1.5 }).BaseName -eq 'h264_28_fill_1.5MB') 'codec, quality, mode and limit follow the settings'
Assert-True ((Get-Loc @{ fileName = '{SOURCE}-{Date}' }).BaseName -eq 'Beach-2026-10-02') 'variable names are not case sensitive'
Assert-True ((Get-Loc @{ fileName = '{width}x{height}' } -Plan $null).BaseName -eq 'x') 'width and height are empty when no plan is known yet'
Assert-True ((Get-Loc @{ outputFolder = (Join-Path (Join-Path $tmpRoot 'Out') '{date}') }).Folder -eq (Join-Path (Join-Path $tmpRoot 'Out') '2026-10-02')) 'an absolute folder is used as is, with variables'
Assert-True ((Get-Loc @{ outputFolder = 'Encoded\{codec}/{quality}' }).Folder -eq (Join-Path (Join-Path (Join-Path $srcDir 'Encoded') 'hevc') '32')) 'relative sub-folders with either slash'
Assert-True ((Get-Loc @{ outputFolder = '..\Out2' }).Folder -eq (Join-Path $tmpRoot 'Out2')) 'a relative folder can go up a level'
$bad = Get-Loc @{ outputFolder = 'En:co<d>e|d"?'; fileName = 'Be*ach<>|"' }
Assert-True ($bad.Folder -eq (Join-Path $srcDir 'Encoded') -and $bad.BaseName -eq 'Beach') "forbidden characters are removed ($($bad.Path))"
Assert-True ((Get-Loc @{ fileName = 'NUL' }).BaseName -eq '_NUL') 'Windows device names are defused'
Assert-True ((Get-Loc @{ fileName = '   ' }).BaseName -eq 'Beach') 'an empty name falls back to the original name'
Assert-True ((Get-Loc @{ fileName = 'a/b\c' }).BaseName -eq 'a_b_c') 'slashes in the file name become underscores'
Assert-True ((Get-Loc @{ fileName = ('x' * 300) }).Path.Length -le 245) 'very long names are shortened to stay under the Windows path limit'
$work = Join-Path $workDir 'Meeting.mp4'
Assert-True ((Get-Loc @{} -Path $work).Folder -eq (Join-Path $workDir 'Encoded') -and (Get-Loc).Folder -eq (Join-Path $srcDir 'Encoded')) 'each original gets its own Encoded folder'
$unk = Get-Loc @{ outputFolder = 'Encoded\{foo}'; fileName = '{source}_{Bar}' }
Assert-True (($unk.Unknown -contains '{foo}') -and ($unk.Unknown -contains '{Bar}')) 'unknown variables are reported'
$threw = ''
try { Get-OutputPath -InputPath $src -Settings (New-TestSettings @{ fileName = '{oops}' }) -BatchTime $fixedTime | Out-Null } catch { $threw = $_.Exception.Message }
Assert-True ($threw -match 'Unknown variable' -and $threw -match '\{oops\}' -and $threw -match '\{source\}') 'an unknown variable stops the file with a message listing the valid ones'
Assert-True ((Get-TemplateVariables | ForEach-Object { $_.Name }) -join ',' -eq 'source,sourcefolder,date,time,datetime,codec,quality,mode,limit,width,height') 'the variable list the window shows'

$made = Get-OutputPath -InputPath $src -Settings (New-TestSettings @{}) -Plan $tplPlan -BatchTime $fixedTime
Assert-True ((Test-Path -LiteralPath (Split-Path -Parent $made)) -and $made -eq (Join-Path (Join-Path $srcDir 'Encoded') 'Beach.mp4')) 'Get-OutputPath creates the Encoded folder'
Set-Content -LiteralPath $made -Value 'existing'
$again = Get-OutputPath -InputPath $src -Settings (New-TestSettings @{}) -Plan $tplPlan -BatchTime $fixedTime
Assert-True ($again -eq (Join-Path (Join-Path $srcDir 'Encoded') 'Beach (2).mp4')) "an existing file is never overwritten ($([System.IO.Path]::GetFileName($again)))"
$original = Join-Path $srcDir 'clip.mp4'
Set-Content -LiteralPath $original -Value 'original'
$sameFolder = Get-OutputPath -InputPath $original -Settings (New-TestSettings @{ outputFolder = '' }) -BatchTime $fixedTime
Assert-True ($sameFolder -ne $original -and $sameFolder -eq (Join-Path $srcDir 'clip (2).mp4')) 'saving next to the original never overwrites the original'
$blocker = Join-Path $tmpRoot 'blocker'
Set-Content -LiteralPath $blocker -Value 'a file, not a folder'
$threw = ''
try { Get-OutputPath -InputPath $src -Settings (New-TestSettings @{ outputFolder = (Join-Path $blocker 'sub') }) -BatchTime $fixedTime | Out-Null } catch { $threw = $_.Exception.Message }
Assert-True ($threw -match 'Could not create the output folder' -and $threw -match 'full folder path') 'an unusable folder gives a clear message'

Write-Host 'settings from older versions'
function Read-TestSettings { param([string]$Json) $f = Join-Path $tmpRoot ([guid]::NewGuid().ToString('N') + '.json'); Set-Content -LiteralPath $f -Value $Json -Encoding UTF8; return (Get-Settings -Path $f) }
$m = Read-TestSettings '{ "outputMode": "nextToSource", "outputFolder": "", "outputSuffix": ".compressed", "targetMB": 25 }'
Assert-True ($m.outputFolder -eq 'Encoded' -and $m.fileName -eq '{source}' -and $m.targetMB -eq 25) 'old default (next to the original) becomes the Encoded default; other settings are kept'
$m = Read-TestSettings '{ "outputMode": "folder", "outputFolder": "D:\\Compressed", "outputSuffix": ".small" }'
Assert-True ($m.outputFolder -eq 'D:\Compressed' -and $m.fileName -eq '{source}.small') 'an old explicit folder and suffix are carried over'
$m = Read-TestSettings '{ "outputFolder": "", "fileName": "{source}_x" }'
Assert-True ($m.outputFolder -eq '' -and $m.fileName -eq '{source}_x') 'new-style settings are not migrated (an empty folder stays empty)'
$m = Read-TestSettings '{ "targetMB": 30 }'
Assert-True ($m.outputFolder -eq 'Encoded' -and $m.fileName -eq '{source}') 'missing keys use the defaults'
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'time estimates (simulated clock)'
Assert-True ((Format-Clock 1e12) -eq '100000:00:00') 'a silly-large time does not crash'
Assert-True ((Format-Clock 42) -eq '0:42' -and (Format-Clock 725) -eq '12:05' -and (Format-Clock 3723) -eq '1:02:03') 'clock format'
Assert-True ((Format-Eta $null) -eq 'calculating...' -and (Format-Eta 2) -eq 'a few seconds' -and (Format-Eta 63) -eq 'about 1:05' -and (Format-Eta 100000) -eq 'about 27:47:00') 'estimate wording and rounding'
Assert-True ((Format-EtaLine 44 40) -eq 'Elapsed 0:44   About 0:40 left' -and (Format-EtaLine 3 $null) -eq 'Elapsed 0:03   Time left: calculating...') 'estimate line'
$t = New-EtaTracker -Durations @(60) -Mode fill -At 0
Start-EtaFile $t 0 -At 0
Update-EtaProgress $t 1 5 -At 1
$sn = Get-EtaSnapshot $t -At 1
Assert-True ($null -eq $sn.FileRemaining -and $null -eq $sn.QueueRemaining -and $sn.FileElapsed -eq 1) 'calculating... until there is enough to go on, elapsed time runs from the start'
Update-EtaProgress $t 1 50 -At 10
$sn = Get-EtaSnapshot $t -At 10
Assert-True ([math]::Abs($sn.FileRemaining - 30) -lt 0.01 -and $sn.FilePercent -eq 25) "halfway through pass 1 of 2: 30 s left (got $($sn.FileRemaining))"
Update-EtaProgress $t 1 100 -At 20; Update-EtaProgress $t 2 25 -At 25
$sn = Get-EtaSnapshot $t -At 25
Assert-True ([math]::Abs($sn.FileRemaining - 15) -lt 0.01 -and [math]::Abs($sn.QueueRemaining - 15) -lt 0.01) 'a quarter into pass 2: 15 s left for the file and the queue'

$t = New-EtaTracker -Durations @(60, 60, 120) -Mode fill -At 0
Start-EtaFile $t 0 -At 0; Update-EtaProgress $t 1 100 -At 20; Update-EtaProgress $t 2 100 -At 40; Complete-EtaFile $t -At 40
$sn = Get-EtaSnapshot $t -At 40
Assert-True ([math]::Abs($sn.QueueRemaining - 120) -lt 0.01 -and $sn.QueuePercent -eq 25 -and -not $sn.Running) 'between files: 3 x remaining work at the measured speed'
Start-EtaFile $t 1 -At 40; Update-EtaProgress $t 1 10 -At 44
$sn = Get-EtaSnapshot $t -At 44
Assert-True ([math]::Abs($sn.QueueRemaining - 123.62) -lt 0.1 -and $sn.QueueElapsed -eq 44 -and $sn.FileElapsed -eq 4) "queue estimate includes the unstarted longer file (got $([math]::Round($sn.QueueRemaining, 1)))"
Assert-True ($sn.QueuePercent -gt 25 -and $sn.QueuePercent -lt 40) 'queue percentage is weighted by video length'

$t = New-EtaTracker -Durations @(100, 100) -Mode quality -At 0
Start-EtaFile $t 0 -At 0; Update-EtaProgress $t 0 20 -At 10
$sn = Get-EtaSnapshot $t -At 10
Assert-True ([math]::Abs($sn.FileRemaining - 65) -lt 0.01) "quality attempt: rest of it plus the expected extra for a fallback (got $($sn.FileRemaining))"
Update-EtaProgress $t 0 50 -At 25                       # the attempt gives up at 50 %
Update-EtaProgress $t 1 0 -At 25
$sn = Get-EtaSnapshot $t -At 25
Assert-True ([math]::Abs($sn.FileRemaining - 100) -lt 0.01) "fallback started: the estimate switches to two passes (got $($sn.FileRemaining))"
Complete-EtaFile $t -At 100 -Learn $false
$t2 = New-EtaTracker -Durations @(100, 100, 100) -Mode quality -At 0
Start-EtaFile $t2 0 -At 0; Update-EtaProgress $t2 0 100 -At 50; Complete-EtaFile $t2 -At 50
Assert-True ((Get-EtaExpectedPasses $t2) -eq 1) 'a file that fitted first time teaches the average (1 pass)'
Assert-True ((Get-EtaExpectedPasses $t) -eq 1.5) 'a cancelled or failed file does not change the average'
$sn = Get-EtaSnapshot $t2 -At 50
Assert-True ([math]::Abs($sn.QueueRemaining - 100) -lt 0.01) 'two files of 100 s left at 2 pass-seconds per second'

Write-Host 'window text and callbacks (tested without a window)'
$pumped = @{ N = 0 }
function New-FakeUi {
    return @{
        BarFile = [PSCustomObject]@{ Value = 0 }; BarAll = [PSCustomObject]@{ Value = 0 }
        CapFile = [PSCustomObject]@{ Text = '' }; CapAll = [PSCustomObject]@{ Text = '' }
        DetFile = [PSCustomObject]@{ Text = '' }; DetAll = [PSCustomObject]@{ Text = '' }
        Status  = [PSCustomObject]@{ Text = '' }
        Pump    = { $pumped.N++ }.GetNewClosure()
        LastError = ''
    }
}
$fakeUi = New-FakeUi
$fakeItem = @{
    Status = ''
    Row    = [PSCustomObject]@{ SubItems = @(1..9 | ForEach-Object { [PSCustomObject]@{ Text = '' } }) }
    Info   = [PSCustomObject]@{ FileName = 'a.mp4' }
}
$cbTracker = New-EtaTracker -Durations @(60, 60, 60, 60) -Mode fill     # real clock: the callback reads it itself
Start-EtaFile $cbTracker 0; Update-EtaProgress $cbTracker 2 100; Update-EtaProgress $cbTracker 1 100; Complete-EtaFile $cbTracker
Start-EtaFile $cbTracker 1
# Same shape as the real thing: the callback is built in one function and called from another that
# the encoder runs, so any reliance on the builder's caller's variables would fail here.
function Invoke-FakeEncoder { param([scriptblock]$OnProgress) & $OnProgress 25 1 '2.0x'; & $OnProgress 50 2 '1.5x'; & $OnProgress 100 0 '3.0x' }
function Start-FakeBatch { $cb = New-GuiProgressCallback -Ui $fakeUi -Item $fakeItem -Index 1 -Total 4 -Quality 32 -Tracker $cbTracker; Invoke-FakeEncoder $cb }
Start-FakeBatch
Assert-True ($fakeUi.LastError -eq '') "progress callback ran without errors ($($fakeUi.LastError))"
Assert-True ($fakeUi.BarFile.Value -eq 100 -and $fakeUi.CapFile.Text -eq 'Current file: 100 %') "file bar and its label: $($fakeUi.BarFile.Value), '$($fakeUi.CapFile.Text)'"
Assert-True ($fakeUi.BarAll.Value -eq 50 -and $fakeUi.CapAll.Text -eq 'Whole queue: file 2 of 4, 50 %') "queue bar and its label: $($fakeUi.BarAll.Value), '$($fakeUi.CapAll.Text)'"
Assert-True ($fakeUi.DetFile.Text -like 'Elapsed *' -and $fakeUi.DetAll.Text -like 'Elapsed *') "elapsed and remaining lines: '$($fakeUi.DetFile.Text)' / '$($fakeUi.DetAll.Text)'"
Assert-True ($fakeUi.Status.Text -eq 'File 2 of 4: a.mp4  (quality RF 32, 3.0x)') "status text: '$($fakeUi.Status.Text)'"
Assert-True ($fakeItem.Row.SubItems[8].Text -eq 'encoding 100% (3.0x)') 'row status text updated'
Assert-True ($pumped.N -eq 3) 'window repainted on every update'
Set-GuiIdle $fakeUi
Assert-True ($fakeUi.CapFile.Text -eq 'Current file' -and $fakeUi.CapAll.Text -eq 'Whole queue' -and $fakeUi.DetFile.Text -eq '' -and $fakeUi.BarAll.Value -eq 0) 'idle state of the progress area'

$brokenUi = @{ BarFile = $null; BarAll = $null; CapFile = $null; CapAll = $null; DetFile = $null; DetAll = $null; Status = $null; Pump = { }; LastError = '' }
$errorEscaped = $false
try { $cb = New-GuiProgressCallback -Ui $brokenUi -Item $fakeItem -Index 0 -Total 1 -Quality 32 -Tracker $cbTracker; & $cb 10 2 '1x' } catch { $errorEscaped = $true }
Assert-True (-not $errorEscaped) 'a window problem never aborts an encode'
Assert-True ($brokenUi.LastError -ne '') 'the window problem is recorded for the log'

$cancelState = @{ Cancel = $false }
$check = New-GuiCancelCheck -Ui $fakeUi -State $cancelState
Assert-True ((& $check) -eq $false) 'cancel check is false at first'
$cancelState.Cancel = $true
Assert-True ((& $check) -eq $true) 'cancel check turns true after Cancel is clicked'

$conTracker = New-EtaTracker -Durations @(60) -Mode quality
Start-EtaFile $conTracker 0
$conErr = $null
try { $cb = New-ConsoleProgressCallback -Tracker $conTracker -Activity 'Test' -Position 1 -Total 1; & $cb 40 0 '2x'; Write-Progress -Activity 'Test' -Completed } catch { $conErr = $_.Exception.Message }
Assert-True ($null -eq $conErr) "console progress callback ran ($conErr)"

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
    $merged = @{ targetMB = 3; speed = 'fast'; outputFolder = $outDir; fileName = '{source}.compressed' }
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
$r = Test-Encode 'silent 720p60 10s.mp4' @{ mode = 'fill'; fileName = '{source}.fill' } 'compress' 'twopass'

Write-Host 'output name collision'
$settings = New-TestSettings @{ outputFolder = $outDir; fileName = '{source}.compressed' }
$p1 = Get-OutputPath -InputPath (Join-Path $fixtures 'clip 1080p30 (20s).mp4') -Settings $settings
Assert-True (([System.IO.Path]::GetFileName($p1) -match '^clip 1080p30 \(20s\)\.compressed \(\d+\)\.mp4$') -and -not (Test-Path -LiteralPath $p1)) "an existing output is never overwritten; next free name is used ($([System.IO.Path]::GetFileName($p1)))"

foreach ($cancelMode in 'fill', 'quality') {
    Write-Host "cancel stops ffmpeg and leaves no output ($cancelMode mode)"
    $settings = New-TestSettings @{ targetMB = 3; speed = 'fast'; mode = $cancelMode; outputFolder = $outDir; fileName = "{source}.cancelled-$cancelMode" }
    $info = Get-VideoInfo -Path (Join-Path $fixtures 'clip 1080p30 (20s).mp4')
    $plan = New-EncodePlan -Info $info -Settings $settings
    $out = Get-OutputPath -InputPath $info.Path -Settings $settings
    $ticks = @{ N = 0 }
    $result = Invoke-CompressVideo -Info $info -Plan $plan -OutputPath $out -Settings $settings -ShouldCancel { $ticks.N++; return ($ticks.N -ge 2) }
    Assert-True ($result.Status -eq 'Cancelled') "status Cancelled (got $($result.Status))"
    Assert-True (-not (Test-Path -LiteralPath $out)) 'no partial output left behind'
}

Write-Host 'console mode with the output flags and time estimates'
$script:SettingsPathOverride = Join-Path $outDir 'test-settings.json'     # nothing below may touch the real settings.json
$conRoot = Join-Path $outDir 'console'
$conSrcDir = Join-Path $conRoot 'Fix'
New-Item -ItemType Directory -Path $conSrcDir -Force | Out-Null
$conClip = Join-Path $conSrcDir 'Silent.mp4'
Copy-Item -LiteralPath (Join-Path $fixtures 'silent 720p60 10s.mp4') -Destination $conClip
$hostExe = (Get-Process -Id $PID).Path
$mainScript = Join-Path (Split-Path -Parent $srcCore) 'Main.ps1'
$hostArgs = @('-NoProfile')
if (Test-IsWindows) { $hostArgs += @('-ExecutionPolicy', 'Bypass') }
$hostArgs += @('-File', $mainScript, '-NoGui', '-NoPause', '-TargetMB', '3', '-Speed', 'fast',
               '-OutputFolder', (Join-Path (Join-Path $conRoot 'Out') '{sourcefolder}'), '-NameTemplate', '{source}_RF{quality}_{height}p', $conClip)
$prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$conOutput = (& $hostExe @hostArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
$conExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
$conExpected = Join-Path (Join-Path (Join-Path $conRoot 'Out') 'Fix') 'Silent_RF32_720p.mp4'
Assert-True ($conExit -eq 0) "console run exits cleanly (exit code $conExit)"
Assert-True (Test-Path -LiteralPath $conExpected) "output went to the folder and name built from the variables ($conExpected)"
Assert-True ($conOutput -match 'output: ') 'the planned output path is shown before encoding'
Assert-True ($conOutput -match 'Finished 1 file\(s\) in \d+:\d\d') 'the console reports the total time'
Assert-True ($conOutput -match 'done: .* in \d+:\d\d ->') 'each file reports how long it took'
if (-not (Test-Path -LiteralPath $conExpected)) { Write-Host $conOutput }

if ((Test-IsWindows) -and $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage') {
    Write-Host 'the real window, driven end to end (Windows only)'
    $guiReady = $true
    try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing }
    catch { $guiReady = $false; Write-Host "  skipped: Windows Forms is not available ($($_.Exception.Message))" }
    if ($guiReady) {
        $guiDir = Join-Path $outDir 'gui'
        New-Item -ItemType Directory -Path $guiDir -Force | Out-Null
        $guiClip = Join-Path $guiDir 'Clip.mp4'
        Copy-Item -LiteralPath (Join-Path $fixtures 'clip 1080p30 (20s).mp4') -Destination $guiClip
        $guiSettings = New-TestSettings @{ targetMB = 3; speed = 'fast'; fileName = '{source}_{height}p' }
        $seen = @{}
        try {
            Show-CompressorWindow -Files @() -Settings $guiSettings -Automation {
                param($w)
                $seen.MenuItems = $w.Controls.Menu.Items.Count
                $seen.IdleCaption = $w.Controls.CapAll.Text
                & $w.AddPaths @($guiClip)
                $seen.Added = $w.State.Items.Count
                $seen.Example = $w.Controls.Example.Text
                & $w.StartBatch
                $seen.Status = $w.State.Items[0].Status
                $seen.CapFile = $w.Controls.CapFile.Text
                $seen.CapAll = $w.Controls.CapAll.Text
                $seen.DetAll = $w.Controls.DetAll.Text
                $seen.BarAll = $w.Controls.BarAll.Value
                $seen.UiError = $w.Ui.LastError
                $w.Controls.FileName.Text = '{nope}'
                $seen.BadExample = $w.Controls.Example.Text
            }
        } catch { $seen.Error = $_.Exception.Message }
        Assert-True (-not $seen.ContainsKey('Error')) "the window ran a whole batch without an error ($($seen.Error))"
        Assert-True ($seen.MenuItems -eq 11 -and $seen.IdleCaption -eq 'Whole queue') 'the Variables menu lists 11 variables; idle caption'
        Assert-True ($seen.Added -eq 1 -and $seen.Example -like '*Encoded*Clip_720p.mp4') "live example before starting: $($seen.Example)"
        Assert-True ($seen.Status -like 'Done*') "file finished: $($seen.Status)"
        Assert-True (Test-Path -LiteralPath (Join-Path (Join-Path $guiDir 'Encoded') 'Clip_720p.mp4')) 'output is in the Encoded folder next to the original'
        Assert-True ($seen.CapFile -eq 'Current file' -and $seen.CapAll -like 'Whole queue: finished*' -and $seen.BarAll -eq 100) "captions and bars after the batch: '$($seen.CapAll)', bar $($seen.BarAll)"
        Assert-True ($seen.DetAll -like 'Elapsed *') "elapsed time shown at the end: '$($seen.DetAll)'"
        Assert-True ($seen.UiError -eq '') "no window update errors ($($seen.UiError))"
        Assert-True ($seen.BadExample -like '*Unknown variable*{nope}*') 'an unknown variable is flagged in the example line'
    }
}

Write-Host "`nPassed: $script:Pass  Failed: $script:Fail"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
