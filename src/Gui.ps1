# src/Gui.ps1
# The window. Uses Windows Forms from the .NET Framework that is built into Windows 10/11,
# so nothing has to be installed. Dot-sourced by Main.ps1 only when that is available.
#
# Design notes
# - All mutable state lives in the $state hashtable so event handlers (which run in child scopes)
#   can change it.
# - Encoding runs on the UI thread; ffmpeg's progress lines arrive every half second and each one
#   pumps the message loop with DoEvents, which keeps the window responsive and lets Cancel work.
# - The encoder callbacks are plain script blocks that call top-level functions (no closures, see
#   the notes above Update-GuiProgress), and the text they show is produced by plain functions
#   that tests can call without a window.
# - Show-CompressorWindow takes an optional -Automation script block. When given, the window is
#   built but not shown, and the script is handed an object to drive it. The tests use this on
#   Windows to click through a real batch.

function Get-GuiProgressText {
    # All the words the progress area shows for one progress tick.
    param($Snapshot, [int]$Pass, [double]$Percent, [int]$Index, [int]$Total, [double]$Quality, [string]$Speed, [string]$FileName)
    $label = 'analysing'
    if ($Pass -eq 2 -or $Pass -eq 0) { $label = 'encoding' }
    if ($Pass -eq 0) { $where = 'quality RF ' + [math]::Round($Quality) } else { $where = "pass $Pass of 2" }
    return @{
        RowStatus = ('{0} {1}% ({2})' -f $label, [int]$Percent, $Speed)
        CapFile   = ('Current file: {0} %' -f [int][math]::Round($Snapshot.FilePercent))
        CapAll    = ('Whole queue: file {0} of {1}, {2} %' -f ($Index + 1), $Total, [int][math]::Round($Snapshot.QueuePercent))
        DetFile   = (Format-EtaLine $Snapshot.FileElapsed $Snapshot.FileRemaining)
        DetAll    = (Format-EtaLine $Snapshot.QueueElapsed $Snapshot.QueueRemaining)
        Status    = ('File {0} of {1}: {2}  ({3}, {4})' -f ($Index + 1), $Total, $FileName, $where, $Speed)
    }
}

# Progress and cancel callbacks. These are deliberately NOT closures. A closure only captures the
# variables of the function that creates it (that caused "The property 'Value' cannot be found" in
# the first release), and in some PowerShell versions it cannot call this script's functions either.
# Instead Start-Batch stores the context for the current file in script-scope variables, and the
# script blocks it hands to the encoder are plain one-liners that call the functions below.
$script:GuiProgress = $null
$script:GuiCancel = $null

function Set-GuiProgressContext {
    # $Ui is a hashtable with the controls BarFile, BarAll, CapFile, CapAll, DetFile, DetAll, Status,
    # a Pump script block that lets the window repaint, and LastError.
    param($Ui, $Item, [int]$Index, [int]$Total, [double]$Quality, $Tracker)
    $script:GuiProgress = @{ Ui = $Ui; Item = $Item; Index = $Index; Total = $Total; Quality = $Quality; Tracker = $Tracker }
}

function Set-GuiCancelContext {
    param($Ui, $State)
    $script:GuiCancel = @{ Ui = $Ui; State = $State }
}

function Update-GuiProgress {
    param($pct, $pass, $speed)
    $c = $script:GuiProgress
    if ($null -eq $c) { return }
    $Ui = $c.Ui
    try {
        Update-EtaProgress -Tracker $c.Tracker -Pass $pass -Percent $pct
        $snap = Get-EtaSnapshot -Tracker $c.Tracker
        $t = Get-GuiProgressText -Snapshot $snap -Pass $pass -Percent $pct -Index $c.Index -Total $c.Total -Quality $c.Quality -Speed $speed -FileName $c.Item.Info.FileName
        $c.Item.Status = $t.RowStatus
        $c.Item.Row.SubItems[8].Text = $t.RowStatus
        $Ui.BarFile.Value = [int][math]::Max(0, [math]::Min(100, $snap.FilePercent))
        $Ui.BarAll.Value  = [int][math]::Max(0, [math]::Min(100, $snap.QueuePercent))
        $Ui.CapFile.Text  = $t.CapFile
        $Ui.CapAll.Text   = $t.CapAll
        $Ui.DetFile.Text  = $t.DetFile
        $Ui.DetAll.Text   = $t.DetAll
        $Ui.Status.Text   = $t.Status
        & $Ui.Pump
    } catch {
        # A cosmetic update must never abort an encode. The batch loop logs this afterwards.
        $Ui.LastError = $_.Exception.Message
    }
}

function Test-GuiCancelRequested {
    $c = $script:GuiCancel
    if ($null -eq $c) { return $false }
    try { & $c.Ui.Pump } catch { }
    return [bool]$c.State.Cancel
}

function Set-GuiIdle {
    # Progress area when nothing is running.
    param($Ui)
    $Ui.BarFile.Value = 0
    $Ui.BarAll.Value = 0
    $Ui.CapFile.Text = 'Current file'
    $Ui.CapAll.Text = 'Whole queue'
    $Ui.DetFile.Text = ''
    $Ui.DetAll.Text = ''
}

function Show-CompressorWindow {
    param([string[]]$Files, $Settings, [scriptblock]$Automation = $null)

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $state = @{
        Items          = New-Object System.Collections.ArrayList   # hashtables: Path, Info, Plan, Row, Status, Result
        Running        = $false
        Cancel         = $false
        CloseRequested = $false
        Settings       = $Settings
        OutputDir      = ''
        ActiveBox      = $null     # the template box the Variables menu inserts into
    }

    # ------------------------------------------------------------------ form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Video Compressor'
    $form.Size = New-Object System.Drawing.Size(1000, 700)
    $form.MinimumSize = New-Object System.Drawing.Size(880, 560)
    $form.StartPosition = 'CenterScreen'
    $form.AllowDrop = $true
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    # ------------------------------------------------------------------ options (top)
    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 172
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

    $y1 = 10; $y2 = 44; $y3 = 78; $y4 = 110; $y5 = 142

    # Row 1: size, codec, speed, resolution
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
    $resOptions = @(0, 1080, 720)
    $resIndex = [array]::IndexOf($resOptions, [int]$Settings.maxHeight); if ($resIndex -lt 0) { $resIndex = 0 }
    $cboMaxRes = Add-Combo $top @('Auto', '1080p', '720p') 785 $y1 90 $resIndex

    # Row 2: quality
    Add-Label $top 'Quality (RF)' 10 ($y2 + 4) | Out-Null
    $numQuality = New-Object System.Windows.Forms.NumericUpDown
    $numQuality.Minimum = 18; $numQuality.Maximum = 45; $numQuality.DecimalPlaces = 0
    $numQuality.Value = [decimal][math]::Min(45, [math]::Max(18, [math]::Round([double]$Settings.quality)))
    $numQuality.Location = New-Object System.Drawing.Point(100, $y2); $numQuality.Width = 70
    $top.Controls.Add($numQuality)
    $lblQuality = Add-Label $top 'Lower = better looking but bigger (30 to 35 is typical). The size limit always wins.' 180 ($y2 + 4)
    $lblQuality.ForeColor = [System.Drawing.SystemColors]::GrayText
    $chkFill = New-Object System.Windows.Forms.CheckBox
    $chkFill.Text = 'Use the full size limit (two-pass)'
    $chkFill.AutoSize = $true
    $chkFill.Checked = ("$($Settings.mode)".ToLowerInvariant() -eq 'fill')
    $chkFill.Location = New-Object System.Drawing.Point(690, ($y2 + 2))
    $top.Controls.Add($chkFill)

    # Row 3: output folder template
    Add-Label $top 'Output folder' 10 ($y3 + 4) | Out-Null
    $txtOut = New-Object System.Windows.Forms.TextBox
    $txtOut.Text = [string]$Settings.outputFolder
    $txtOut.Location = New-Object System.Drawing.Point(100, $y3); $txtOut.Width = 420
    $top.Controls.Add($txtOut)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Browse...'; $btnBrowse.Location = New-Object System.Drawing.Point(526, ($y3 - 1)); $btnBrowse.Width = 80
    $top.Controls.Add($btnBrowse)
    $btnVars = New-Object System.Windows.Forms.Button
    $btnVars.Text = 'Variables...'; $btnVars.Location = New-Object System.Drawing.Point(612, ($y3 - 1)); $btnVars.Width = 90
    $top.Controls.Add($btnVars)
    $chkSmall = New-Object System.Windows.Forms.CheckBox
    $chkSmall.Text = 'Also re-encode files already under the limit'
    $chkSmall.AutoSize = $true
    $chkSmall.Checked = -not [bool]$Settings.skipIfAlreadyUnderLimit
    $chkSmall.Location = New-Object System.Drawing.Point(715, ($y3 + 2))
    $top.Controls.Add($chkSmall)

    # Row 4: file name template
    Add-Label $top 'File name' 10 ($y4 + 4) | Out-Null
    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.Text = [string]$Settings.fileName
    $txtName.Location = New-Object System.Drawing.Point(100, $y4); $txtName.Width = 420
    $top.Controls.Add($txtName)
    Add-Label $top '.mp4' 526 ($y4 + 4) | Out-Null

    # Row 5: live example of where the next file will go
    $lblExample = New-Object System.Windows.Forms.Label
    $lblExample.AutoSize = $false
    $lblExample.Location = New-Object System.Drawing.Point(10, $y5); $lblExample.Size = New-Object System.Drawing.Size(960, 20)
    $lblExample.Anchor = 'Top,Left,Right'
    $lblExample.ForeColor = [System.Drawing.SystemColors]::GrayText
    $top.Controls.Add($lblExample)

    $tips = New-Object System.Windows.Forms.ToolTip
    $tips.SetToolTip($txtOut, 'Folder for the compressed videos. A relative name such as Encoded is created next to each original; a full path such as D:\Compressed\{date} is used as is. Leave empty to save next to the original. Variables in {braces} are replaced.')
    $tips.SetToolTip($txtName, 'File name without the extension. Variables in {braces} are replaced, for example {source}_{height}p. An existing file is never overwritten; a number is added instead.')

    # The Variables menu: click a variable to insert it where the cursor is.
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($v in (Get-TemplateVariables)) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem
        $mi.Text = ('{{{0}}}    e.g. {1}    ({2})' -f $v.Name, $v.Example, $v.Help)
        $mi.Tag = '{' + $v.Name + '}'
        $mi.Add_Click({
            $box = $state.ActiveBox
            if ($null -eq $box) { $box = $txtName }
            $box.SelectedText = [string]$this.Tag
            $box.Focus()
        })
        [void]$menu.Items.Add($mi)
    }
    $state.ActiveBox = $txtName

    # ------------------------------------------------------------------ bottom: buttons + progress
    $bottom = New-Object System.Windows.Forms.Panel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 152
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
    $lblStatus.Location = New-Object System.Drawing.Point(10, 44); $lblStatus.Size = New-Object System.Drawing.Size(960, 20)
    $lblStatus.Anchor = 'Top,Left,Right'
    $lblStatus.Text = 'Drop videos or folders anywhere on this window, or click "Add videos...".'
    $bottom.Controls.Add($lblStatus)

    # Two labelled progress bars side by side: this file, and the whole queue. Each has a caption
    # above it (with the percentage) and a line below it (elapsed time and time remaining).
    $tbl = New-Object System.Windows.Forms.TableLayoutPanel
    $tbl.Location = New-Object System.Drawing.Point(10, 68)
    $tbl.Size = New-Object System.Drawing.Size(960, 76)
    $tbl.Anchor = 'Top,Left,Right'
    $tbl.ColumnCount = 2
    $tbl.RowCount = 3
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    [void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    $bottom.Controls.Add($tbl)

    function New-CaptionLabel {
        param([bool]$Bold)
        $l = New-Object System.Windows.Forms.Label
        $l.Dock = 'Fill'; $l.AutoSize = $false; $l.TextAlign = 'MiddleLeft'
        if ($Bold) { $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold) }
        return $l
    }
    $capFile = New-CaptionLabel $true;  $capAll = New-CaptionLabel $true
    $detFile = New-CaptionLabel $false; $detAll = New-CaptionLabel $false
    $barFile = New-Object System.Windows.Forms.ProgressBar
    $barFile.Dock = 'Fill'; $barFile.Margin = New-Object System.Windows.Forms.Padding(3, 2, 10, 2)
    $barAll = New-Object System.Windows.Forms.ProgressBar
    $barAll.Dock = 'Fill'; $barAll.Margin = New-Object System.Windows.Forms.Padding(10, 2, 3, 2)
    $tbl.Controls.Add($capFile, 0, 0); $tbl.Controls.Add($capAll, 1, 0)
    $tbl.Controls.Add($barFile, 0, 1); $tbl.Controls.Add($barAll, 1, 1)
    $tbl.Controls.Add($detFile, 0, 2); $tbl.Controls.Add($detAll, 1, 2)

    # Controls and helpers that the encoder callbacks need, handed over explicitly.
    $ui = @{
        BarFile   = $barFile
        BarAll    = $barAll
        CapFile   = $capFile
        CapAll    = $capAll
        DetFile   = $detFile
        DetAll    = $detAll
        Status    = $lblStatus
        Pump      = { [System.Windows.Forms.Application]::DoEvents() }
        LastError = ''
    }
    Set-GuiIdle $ui

    # ------------------------------------------------------------------ list (fill)
    $list = New-Object System.Windows.Forms.ListView
    $list.Dock = 'Fill'
    $list.View = 'Details'
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    $list.AllowDrop = $true
    $list.ShowItemToolTips = $true
    foreach ($col in @(@('File', 210), @('Length', 55), @('Source', 130), @('Output', 120), @('Video', 80), @('Audio', 90), @('Est. size', 90), @('Quality', 55), @('Status', 170))) {
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
        $s.outputFolder = $txtOut.Text.Trim()
        $s.fileName = $txtName.Text.Trim()
        $s.skipIfAlreadyUnderLimit = -not $chkSmall.Checked
        $s.quality = [double]$numQuality.Value
        $s.mode = 'quality'; if ($chkFill.Checked) { $s.mode = 'fill' }
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
            if ($state.Settings.mode -eq 'fill') {
                $row.SubItems[4].Text = "$($plan.VideoKbps) kbps"
                $row.SubItems[6].Text = Format-Bytes $plan.EstimatedBytes
            } else {
                $row.SubItems[4].Text = "RF $([math]::Round([double]$state.Settings.quality))"
                $row.SubItems[6].Text = 'up to ' + (Format-Bytes $plan.EstimatedBytes)
            }
            $audio = 'none'
            if ($plan.AudioKbps -gt 0) { $ch = 'stereo'; if ($plan.AudioChannels -eq 1) { $ch = 'mono' }; $audio = "$($plan.AudioKbps) kbps $ch" }
            $row.SubItems[5].Text = $audio
            $row.SubItems[7].Text = $plan.Grade
            $row.SubItems[8].Text = $item.Status
            $tip = @($plan.Notes)
            if ($state.Settings.mode -ne 'fill') {
                $tip += "Encodes at quality RF $([math]::Round([double]$state.Settings.quality)) first and keeps that if it fits. If it is too big, it re-encodes at $($plan.VideoKbps) kbps; the quality grade describes that fallback."
            }
            $row.ToolTipText = ($tip -join "`n")
        }
        $grade = ''
        if ($null -ne $plan -and -not $plan.Skip) { $grade = $plan.Grade }
        switch ($grade) {
            'Poor' { $row.ForeColor = [System.Drawing.Color]::Firebrick }
            'OK'   { $row.ForeColor = [System.Drawing.Color]::DarkGoldenrod }
            default { $row.ForeColor = [System.Drawing.SystemColors]::WindowText }
        }
    }

    function Update-Example {
        # Shows where the selected file (or the first one, or a sample) would be saved.
        Sync-SettingsFromUi
        $s = $state.Settings
        $item = $null
        if ($list.SelectedItems.Count -gt 0) {
            foreach ($candidate in $state.Items) { if ($candidate.Row -eq $list.SelectedItems[0]) { $item = $candidate; break } }
        }
        if ($null -eq $item -and $state.Items.Count -gt 0) { $item = $state.Items[0] }
        if ($null -ne $item) { $path = $item.Path; $plan = $item.Plan }
        else { $path = 'C:\Videos\Holiday\Beach.mov'; $plan = [PSCustomObject]@{ OutWidth = 1280; OutHeight = 720 } }
        try {
            $loc = Resolve-OutputLocation -InputPath $path -Settings $s -Plan $plan -BatchTime (Get-Date)
            if (@($loc.Unknown | Where-Object { $_ }).Count -gt 0) {
                $lblExample.ForeColor = [System.Drawing.Color]::Firebrick
                $lblExample.Text = Get-UnknownVariableMessage $loc
            } else {
                $lblExample.ForeColor = [System.Drawing.SystemColors]::GrayText
                $lblExample.Text = 'Example: ' + $loc.Path
            }
        } catch {
            $lblExample.ForeColor = [System.Drawing.Color]::Firebrick
            $lblExample.Text = 'Example unavailable: ' + $_.Exception.Message
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
        Update-Example
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
        foreach ($c in @($numTarget, $cboCodec, $cboSpeed, $cboMaxRes, $txtOut, $txtName, $btnBrowse, $btnVars, $chkSmall, $numQuality, $chkFill, $btnAdd, $btnRemove, $btnClear, $btnStart)) { $c.Enabled = -not $Busy }
        $btnCancel.Enabled = $Busy
        $form.AllowDrop = -not $Busy
        $list.AllowDrop = -not $Busy
    }

    function Start-Batch {
        Sync-SettingsFromUi
        $s = $state.Settings
        $todo = @($state.Items | Where-Object { $null -ne $_.Info -and $null -ne $_.Plan -and -not $_.Plan.Skip -and $_.Status -notlike 'Done*' })
        if ($todo.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show('Nothing to do. Add some videos first.', 'Video Compressor') | Out-Null
            return
        }
        $batchTime = Get-Date    # {date} and {time} in the output names are the same for the whole batch
        $check = Resolve-OutputLocation -InputPath $todo[0].Path -Settings $s -Plan $todo[0].Plan -BatchTime $batchTime
        if (@($check.Unknown | Where-Object { $_ }).Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show((Get-UnknownVariableMessage $check), 'Video Compressor') | Out-Null
            return
        }
        Save-Settings $s
        $state.Cancel = $false
        Set-Busy $true
        $done = 0; $failed = 0; $over = 0
        $durations = New-Object System.Collections.Generic.List[double]
        foreach ($t in $todo) { $durations.Add([double]$t.Info.DurationSec) }
        $tracker = New-EtaTracker -Durations $durations.ToArray() -Mode "$($s.mode)"

        try {
            for ($n = 0; $n -lt $todo.Count; $n++) {
                if ($state.Cancel) { break }
                $item = $todo[$n]
                $item.Status = 'Starting...'
                Update-Row $item
                $item.Row.EnsureVisible()
                Start-EtaFile -Tracker $tracker -Index $n
                $learn = $false
                try {
                    $outPath = Get-OutputPath -InputPath $item.Path -Settings $s -Plan $item.Plan -BatchTime $batchTime
                    $state.OutputDir = Split-Path -Parent $outPath
                    Set-GuiProgressContext -Ui $ui -Item $item -Index $n -Total $todo.Count -Quality ([double]$s.quality) -Tracker $tracker
                    Set-GuiCancelContext -Ui $ui -State $state
                    $onProgress = { param($pct, $pass, $speed) Update-GuiProgress $pct $pass $speed }
                    $shouldCancel = { Test-GuiCancelRequested }
                    $result = Invoke-CompressVideo -Info $item.Info -Plan $item.Plan -OutputPath $outPath -Settings $s -OnProgress $onProgress -ShouldCancel $shouldCancel
                    $item.Result = $result
                    $learn = ($result.Status -eq 'Done')
                    switch ($result.Status) {
                        'Done'      {
                            $done++
                            if ($result.Method -eq 'quality') { $item.Status = "Done: $(Format-Bytes $result.SizeBytes) (RF $($result.Crf))" }
                            else { $item.Status = "Done: $(Format-Bytes $result.SizeBytes) (fitted to limit)" }
                        }
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
                Complete-EtaFile -Tracker $tracker -Learn:$learn
                Update-Row $item

                # Between files: show the queue as it stands, with the current-file bar reset.
                $snap = Get-EtaSnapshot -Tracker $tracker
                $ui.BarFile.Value = 0
                $ui.BarAll.Value = [int][math]::Max(0, [math]::Min(100, $snap.QueuePercent))
                $ui.CapFile.Text = 'Current file'
                $ui.DetFile.Text = ''
                $ui.CapAll.Text = ('Whole queue: {0} of {1} done, {2} %' -f ($n + 1), $todo.Count, [int][math]::Round($snap.QueuePercent))
                $ui.DetAll.Text = Format-EtaLine $snap.QueueElapsed $snap.QueueRemaining
                if ($ui.LastError) {
                    Write-Log "Window update problem (encoding was not affected): $($ui.LastError)"
                    $ui.LastError = ''
                }
            }
        } finally {
            Set-Busy $false
        }

        $total = Get-EtaSnapshot -Tracker $tracker
        if ($state.CloseRequested) {
            $form.Close()
            return
        }
        $elapsedText = Format-Clock $total.QueueElapsed
        $ui.BarFile.Value = 0
        $ui.CapFile.Text = 'Current file'
        $ui.DetFile.Text = ''
        if ($state.Cancel) {
            $lblStatus.Text = "Cancelled after $elapsedText. $done file(s) finished before stopping."
            $ui.CapAll.Text = 'Whole queue: cancelled'
        } else {
            $ui.BarAll.Value = 100
            $msg = "Finished in ${elapsedText}: $done compressed"
            if ($over -gt 0)   { $msg += ", $over still over the limit" }
            if ($failed -gt 0) { $msg += ", $failed failed (see logs folder)" }
            $lblStatus.Text = $msg + '.'
            $ui.CapAll.Text = 'Whole queue: finished, 100 %'
        }
        $ui.DetAll.Text = "Elapsed $elapsedText"
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
        $dlg.Description = 'Where should the compressed videos go? (You can still add variables to the path afterwards.)'
        if ($txtOut.Text -and [System.IO.Path]::IsPathRooted($txtOut.Text) -and (Test-Path -LiteralPath $txtOut.Text)) { $dlg.SelectedPath = $txtOut.Text }
        if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $txtOut.Text = $dlg.SelectedPath }
    })
    $btnVars.Add_Click({ $menu.Show($btnVars, (New-Object System.Drawing.Point(0, $btnVars.Height))) })
    $txtOut.Add_Enter({ $state.ActiveBox = $txtOut })
    $txtName.Add_Enter({ $state.ActiveBox = $txtName })
    $txtOut.Add_TextChanged({ Update-Example })
    $txtName.Add_TextChanged({ Update-Example })
    $list.Add_SelectedIndexChanged({ Update-Example })
    $btnOpen.Add_Click({
        $dir = $state.OutputDir
        if (-not $dir -and $state.Items.Count -gt 0) {
            Sync-SettingsFromUi
            $first = $state.Items[0]
            $loc = Resolve-OutputLocation -InputPath $first.Path -Settings $state.Settings -Plan $first.Plan -BatchTime (Get-Date)
            $dir = $loc.Folder
        }
        if ($dir -and (Test-Path -LiteralPath $dir)) { Start-Process explorer.exe -ArgumentList "`"$dir`"" }
        else { $lblStatus.Text = 'Nothing has been saved to that folder yet.' }
    })
    $btnStart.Add_Click({ Start-Batch })
    $btnCancel.Add_Click({
        $state.Cancel = $true
        $btnCancel.Enabled = $false
        $lblStatus.Text = 'Cancelling after the current progress tick...'
    })
    foreach ($c in @($cboCodec, $cboSpeed, $cboMaxRes)) { $c.Add_SelectedIndexChanged({ Update-Plans }) }
    $numTarget.Add_ValueChanged({ Update-Plans })
    $chkSmall.Add_CheckedChanged({ Update-Plans })
    $chkFill.Add_CheckedChanged({ Update-Plans })
    $numQuality.Add_ValueChanged({ Update-Plans })
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

    Update-Example

    if ($null -ne $Automation) {
        # Test mode: build the window, do not show it, and let the script drive it. The script blocks
        # below are created here, so they can reach this function's controls and helpers.
        $api = @{
            State      = $state
            Ui         = $ui
            Form       = $form
            Controls   = @{
                OutputFolder = $txtOut; FileName = $txtName; Example = $lblExample; Status = $lblStatus
                Quality = $numQuality; Target = $numTarget; Fill = $chkFill; Start = $btnStart; Cancel = $btnCancel
                BarFile = $barFile; BarAll = $barAll; CapFile = $capFile; CapAll = $capAll; DetFile = $detFile; DetAll = $detAll
                Menu = $menu; List = $list
            }
            AddPaths   = { param($paths) Add-Paths $paths }
            StartBatch = { Start-Batch }
            Refresh    = { Update-Plans }
        }
        try { & $Automation $api } finally { $form.Dispose() }
        return
    }

    [void]$form.ShowDialog()
    $form.Dispose()
}
