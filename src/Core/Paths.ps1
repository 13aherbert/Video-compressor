# Core/Paths.ps1
# Locating ffmpeg, temp folders, output names, settings and logging.
# Must run on Windows PowerShell 5.1 (built into Windows 10/11) and on PowerShell 7.

$script:ToolRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:LogFile = $null
$script:VideoExtensions = @('.mp4', '.mov', '.m4v', '.mkv', '.avi', '.wmv', '.webm', '.mts', '.m2ts',
                            '.ts', '.3gp', '.flv', '.mpg', '.mpeg', '.mxf', '.vob')

function Get-ToolRoot { return $script:ToolRoot }

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }

function Get-NullDevice {
    if (Test-IsWindows) { return 'NUL' }
    return '/dev/null'
}

function Get-ToolExe {
    param([Parameter(Mandatory = $true)][string]$Name)
    $exe = $Name
    if (Test-IsWindows) { $exe = "$Name.exe" }
    $bundled = Join-Path (Join-Path (Get-ToolRoot) 'bin') $exe
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw ("Could not find $exe in the 'bin' folder. On a computer with internet access, run " +
           "tools\Get-FFmpeg.ps1 once to download it, then copy the whole folder to your flash drive.")
}

function Get-FFmpegPath  { return (Get-ToolExe -Name 'ffmpeg') }
function Get-FFprobePath { return (Get-ToolExe -Name 'ffprobe') }

function New-JobTempDir {
    # Scratch space on the local disk (not the flash drive) for two-pass stats files.
    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'VideoCompressor'
    $dir = Join-Path $base ([System.Guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Remove-JobTempDir {
    param([string]$Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-OutputPath {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)]$Settings
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
    $suffix = [string]$Settings.outputSuffix
    $dir = Split-Path -Parent $InputPath
    if ($Settings.outputMode -eq 'folder' -and -not [string]::IsNullOrWhiteSpace([string]$Settings.outputFolder)) {
        $dir = [string]$Settings.outputFolder
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    }
    $candidate = Join-Path $dir ($base + $suffix + '.mp4')
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $dir ($base + $suffix + " ($n).mp4")
        $n++
    }
    return $candidate
}

# ---------------------------------------------------------------- settings

function Get-DefaultSettings {
    return [ordered]@{
        targetMB                = 40
        sizeUnitBytes           = 1000000
        safetyMarginPercent     = 3
        codec                   = 'hevc'
        speed                   = 'balanced'
        audioKbps               = 96
        maxHeight               = 0
        outputMode              = 'nextToSource'
        outputFolder            = ''
        outputSuffix            = '.compressed'
        skipIfAlreadyUnderLimit = $true
        maxRetries              = 2
    }
}

function Get-SettingsPath { return (Join-Path (Get-ToolRoot) 'settings.json') }

function Get-Settings {
    $defaults = Get-DefaultSettings
    $obj = New-Object PSObject
    foreach ($k in $defaults.Keys) { $obj | Add-Member -MemberType NoteProperty -Name $k -Value $defaults[$k] }
    $file = Get-SettingsPath
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) {
                if ($defaults.Contains($prop.Name)) { $obj.($prop.Name) = $prop.Value }
            }
        } catch {
            Write-Log "settings.json could not be read, using defaults: $($_.Exception.Message)"
        }
    }
    return $obj
}

function Save-Settings {
    param([Parameter(Mandatory = $true)]$Settings)
    try {
        $Settings | ConvertTo-Json | Set-Content -LiteralPath (Get-SettingsPath) -Encoding UTF8
    } catch {
        Write-Log "Could not save settings.json: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- logging

function Initialize-Log {
    $logDir = Join-Path (Get-ToolRoot) 'logs'
    try {
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $script:LogFile = Join-Path $logDir ((Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Add-Content -LiteralPath $script:LogFile -Value "Video compressor log started $(Get-Date)" -Encoding UTF8
    } catch {
        # Read-only media: fall back to the temp folder.
        $script:LogFile = Join-Path ([System.IO.Path]::GetTempPath()) 'VideoCompressor.log'
    }
    return $script:LogFile
}

function Get-LogPath {
    if (-not $script:LogFile) { Initialize-Log | Out-Null }
    return $script:LogFile
}

function Write-Log {
    param([string]$Message)
    if (-not $script:LogFile) { Initialize-Log | Out-Null }
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
}

# ---------------------------------------------------------------- inputs

function Resolve-VideoInputs {
    # Accepts files and folders (as dropped onto the launcher); returns video file paths.
    param([string[]]$Paths)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $p = $p.Trim('"')
        if (-not (Test-Path -LiteralPath $p)) { Write-Log "Skipping missing path: $p"; continue }
        $item = Get-Item -LiteralPath $p
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $p -File |
                Where-Object { $script:VideoExtensions -contains $_.Extension.ToLowerInvariant() } |
                Sort-Object Name |
                ForEach-Object { $result.Add($_.FullName) }
        } elseif ($script:VideoExtensions -contains $item.Extension.ToLowerInvariant()) {
            if (-not $result.Contains($item.FullName)) { $result.Add($item.FullName) }
        } else {
            Write-Log "Skipping non-video file: $p"
        }
    }
    return , $result.ToArray()
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1000000000) { return ('{0:N2} GB' -f ($Bytes / 1000000000)) }
    if ($Bytes -ge 1000000)    { return ('{0:N1} MB' -f ($Bytes / 1000000)) }
    if ($Bytes -ge 1000)       { return ('{0:N0} KB' -f ($Bytes / 1000)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Duration {
    param([double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([math]::Round($Seconds))
    if ($ts.TotalHours -ge 1) { return ('{0}:{1:00}:{2:00}' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds) }
    return ('{0}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}
