# src/Gui.ps1
# The window. Uses Windows Forms from the .NET Framework that is built into Windows 10/11,
# so nothing has to be installed. Dot-sourced by Main.ps1 only when that is available.
#
# Design: all mutable state lives in the $state hashtable so event handlers (which run in
# child scopes) can change it. Encoding runs on the UI thread; ffmpeg's progress lines
# arrive every half second and each one pumps the message loop with DoEvents, which keeps
# the window responsive and lets Cancel work.

function Show-CompressorWindow {
    param([string[]]$Files, $Settings)

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{
        Items     = New-Object System.Collections.ArrayList   # hashtables: Path, Info, Plan, Row, Status, Result
        Running        = $false
        Cancel         = $false
        CloseRequested = $false
        Settings       = $Settings
        OutputDir      = ''
    }

    # ------------------------------------------------------------------ form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Video Compressor'
    $form.Size = New-Object System.Drawing.Size(1000, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(860, 480)
    $form.StartPosition = 'CenterScreen'
    $form.AllowDrop = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # ------------------------------------------------------------------ options (top)
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 86
    $top.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 0)
    $form.Controls.Add($top)

    function Add-Label {
        param($Parent, [string]$Text, [int]$X, [int]$Y)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point($X, $Y)
        $Parent.Controls.Add($l) | Out-Null
        return $l
    }
    function Add-Combo {
        param($Parent, [string[]]$Items, [int]$X, [int]$Y, [int]$Width, [int]$Selected)
        $c = New-Object System.Windows.Forms.ComboBox
        $c.DropDownStyle = 'DropDownList'
        foreach ($i in $Items) { $c.Items.Add($i) | Out-Null }
        $c.SelectedIndex = $Selected
        $c.Location = New-Object System.Drawing.Point($X, $Y)
        $c.Width = $Width
        $Parent.Controls.Add($c) | Out-Null
        return $c
    }

    $y1 = 10; $y2 = 48
    Add-Label $top 'Max size (MB)' 10 ($y1 + 4) | Out-Null
    $numTarget = New-Object System.Windows.Forms.NumericUpDown
    $numTarget.Minimum = 1; $numTarget.Maximum = 10000; $numTarget.DecimalPlaces = 0
    $numTarget.Value = [decimal][math]::Max(1, [math]::Round([double]$Settings.targetMB))
    $numTarget.Location = New-Object System.Drawing.Point(100, $y1); $numTarget.Width = 70
    $top.Controls.Add($numTarget)

    Add-Label $top 'Codec' 190 ($y1 + 4) | Out-Null
    $codecIndex = 0; if ((ConvertTo-CodecId $Settings.codec) -eq 'h264') { $codecIndex = 1 }
    $cboCodec = Add-Combo $top @('HEVC (H.265): best quality per MB', 'H.264: plays on anything') 235 $y1 230 $codecIndex

    Add-Label $top 'Speed' 480 ($y1 + 4) | Out-Null
    $speedIndex = 1
    switch ("$($Settings.speed)".ToLowerInvariant()) { 'fast' { $speedIndex = 0 } 'best' { $speedIndex = 2 } }
    $cboSpeed = Add-Combo $top @('Fast', 'Balanced', 'Best quality (slow)') 525 $y1 150 $speedIndex

    Add-Label $top 'Max resolution' 690 ($y1 + 4) | Out-Null
    $resOptions = @(0, 1080, 720, 480)
    $resIndex = [array]::IndexOf($resOptions, [int]$Settings.maxHeight); if ($resIndex -lt 0) { $resIndex = 0 }
    $cboMaxRes = Add-Combo $top @('Auto', '1080p', '720p', '480p') 785 $y1 90 $resIndex

    Add-Label $top 'Save to' 10 ($y2 + 4) | Out-Null
    $outIndex = 0; if ($Settings.outputMode -eq 'folder') { $outIndex = 1 }
    $cboOut = Add-Combo $top @('Next to the original file', 'A folder I choose') 100 $y2 180 $outIndex
    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.ReadOnly = $true
    $txtOut.Text = [string]$Settings.outputFolder
    $txtOut.Location = New-Object System.Drawing.Point(290, $y2); $txtOut.Width = 300
    $top.Controls.Add($txtOut)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point(596, ($y2 - 1)); $btnBrowse.Width = 80
    $top.Controls.Add($btnBrowse)
    $chkSmall = New-Object System.Windows.Forms.CheckBox
    $chkSmall.Text = 'Also re-encode files already under the limit'
    $chkSmall.AutoSize = $true
    $chkSmall.Checked = -not [bool]$Settings.skipIfAlreadyUnderLimit
    $chkSmall.Location = New-Object System.Drawing.Point(690, ($y2 + 2))
    $top.Controls.Add($chkSmall)

    # ------------------------------------------------------------------ bottom: buttons + progress
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 96
    $form.Controls.Add($bottom)

    function Add-Button {
        param([string]$Text, [int]$X, [int]$Y, [int]$Width = 100)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Width = $Width; $b.Height = 28
        $bottom.Controls.Add($b) | Out-Null
        return $b
    }
    $btnAdd    = Add-Button 'Add videos...' 10 8 110
    $btnRemove = Add-Button 'Remove' 126 8 80
    $btnClear  = Add-Button 'Clear' 212 8 70
    $btnOpen   = Add-Button 'Open output folder' 300 8 140
    $btnCancel = Add-Button 'Cancel' 760 8 90
    $btnStart  = Add-Button 'Start' 856 8 120
    $btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $btnStart.Anchor = 'Top,Right'; $btnCancel.Anchor = 'Top,Right'
    $btnCancel.Enabled = $false

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.AutoSize = $false
    $lblStatus.Location = New-Object System.Drawing.Point(10, 44); $lblStatus.Width = 960; $lblStatus.Height = 18
    $lblStatus.Anchor = 'Top,Left,Right'
    $lblStatus.Text = 'Drop videos or folders anywhere on this window, or click "Add videos...".'
    $bottom.Controls.Add($lblStatus)

    $barFile = New-Object System.Windows.Forms.ProgressBar
    $barFile.Location = New-Object System.Drawing.Point(10, 64); $barFile.Width = 470; $barFile.Height = 18
    $barFile.Anchor = 'Top,Left,Right'
    $bottom.Controls.Add($barFile)
    $barAll = New-Object System.Windows.Forms.ProgressBar
    $barAll.Location = New-Object System.Drawing.Point(500, 64); $barAll.Width = 476; $barAll.Height = 18
    $barAll.Anchor = 'Top,Right'
    $bottom.Controls.Add($barAll)

    # ------------------------------------------------------------------ list (fill)
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    $list.AllowDrop = $true
    $list.ShowItemToolTips = $true
    foreach ($col in @(@('File', 250), @('Length', 60), @('Source', 120), @('Output', 120), @('Video', 70), @('Audio', 90), @('Est. size', 70), @('Quality', 60), @('Status', 150))) {
        $list.Columns.Add($col[0], $col[1]) | Out-Null
    }
    $form.Controls.Add($list)
    $list.BringToFront()

    # ------------------------------------------------------------------ helpers
    function Sync-SettingsFromUi {
        $s = $state.Settings
        $s.targetMB = [double]$numTarget.Value
        $s.codec = @('hevc', 'h264')[$cboCodec.SelectedIndex]
        $s.speed = @('fast', 'balanced', 'best')[$cboSpeed.SelectedIndex]
        $s.maxHeight = $resOptions[$cboMaxRes.SelectedIndex]
        $s.outputMode = @('nextToSource', 'folder')[$cboOut.SelectedIndex]
        $s.outputFolder = $txtOut.Text
        $s.skipIfAlreadyUnderLimit = -not $chkSmall.Checked
    }

    function Update-Row {
        param($item)
        $row = $item.Row
        $info = $item.Info; $plan = $item.Plan
        if ($null -eq $info) {
            $row.SubItems[8].Text = $item.Status
            return
        }
        $row.SubItems[1].Text = Format-Duration $info.DurationSec
        $srcFps = [math]::Round([double]$info.Fps, 0)
        $row.SubItems[2].Text = "$($info.Width)x$($info.Height) $srcFps fps, $(Format-Bytes $info.SizeBytes)"
        if ($null -eq $plan -or $plan.Skip) {
            foreach ($i in 3..7) { $row.SubItems[$i].Text = '' }
            if ($null -ne $plan) { $row.SubItems[8].Text = "Skipped: $($plan.SkipReason)" }
        } else {
            $outFps = $srcFps; if ($plan.OutFps -gt 0) { $outFps = [math]::Round($plan.OutFps, 0) }
            $row.SubItems[3].Text = "$($plan.OutWidth)x$($plan.OutHeight) $outFps fps"
            $row.SubItems[4].Text = "$($plan.VideoKbps) kbps"
            $audio = 'none'
            if ($plan.AudioKbps -gt 0) { $ch = 'stereo'; if ($plan.AudioChannels -eq 1) { $ch = 'mono' }; $audio = "$($plan.AudioKbps) kbps $ch" }
            $row.SubItems[5].Text = $audio
            $row.SubItems[6].Text = Format-Bytes $plan.EstimatedBytes
            $row.SubItems[7].Text = $plan.Grade
            $row.SubItems[8].Text = $item.Status
            $row.ToolTipText = ($plan.Notes -join "`n")
        }
        $grade = ''
        if ($null -ne $plan -and -not $plan.Skip) { $grade = $plan.Grade }
        switch ($grade) {
            'Poor' { $row.ForeColor = [System.Drawing.Color]::Firebrick }
            'OK'   { $row.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            default { $row.ForeColor = [System.Drawing.SystemColors]::WindowText }
        }
    }

    function Update-Plans {
        if ($state.Running) { return }
        Sync-SettingsFromUi
        foreach ($item in $state.Items) {
            if ($null -eq $item.Info) { continue }
            if ($item.Status -like 'Done*') { continue }
            $item.Plan = New-EncodePlan -Info $item.Info -Settings $state.Settings
            $item.Status = 'Ready'
            Update-Row $item
        }
        $limit = Format-Bytes (Get-LimitBytes $state.Settings)
        $lblStatus.Text = "$($state.Items.Count) file(s). Limit $limit. Colours: red = will look rough, amber = acceptable."
    }

    function Add-Paths {
        param([string[]]$Paths)
        $resolved = Resolve-VideoInputs -Paths $Paths
        foreach ($p in $resolved) {
            $dup = $false
            foreach ($existing in $state.Items) { if ($existing.Path -eq $p) { $dup = $true; break } }
            if ($dup) { continue }
            $row = New-Object System.Windows.Forms.ListViewItem([System.IO.Path]::GetFileName($p))
            foreach ($i in 1..8) { $row.SubItems.Add('') | Out-Null }
            $row.SubItems[8].Text = 'Reading...'
            $list.Items.Add($row) | Out-Null
            $item = @{ Path = $p; Info = $null; Plan = $null; Row = $row; Status = 'Reading...'; Result = $null }
            [void]$state.Items.Add($item)
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $item.Info = Get-VideoInfo -Path $p
                $item.Status = 'Ready'
            } catch {
                $item.Status = "Error: $($_.Exception.Message)"
                $row.ForeColor = [System.Drawing.Color]::Firebrick
                $row.ToolTipText = $_.Exception.Message
                Write-Log "Could not read '$p': $($_.Exception.Message)"
            }
        }
        Update-Plans
    }

    function Set-Busy {
        param([bool]$Busy)
        $state.Running = $Busy
        foreach ($c in @($numTarget, $cboCodec, $cboSpeed, $cboMaxRes, $cboOut, $btnBrowse, $chkSmall, $btnAdd, $btnRemove, $btnClear, $btnStart)) { $c.Enabled = -not $Busy }
        $btnCancel.Enabled = $Busy
        $form.AllowDrop = -not $Busy
        $list.AllowDrop = -not $Busy
    }

    function Start-Batch {
        Sync-SettingsFromUi
        $s = $state.Settings
        if ($s.outputMode -eq 'folder' -and [string]::IsNullOrWhiteSpace($s.outputFolder)) {
            [System.Windows.Forms.MessageBox]::Show('Choose an output folder first, or save next to the original files.', 'Video Compressor') | Out-Null
            return
        }
        $todo = @($state.Items | Where-Object { $null -ne $_.Info -and $null -ne $_.Plan -and -not $_.Plan.Skip -and $_.Status -notlike 'Done*' })
        if ($todo.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Nothing to do. Add some videos first.', 'Video Compressor') | Out-Null
            return
        }
        Save-Settings $s
        $state.Cancel = $false
        Set-Busy $true
        $barAll.Value = 0
        $done = 0; $failed = 0; $over = 0
        $batch = [System.Diagnostics.Stopwatch]::StartNew()

        for ($n = 0; $n -lt $todo.Count; $n++) {
            if ($state.Cancel) { break }
            $item = $todo[$n]
            $item.Status = 'Starting...'
            Update-Row $item
            $item.Row.EnsureVisible()
            $barFile.Value = 0
            $outPath = Get-OutputPath -InputPath $item.Path -Settings $s
            $state.OutputDir = Split-Path -Parent $outPath
            $current = $item
            $onProgress = {
                param($pct, $pass, $speed)
                $label = 'analysing'; if ($pass -eq 2) { $label = 'encoding' }
                $current.Status = ('{0} {1}% ({2})' -f $label, [int]$pct, $speed)
                $current.Row.SubItems[8].Text = $current.Status
                $barFile.Value = [int][math]::Max(0, [math]::Min(100, $pct))
                $fileFraction = (($pass - 1) + ($pct / 100.0)) / 2.0
                $barAll.Value = [int][math]::Min(100, (($n + $fileFraction) / $todo.Count) * 100)
                $lblStatus.Text = ('File {0} of {1}: {2}  (pass {3} of 2, {4})' -f ($n + 1), $todo.Count, $current.Info.FileName, $pass, $speed)
                [System.Windows.Forms.Application]::DoEvents()
            }.GetNewClosure()
            $shouldCancel = { [System.Windows.Forms.Application]::DoEvents(); return $state.Cancel }.GetNewClosure()
            try {
                $result = Invoke-TwoPassEncode -Info $item.Info -Plan $item.Plan -OutputPath $outPath -Settings $s -OnProgress $onProgress -ShouldCancel $shouldCancel
                $item.Result = $result
                switch ($result.Status) {
                    'Done'      { $done++; $item.Status = "Done: $(Format-Bytes $result.SizeBytes)" }
                    'OverLimit' { $over++; $item.Status = "Still $(Format-Bytes $result.SizeBytes) (over)" }
                    'Cancelled' { $item.Status = 'Cancelled' }
                    default     { $failed++; $item.Status = $result.Status }
                }
            } catch {
                $failed++
                $item.Status = "Failed: $($_.Exception.Message)".Split("`n")[0]
                $item.Row.ToolTipText = $_.Exception.Message
                Write-Log "FAILED '$($item.Path)': $($_.Exception.Message)"
            }
            Update-Row $item
        }

        Set-Busy $false
        $barFile.Value = 0
        $elapsed = [math]::Round($batch.Elapsed.TotalMinutes, 1)
        if ($state.CloseRequested) {
            $form.Close()
            return
        }
        if ($state.Cancel) {
            $lblStatus.Text = "Cancelled. $done file(s) finished before stopping."
        } else {
            $barAll.Value = 100
            $msg = "Finished in $elapsed min: $done compressed"
            if ($over -gt 0)   { $msg += ", $over still over the limit" }
            if ($failed -gt 0) { $msg += ", $failed failed (see logs folder)" }
            $lblStatus.Text = $msg + '.'
        }
    }

    # ------------------------------------------------------------------ events
    $dragEnter = {
        if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy }
    }
    $dragDrop = {
        $paths = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
        Add-Paths $paths
    }
    $form.Add_DragEnter($dragEnter); $form.Add_DragDrop($dragDrop)
    $list.Add_DragEnter($dragEnter); $list.Add_DragDrop($dragDrop)

    $btnAdd.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Multiselect = $true
        $dlg.Title = 'Choose videos to compress'
        $dlg.Filter = 'Videos|*.mp4;*.mov;*.m4v;*.mkv;*.avi;*.wmv;*.webm;*.mts;*.m2ts;*.ts;*.3gp;*.flv;*.mpg;*.mpeg;*.mxf;*.vob|All files|*.*'
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { Add-Paths $dlg.FileNames }
    })
    $btnRemove.Add_Click({
        $selected = @($list.SelectedItems | ForEach-Object { $_ })
        foreach ($row in $selected) {
            $victim = $null
            foreach ($item in $state.Items) { if ($item.Row -eq $row) { $victim = $item; break } }
            if ($victim) { $state.Items.Remove($victim) }
            $list.Items.Remove($row)
        }
        Update-Plans
    })
    $btnClear.Add_Click({ $list.Items.Clear(); $state.Items.Clear(); Update-Plans })
    $btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Where should the compressed videos go?'
        if ($txtOut.Text -and (Test-Path -LiteralPath $txtOut.Text)) { $dlg.SelectedPath = $txtOut.Text }
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtOut.Text = $dlg.SelectedPath
            $cboOut.SelectedIndex = 1
        }
    })
    $btnOpen.Add_Click({
        $dir = $state.OutputDir
        if (-not $dir -and $state.Items.Count -gt 0) {
            Sync-SettingsFromUi
            if ($state.Settings.outputMode -eq 'folder' -and $state.Settings.outputFolder) { $dir = $state.Settings.outputFolder }
            else { $dir = Split-Path -Parent $state.Items[0].Path }
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) { Start-Process explorer.exe -ArgumentList "`"$dir`"" }
    })
    $btnStart.Add_Click({ Start-Batch })
    $btnCancel.Add_Click({
        $state.Cancel = $true
        $btnCancel.Enabled = $false
        $lblStatus.Text = 'Cancelling after the current progress tick...'
    })
    foreach ($c in @($cboCodec, $cboSpeed, $cboMaxRes, $cboOut)) { $c.Add_SelectedIndexChanged({ Update-Plans }) }
    $numTarget.Add_ValueChanged({ Update-Plans })
    $chkSmall.Add_CheckedChanged({ Update-Plans })
    $form.Add_FormClosing({
        if ($state.Running) {
            # Let the batch loop unwind cleanly, then close from Start-Batch.
            $state.Cancel = $true
            $state.CloseRequested = $true
            $_.Cancel = $true
            $lblStatus.Text = 'Stopping, the window will close in a moment...'
            Stop-ChildFFmpeg
        }
    })
    $form.Add_Shown({
        $form.Activate()
        if ($Files -and $Files.Count -gt 0) { Add-Paths $Files }
    })

    [void]$form.ShowDialog()
    $form.Dispose()
}
