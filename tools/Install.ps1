<#
.SYNOPSIS
    Installs Video Compressor on this computer so it no longer needs a flash drive.

.DESCRIPTION
    Copies the app to a folder you can write to, checks that Windows lets it run from there, then
    adds a Desktop shortcut and a right-click "Send to" entry. No admin rights, no registry changes.

    Run it by double-clicking Install.bat. Running it again over an existing install is safe: your
    settings and logs are kept and the program files are replaced.

    Without -Target it tries these folders in order and uses the first that works:
      1. %LOCALAPPDATA%\Video Compressor
      2. %USERPROFILE%\Video Compressor
      3. Documents\Video Compressor

.PARAMETER Target
    Install into exactly this folder instead of trying the list above.
.PARAMETER Uninstall
    Remove the shortcuts and the install folder (run from the installed copy by Uninstall.bat).
.PARAMETER NoDesktop, NoSendTo
    Skip that shortcut.
.PARAMETER Yes
    Do not ask for confirmation (used by tests).
.PARAMETER Candidates, DesktopDir, SendToDir, NoSmokeTest
    For tests: folders to try (several joined with |), where shortcuts go, and skipping the
    "does it run here" check.
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [string[]]$Candidates = @(),
    [string]$DesktopDir = '',
    [string]$SendToDir = '',
    [switch]$NoDesktop,
    [switch]$NoSendTo,
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$NoSmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# -File cannot pass several values to an array parameter, so folders may also be joined with '|',
# a character Windows does not allow in paths.
$Candidates = @(@($Candidates) | ForEach-Object { $_ -split '\|' } | Where-Object { $_ })

$script:AppName = 'Video Compressor'
$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')
$script:Sep = [string][System.IO.Path]::DirectorySeparatorChar

# ------------------------------------------------------------------ helpers

function Get-FullPathTrimmed {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    return $full
}

function Test-SamePath {
    param([string]$A, [string]$B)
    return ([string]::Equals((Get-FullPathTrimmed $A), (Get-FullPathTrimmed $B), [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-IsInside {
    # True if $Child is the same as, or inside, $Parent.
    param([string]$Child, [string]$Parent)
    $c = Get-FullPathTrimmed $Child
    $p = Get-FullPathTrimmed $Parent
    if ([string]::Equals($c, $p, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $c.StartsWith($p.TrimEnd('\', '/') + $script:Sep, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-LooksLikeThisApp {
    param([string]$Folder)
    return ((Test-Path -LiteralPath (Join-Path $Folder 'Compress-Videos.bat')) -and
            (Test-Path -LiteralPath (Join-Path (Join-Path $Folder 'src') 'Main.ps1')))
}

function Get-SpecialFolder {
    param([string]$Name)
    try { return [Environment]::GetFolderPath($Name) } catch { return '' }
}

function Get-DefaultCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    if ($env:LOCALAPPDATA) { $list.Add((Join-Path $env:LOCALAPPDATA $script:AppName)) }
    if ($env:USERPROFILE)  { $list.Add((Join-Path $env:USERPROFILE $script:AppName)) }
    $docs = Get-SpecialFolder 'MyDocuments'
    if ($docs) { $list.Add((Join-Path $docs $script:AppName)) }
    if ($list.Count -eq 0 -and $env:HOME) { $list.Add((Join-Path $env:HOME $script:AppName)) }
    return $list.ToArray()
}

function Get-TargetProblem {
    # Returns why a folder must not be used, or '' if it is fine.
    param([string]$Folder, [string]$SourceRoot)
    if ([string]::IsNullOrWhiteSpace($Folder)) { return 'no folder given' }
    try { $full = Get-FullPathTrimmed $Folder } catch { return "not a valid folder name ($($_.Exception.Message))" }

    $root = [System.IO.Path]::GetPathRoot($full)
    if ($root -and [string]::Equals($full.TrimEnd('\', '/'), $root.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return 'a drive root cannot be used'
    }
    foreach ($guard in @($env:windir, $env:USERPROFILE, (Get-SpecialFolder 'Desktop'), (Get-SpecialFolder 'MyDocuments'), $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($guard -and (Test-SamePath $full $guard)) { return "'$guard' itself cannot be used, choose a sub-folder" }
    }
    if ($env:windir -and (Test-IsInside $full $env:windir)) { return 'the Windows folder cannot be used' }
    if (Test-IsInside $full $SourceRoot) { return 'that is the folder being installed from' }
    if (Test-IsInside $SourceRoot $full) { return 'it contains the folder being installed from' }

    if (Test-Path -LiteralPath $full -PathType Leaf) { return 'a file with that name already exists' }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $items = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0 -and -not (Test-LooksLikeThisApp $full)) {
            return 'the folder already holds other files (it is not an earlier install of this app)'
        }
    }
    return ''
}

function Copy-AppFiles {
    param([string]$Source, [string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null

    foreach ($f in 'Compress-Videos.bat', 'README.md', 'LICENSE') {
        $from = Join-Path $Source $f
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $Dest $f) -Force }
    }
    # Program folders are replaced as a whole so files removed in a newer version do not linger.
    foreach ($d in 'src', 'tools') {
        $from = Join-Path $Source $d
        $to = Join-Path $Dest $d
        if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $to -Recurse -Force }
    }
    $binFrom = Join-Path $Source 'bin'
    $binTo = Join-Path $Dest 'bin'
    New-Item -ItemType Directory -Path $binTo -Force | Out-Null
    if (Test-Path -LiteralPath $binFrom) {
        foreach ($file in Get-ChildItem -LiteralPath $binFrom -File -Force) {
            if ($file.Name -eq '.gitkeep') { continue }
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $binTo $file.Name) -Force
        }
    }
    # Settings are copied only the first time, so an update never resets your choices.
    $settingsFrom = Join-Path $Source 'settings.json'
    $settingsTo = Join-Path $Dest 'settings.json'
    if ((Test-Path -LiteralPath $settingsFrom) -and -not (Test-Path -LiteralPath $settingsTo)) {
        Copy-Item -LiteralPath $settingsFrom -Destination $settingsTo
    }
    New-Item -ItemType Directory -Path (Join-Path $Dest 'logs') -Force | Out-Null
}

function Remove-DownloadMark {
    # Files from a downloaded zip carry a "came from the internet" mark that makes Windows nag.
    param([string]$Folder)
    if (-not (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { return }
    try { Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | Unblock-File -ErrorAction SilentlyContinue } catch { }
}

function Test-RunsFromHere {
    # Proves Windows lets ffmpeg and the app's own script run from this folder. Throws a readable
    # message if not.
    param([string]$Folder)
    $ffmpeg = Join-Path (Join-Path $Folder 'bin') 'ffmpeg.exe'
    if (Test-Path -LiteralPath $ffmpeg) {
        try {
            $out = & $ffmpeg -version 2>&1
            if ($LASTEXITCODE -ne 0) { throw "ffmpeg.exe exited with code $LASTEXITCODE" }
        } catch {
            throw "Windows would not run ffmpeg.exe from this folder ($($_.Exception.Message))"
        }
    } elseif ($script:IsWindowsHost) {
        throw 'bin\ffmpeg.exe is missing from the copy being installed'
    }

    $hostExe = 'powershell.exe'
    if (-not $script:IsWindowsHost) { $hostExe = (Get-Process -Id $PID).Path }
    $main = Join-Path (Join-Path $Folder 'src') 'Main.ps1'
    try {
        $procArgs = @('-NoProfile')
        if ($script:IsWindowsHost) { $procArgs += @('-ExecutionPolicy', 'Bypass') }
        $procArgs += @('-File', $main, '-NoGui', '-NoPause')
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $text = (& $hostExe @procArgs 2>&1 | ForEach-Object { "$_" }) -join "`n"
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($code -ne 0 -or $text -notmatch 'No videos given') { throw "the app did not start cleanly (exit code $code): $text" }
    } catch {
        throw "Windows would not start the app's scripts from this folder ($($_.Exception.Message))"
    }
}

function ConvertTo-CmdPath {
    # Keeps the fallback .cmd file pure ASCII where possible by using environment variables.
    param([string]$Path)
    foreach ($pair in @(@('LOCALAPPDATA', $env:LOCALAPPDATA), @('USERPROFILE', $env:USERPROFILE))) {
        $value = $pair[1]
        if ($value -and $Path.StartsWith($value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return ('%' + $pair[0] + '%' + $Path.Substring($value.Length))
        }
    }
    return $Path
}

function New-AppShortcut {
    # Makes a .lnk shortcut; if the PC blocks that, a tiny .cmd launcher with the same effect.
    # Returns the path of what was created.
    param([string]$Path, [string]$TargetBat, [string]$WorkDir)
    if ($script:IsWindowsHost) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $lnk = $shell.CreateShortcut($Path)
            $lnk.TargetPath = $TargetBat
            $lnk.WorkingDirectory = $WorkDir
            $lnk.Description = 'Compress videos to a size limit'
            $lnk.Save()
            return $Path
        } catch { }
    }
    $cmdPath = [System.IO.Path]::ChangeExtension($Path, '.cmd')
    $shown = ConvertTo-CmdPath $TargetBat
    $text = "@echo off`r`ncall `"$shown`" %*`r`n"
    if ($text -match '[^\x00-\x7F]') { Write-Warning 'The shortcut file contains non-English characters and may not work; use the Desktop icon from the Start menu instead.' }
    [System.IO.File]::WriteAllText($cmdPath, $text, [System.Text.Encoding]::ASCII)
    return $cmdPath
}

function Get-ShortcutPaths {
    param([string]$Desktop, [string]$SendTo)
    $paths = @()
    foreach ($dir in @($Desktop, $SendTo)) {
        if (-not $dir) { continue }
        $paths += (Join-Path $dir "$($script:AppName).lnk")
        $paths += (Join-Path $dir "$($script:AppName).cmd")
    }
    return $paths
}

function Resolve-ShortcutDirs {
    $d = $DesktopDir
    if (-not $d) { $d = Get-SpecialFolder 'Desktop' }
    $s = $SendToDir
    if (-not $s -and $env:APPDATA) { $s = Join-Path (Join-Path (Join-Path $env:APPDATA 'Microsoft') 'Windows') 'SendTo' }
    return @{ Desktop = $d; SendTo = $s }
}

function Remove-ShortcutsFor {
    # Removes only shortcuts that point at this install.
    param([string]$Folder, [string]$Desktop, [string]$SendTo)
    $removed = @()
    $bat = Join-Path $Folder 'Compress-Videos.bat'
    foreach ($p in (Get-ShortcutPaths -Desktop $Desktop -SendTo $SendTo)) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $ours = $false
        if ($p -like '*.cmd') {
            $content = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
            $ours = ($content -and ($content.IndexOf((ConvertTo-CmdPath $bat), [System.StringComparison]::OrdinalIgnoreCase) -ge 0))
        } else {
            if ($script:IsWindowsHost) {
                try { $ours = Test-SamePath ((New-Object -ComObject WScript.Shell).CreateShortcut($p).TargetPath) $bat } catch { $ours = $true }
            } else { $ours = $true }
        }
        if ($ours) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; $removed += $p }
    }
    return $removed
}

# ------------------------------------------------------------------ main

function Invoke-Install {
    $source = Get-FullPathTrimmed (Split-Path -Parent $PSScriptRoot)
    if (-not (Test-LooksLikeThisApp $source)) {
        throw "This does not look like the Video Compressor folder (Compress-Videos.bat or src\Main.ps1 is missing next to the tools folder). Unzip the whole download first."
    }
    if ($script:IsWindowsHost -and -not $NoSmokeTest -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $source 'bin') 'ffmpeg.exe'))) {
        throw "This copy has no ffmpeg (bin\ffmpeg.exe). Use the Video-compressor-win64.zip from the GitHub Releases page, or run Compress-Videos.bat once on a computer with internet first."
    }

    Write-Host ''
    Write-Host "Installing $($script:AppName) on this computer" -ForegroundColor Cyan
    Write-Host "From: $source"

    $folders = @()
    if ($Target) { $folders = @($Target) }
    elseif (@($Candidates).Count -gt 0) { $folders = @($Candidates) }
    else { $folders = Get-DefaultCandidates }

    $installed = ''
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $folders) {
        Write-Host ''
        Write-Host "Trying $folder ..."
        $why = Get-TargetProblem -Folder $folder -SourceRoot $source
        if ($why) { Write-Host "  skipped: $why" -ForegroundColor Yellow; $problems.Add("${folder}: $why"); continue }

        $full = Get-FullPathTrimmed $folder
        $weCreatedIt = -not (Test-Path -LiteralPath $full)
        try {
            Copy-AppFiles -Source $source -Dest $full
            Remove-DownloadMark -Folder $full
            if (-not $NoSmokeTest) {
                Write-Host '  checking that Windows lets it run from here ...'
                Test-RunsFromHere -Folder $full
            }
            $installed = $full
            break
        } catch {
            $msg = $_.Exception.Message
            Write-Host "  did not work: $msg" -ForegroundColor Yellow
            $problems.Add("${folder}: $msg")
            if ($weCreatedIt -and (Test-Path -LiteralPath $full)) {
                # Only a folder this run created is cleaned up; an existing install is left alone.
                Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $installed) {
        Write-Host ''
        Write-Host 'Could not install on this computer.' -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  - $p" }
        Write-Host ''
        Write-Host 'If this says Windows would not run the program, the PC only allows programs to run from'
        Write-Host 'approved places. You can keep using the flash drive, or ask IT to allow one of the folders above.'
        return 1
    }

    # Uninstaller, written next to the app.
    $uninstallBat = Join-Path $installed 'Uninstall.bat'
    $batText = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tools\Install.ps1`" -Uninstall`r`nexit /b %ERRORLEVEL%`r`n"
    [System.IO.File]::WriteAllText($uninstallBat, $batText, [System.Text.Encoding]::ASCII)

    $dirs = Resolve-ShortcutDirs
    $bat = Join-Path $installed 'Compress-Videos.bat'
    $made = @()
    if (-not $NoDesktop -and $dirs.Desktop) {
        try {
            if (-not (Test-Path -LiteralPath $dirs.Desktop)) { New-Item -ItemType Directory -Path $dirs.Desktop -Force | Out-Null }
            $made += (New-AppShortcut -Path (Join-Path $dirs.Desktop "$($script:AppName).lnk") -TargetBat $bat -WorkDir $installed)
        } catch { Write-Host "  could not create the Desktop shortcut: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if (-not $NoSendTo -and $dirs.SendTo) {
        try {
            if (-not (Test-Path -LiteralPath $dirs.SendTo)) { New-Item -ItemType Directory -Path $dirs.SendTo -Force | Out-Null }
            $made += (New-AppShortcut -Path (Join-Path $dirs.SendTo "$($script:AppName).lnk") -TargetBat $bat -WorkDir $installed)
        } catch { Write-Host "  could not create the Send to entry: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host 'Installed.' -ForegroundColor Green
    Write-Host "  Location:   $installed"
    foreach ($m in $made) { Write-Host "  Shortcut:   $m" }
    if ($made | Where-Object { $_ -like '*SendTo*' }) {
        Write-Host '  Right-click videos or folders, choose Send to, then Video Compressor.'
    }
    Write-Host "  To remove:  run Uninstall.bat in $installed"
    Write-Host '  Your settings and logs are kept if you install a newer version over this one.'
    return 0
}

function Invoke-Uninstall {
    $root = Get-FullPathTrimmed (Split-Path -Parent $PSScriptRoot)
    if ($Target) { $root = Get-FullPathTrimmed $Target }
    if (-not (Test-LooksLikeThisApp $root)) {
        throw "Refusing to remove '$root': it does not look like an installed copy of $($script:AppName)."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Uninstall.bat'))) {
        throw "Refusing to remove '$root': it was not put there by the installer (no Uninstall.bat). To remove a portable copy, just delete its folder."
    }
    $dirs = Resolve-ShortcutDirs
    Write-Host ''
    Write-Host "This will remove $($script:AppName) from this computer:" -ForegroundColor Cyan
    Write-Host "  Folder: $root (including its settings and logs)"
    Write-Host '  Its Desktop shortcut and Send to entry'
    Write-Host 'Your compressed videos (the Encoded folders next to your originals) are not touched.'
    if (-not $Yes) {
        $answer = Read-Host 'Type Y and press Enter to continue'
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Nothing was removed.'; return 0 }
    }
    $removed = Remove-ShortcutsFor -Folder $root -Desktop $dirs.Desktop -SendTo $dirs.SendTo
    foreach ($r in $removed) { Write-Host "  removed $r" }

    if ($script:IsWindowsHost) {
        # This script and Uninstall.bat live inside the folder, so it is deleted a moment after they exit.
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', "timeout /t 6 /nobreak >nul & rmdir /s /q `"$root`"" -WindowStyle Hidden
        Write-Host '  the folder will be deleted in a few seconds'
        if (-not $Yes) { Start-Sleep -Seconds 4 }
    } else {
        Remove-Item -LiteralPath $root -Recurse -Force
        Write-Host "  removed $root"
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($Uninstall) { $code = @(Invoke-Uninstall)[-1] } else { $code = @(Invoke-Install)[-1] }
    } catch {
        Write-Host ''
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $code = 1
    }
    exit $code
}
