# Core/Eta.ps1
# Elapsed time and "time remaining" for the current file and for the whole queue.
#
# Everything is measured in "pass-seconds": one full pass over a video of D seconds is D pass-seconds.
# A quality attempt is one pass; the fallback is two more (analysis + encode). Throughput is
# pass-seconds of work per wall-clock second over everything done so far, so it adapts to your
# computer, to the video, and to how often quality mode has to fall back.
#
# The functions take the current time as a parameter (seconds), so tests can drive a fake clock.
# Time is read from [DateTime] rather than Stopwatch so this also works in Constrained Language Mode.

function Get-EtaNow {
    return ([DateTime]::UtcNow.Ticks / 10000000.0)
}

function Get-FileFraction {
    # How far through the current file the progress bar should be (0 to 1).
    # Pass 0 is the single quality pass; passes 1 and 2 are the two halves of a two-pass encode.
    param([int]$Pass, [double]$Percent)
    $p = [math]::Max(0.0, [math]::Min(100.0, $Percent)) / 100.0
    if ($Pass -eq 0) { return $p }
    return ((($Pass - 1) + $p) / 2.0)
}

function New-EtaTracker {
    param(
        [Parameter(Mandatory = $true)][double[]]$Durations,   # video length of each file to be encoded, in order
        [string]$Mode = 'quality',                            # 'quality' or 'fill'
        [double]$At = (Get-EtaNow)
    )
    $total = 0.0
    foreach ($d in $Durations) { $total += $d }
    return @{
        Durations    = $Durations
        TotalMedia   = $total
        Mode         = $Mode
        BatchStart   = $At
        Index        = -1
        FileStart    = 0.0
        CurPass      = -1      # the pass being reported right now: 0 quality attempt, 1 analysis, 2 encode
        PassMax      = @{ 0 = 0.0; 1 = 0.0; 2 = 0.0 }   # furthest fraction (0 to 1) reached in each pass
        CurFraction  = 0.0
        DoneBusy     = 0.0     # wall seconds spent on finished files
        DoneWork     = 0.0     # pass-seconds done on finished files
        DoneMedia    = 0.0     # video seconds of finished files (for the queue percentage)
        LearnWork    = 0.0     # pass-seconds and video seconds of files that finished normally,
        LearnMedia   = 0.0     #   used to learn how many passes a file really takes
        FilesDone    = 0
    }
}

function Start-EtaFile {
    param([Parameter(Mandatory = $true)]$Tracker, [Parameter(Mandatory = $true)][int]$Index, [double]$At = (Get-EtaNow))
    $Tracker.Index = $Index
    $Tracker.FileStart = $At
    $Tracker.PassMax = @{ 0 = 0.0; 1 = 0.0; 2 = 0.0 }
    $Tracker.CurPass = -1
    $Tracker.CurFraction = 0.0
}

function Update-EtaProgress {
    param([Parameter(Mandatory = $true)]$Tracker, [int]$Pass, [double]$Percent, [double]$At = (Get-EtaNow))
    if ($Tracker.Index -lt 0) { return }
    $f = [math]::Max(0.0, [math]::Min(100.0, $Percent)) / 100.0
    if ($Tracker.PassMax.ContainsKey($Pass) -and $f -gt $Tracker.PassMax[$Pass]) { $Tracker.PassMax[$Pass] = $f }
    $Tracker.CurPass = $Pass
    $Tracker.CurFraction = Get-FileFraction -Pass $Pass -Percent $Percent
}

function Get-EtaCurrentWork {
    param($Tracker)
    if ($Tracker.Index -lt 0) { return 0.0 }
    $d = $Tracker.Durations[$Tracker.Index]
    return ($d * ($Tracker.PassMax[0] + $Tracker.PassMax[1] + $Tracker.PassMax[2]))
}

function Complete-EtaFile {
    # Call when a file is finished. -Learn:$false for failed or cancelled files, which would skew the average.
    param([Parameter(Mandatory = $true)]$Tracker, [double]$At = (Get-EtaNow), [bool]$Learn = $true)
    if ($Tracker.Index -lt 0) { return }
    $d = $Tracker.Durations[$Tracker.Index]
    $work = Get-EtaCurrentWork $Tracker
    $Tracker.DoneBusy += [math]::Max(0.0, $At - $Tracker.FileStart)
    $Tracker.DoneWork += $work
    $Tracker.DoneMedia += $d
    if ($Learn) { $Tracker.LearnWork += $work; $Tracker.LearnMedia += $d }
    $Tracker.FilesDone++
    $Tracker.Index = -1
    $Tracker.CurFraction = 0.0
}

function Get-EtaExpectedPasses {
    # Average number of passes a file takes. Learned from finished files; until then a guess:
    # quality mode usually needs 1 but sometimes falls back to 3, fill mode always needs 2.
    param($Tracker)
    if ($Tracker.LearnMedia -gt 0) { return [math]::Max(1.0, $Tracker.LearnWork / $Tracker.LearnMedia) }
    if ($Tracker.Mode -eq 'fill') { return 2.0 }
    return 1.5
}

function Get-EtaSnapshot {
    param([Parameter(Mandatory = $true)]$Tracker, [double]$At = (Get-EtaNow))

    $running = ($Tracker.Index -ge 0)
    $fileElapsed = 0.0
    if ($running) { $fileElapsed = [math]::Max(0.0, $At - $Tracker.FileStart) }
    $queueElapsed = [math]::Max(0.0, $At - $Tracker.BatchStart)

    $curWork = Get-EtaCurrentWork $Tracker
    $busy = $Tracker.DoneBusy + $fileElapsed
    $work = $Tracker.DoneWork + $curWork
    $rate = $null
    if ($busy -ge 2.0 -and $work -gt 0.0) { $rate = $work / $busy }

    $expected = Get-EtaExpectedPasses $Tracker

    # Work still to do on the current file, in pass-seconds.
    $curRemainingWork = 0.0
    if ($running) {
        $d = $Tracker.Durations[$Tracker.Index]
        $pm = $Tracker.PassMax
        if ($Tracker.CurPass -ge 1) {
            # Two-pass phase: whatever is left of the analysis pass plus the whole encode pass.
            $curRemainingWork = $d * ((1.0 - $pm[1]) + (1.0 - $pm[2]))
        } elseif ($Tracker.CurPass -eq 0) {
            # Quality attempt: the rest of it, plus the average extra work when it has to fall back.
            $curRemainingWork = $d * ((1.0 - $pm[0]) + [math]::Max(0.0, $expected - 1.0))
        } else {
            $curRemainingWork = $d * $expected
        }
    }

    # Work for files not started yet (they run in order; finished files are counted in FilesDone).
    $futureWork = 0.0
    $next = $Tracker.FilesDone
    if ($running) { $next = $Tracker.Index + 1 }
    for ($i = $next; $i -lt $Tracker.Durations.Count; $i++) { $futureWork += $Tracker.Durations[$i] * $expected }

    $fileRemaining = $null
    $queueRemaining = $null
    if ($null -ne $rate -and $rate -gt 0.0) {
        if ($running) { $fileRemaining = $curRemainingWork / $rate }
        $queueRemaining = ($curRemainingWork + $futureWork) / $rate
    }

    $queuePercent = 0.0
    if ($Tracker.TotalMedia -gt 0.0) {
        $curMedia = 0.0
        if ($running) { $curMedia = $Tracker.Durations[$Tracker.Index] * $Tracker.CurFraction }
        $queuePercent = [math]::Min(100.0, 100.0 * ($Tracker.DoneMedia + $curMedia) / $Tracker.TotalMedia)
    }

    return [PSCustomObject]@{
        Running        = $running
        FileElapsed    = $fileElapsed
        FileRemaining  = $fileRemaining      # $null while still calculating
        QueueElapsed   = $queueElapsed
        QueueRemaining = $queueRemaining     # $null while still calculating
        FilePercent    = 100.0 * $Tracker.CurFraction
        QueuePercent   = $queuePercent
        FilesDone      = $Tracker.FilesDone
        FilesTotal     = $Tracker.Durations.Count
    }
}

function Format-Clock {
    # 0:42, 12:05, 1:02:03
    param([double]$Seconds)
    $s = [long][math]::Round([math]::Min(3.6e8, [math]::Max(0.0, $Seconds)))
    $h = [long][math]::Floor($s / 3600)
    $m = [int][math]::Floor(($s % 3600) / 60)
    $sec = [int]($s % 60)
    if ($h -gt 0) { return ('{0}:{1:00}:{2:00}' -f $h, $m, $sec) }
    return ('{0}:{1:00}' -f $m, $sec)
}

function Format-Eta {
    # Time remaining as text. Rounded so the number does not flicker on every tick.
    param($Seconds)
    if ($null -eq $Seconds) { return 'calculating...' }
    $s = [double]$Seconds
    if ($s -gt 359999) { return 'a very long time' }
    if ($s -lt 5) { return 'a few seconds' }
    if ($s -lt 600)       { $s = [math]::Round($s / 5.0) * 5.0 }
    elseif ($s -lt 3600)  { $s = [math]::Round($s / 15.0) * 15.0 }
    else                  { $s = [math]::Round($s / 60.0) * 60.0 }
    return ('about ' + (Format-Clock $s))
}

function Format-EtaLine {
    # "Elapsed 0:42   About 1:10 left"
    param([double]$Elapsed, $Remaining)
    if ($null -eq $Remaining) {
        $left = 'Time left: calculating...'
    } else {
        $text = Format-Eta $Remaining
        $left = $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1) + ' left'
    }
    return ('Elapsed {0}   {1}' -f (Format-Clock $Elapsed), $left)
}

function New-ConsoleProgressCallback {
    # Progress callback for console mode. Everything it needs is passed in (see New-GuiProgressCallback
    # in Gui.ps1 for why): it shows the encoder pass, percentage, and elapsed / remaining time for the
    # current file and for the whole queue.
    param($Tracker, [string]$Activity, [int]$Position, [int]$Total)
    $callback = {
        param($pct, $pass, $speed)
        try {
            Update-EtaProgress -Tracker $Tracker -Pass $pass -Percent $pct
            $snap = Get-EtaSnapshot -Tracker $Tracker
            $label = 'pass 1 of 2 (analysing)'
            if ($pass -eq 0) { $label = 'encoding at your quality setting' }
            if ($pass -eq 2) { $label = 'pass 2 of 2 (encoding)' }
            $detail = ('This file: {0}   |   Whole queue, file {1} of {2}: {3}' -f
                (Format-EtaLine $snap.FileElapsed $snap.FileRemaining), $Position, $Total,
                (Format-EtaLine $snap.QueueElapsed $snap.QueueRemaining))
            Write-Progress -Activity $Activity -Status ("$label  $([math]::Round($pct))%  $speed") `
                           -CurrentOperation $detail -PercentComplete ([int][math]::Max(0, [math]::Min(100, $pct)))
        } catch { }
    }.GetNewClosure()
    return $callback
}
