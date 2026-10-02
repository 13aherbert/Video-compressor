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

# ---------------------------------------------------------------- output folder / name templates
# The output folder and the file name are templates with {variables}, like HandBrake's auto-naming.
# Resolve-OutputLocation is pure (no disk access) so the window can preview it as you type;
# Get-OutputPath adds the disk work: create the folder and never overwrite an existing file.

$script:TemplateVariables = @(
    @{ Name = 'source';       Example = 'Beach';             Help = 'original file name, without extension' }
    @{ Name = 'sourcefolder'; Example = 'Holiday';           Help = 'name of the folder the original is in' }
    @{ Name = 'date';         Example = '2026-10-02';        Help = 'date the batch started' }
    @{ Name = 'time';         Example = '17-45-09';          Help = 'time the batch started' }
    @{ Name = 'datetime';     Example = '2026-10-02_17-45-09'; Help = 'date and time the batch started' }
    @{ Name = 'codec';        Example = 'hevc';              Help = 'hevc or h264' }
    @{ Name = 'quality';      Example = '32';                Help = 'the Quality (RF) number' }
    @{ Name = 'mode';         Example = 'quality';           Help = 'quality or fill' }
    @{ Name = 'limit';        Example = '40MB';              Help = 'the size limit' }
    @{ Name = 'width';        Example = '1280';              Help = 'width of the compressed video' }
    @{ Name = 'height';       Example = '720';               Help = 'height of the compressed video' }
)

function Get-TemplateVariables { return $script:TemplateVariables }

function Remove-InvalidNameChars {
    # Characters Windows does not allow in a file or folder name (and control characters).
    param([string]$Text, [string]$Replacement = '')
    return [regex]::Replace($Text, '[\\/:*?"<>|\x00-\x1f]', $Replacement)
}

function ConvertTo-SafeSegment {
    # One folder or file name: forbidden characters removed, trailing dots/spaces trimmed, device names defused.
    param([string]$Text)
    $t = (Remove-InvalidNameChars $Text).Trim().TrimEnd('.', ' ')
    if ($t -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?$') { $t = '_' + $t }
    return $t
}

function Get-TemplateContext {
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)]$Settings,
        $Plan = $null,
        [datetime]$BatchTime = (Get-Date)
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $dir = [System.IO.Path]::GetDirectoryName($InputPath)
    $folderName = ''
    if ($dir) {
        $folderName = Split-Path -Leaf $dir
        if (-not $folderName) { $folderName = ($dir -replace '[\\/:]', '') }   # a drive root such as C:\
    }
    $codec = 'hevc'
    if ("$($Settings.codec)" -match '264|avc') { $codec = 'h264' }
    $mode = 'quality'
    if ("$($Settings.mode)".ToLowerInvariant() -eq 'fill') { $mode = 'fill' }
    $width = ''; $height = ''
    if ($null -ne $Plan -and $null -ne $Plan.PSObject.Properties['OutWidth']) {
        $width = "$($Plan.OutWidth)"; $height = "$($Plan.OutHeight)"
    }
    return @{
        source       = [System.IO.Path]::GetFileNameWithoutExtension($InputPath)
        sourcefolder = $folderName
        date         = $BatchTime.ToString('yyyy-MM-dd', $inv)
        time         = $BatchTime.ToString('HH-mm-ss', $inv)
        datetime     = $BatchTime.ToString('yyyy-MM-dd_HH-mm-ss', $inv)
        codec        = $codec
        quality      = "$([int][math]::Round([double]$Settings.quality))"
        mode         = $mode
        limit        = ("{0}MB" -f ([double]$Settings.targetMB).ToString('0.##', $inv))
        width        = $width
        height       = $height
    }
}

function Expand-TemplateText {
    # Replaces {variables} with their (sanitised) values. Unknown variables are collected, not dropped.
    param([string]$Template, [hashtable]$Context)
    $unknown = New-Object System.Collections.Generic.List[string]
    $sb = New-Object System.Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($Template, '\{([^{}\\/]*)\}')) {
        [void]$sb.Append($Template.Substring($last, $m.Index - $last))
        $name = $m.Groups[1].Value.Trim().ToLowerInvariant()
        if ($Context.ContainsKey($name)) {
            [void]$sb.Append((Remove-InvalidNameChars ([string]$Context[$name])))
        } else {
            if (-not $unknown.Contains($m.Value)) { $unknown.Add($m.Value) }
            [void]$sb.Append($m.Value)
        }
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Template.Substring($last))
    return [PSCustomObject]@{ Text = $sb.ToString(); Unknown = $unknown.ToArray() }
}

function Resolve-OutputLocation {
    # Works out where the compressed file goes. No disk access.
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)]$Settings,
        $Plan = $null,
        [datetime]$BatchTime = (Get-Date)
    )
    $context = Get-TemplateContext -InputPath $InputPath -Settings $Settings -Plan $Plan -BatchTime $BatchTime
    $folderTemplate = [string]$Settings.outputFolder
    $nameTemplate = [string]$Settings.fileName
    if ([string]::IsNullOrWhiteSpace($nameTemplate)) { $nameTemplate = '{source}' }

    $folderPart = Expand-TemplateText -Template $folderTemplate.Trim() -Context $context
    $namePart   = Expand-TemplateText -Template $nameTemplate.Trim() -Context $context
    $unknown = @(@($folderPart.Unknown) + @($namePart.Unknown) | Where-Object { $_ } | Select-Object -Unique)

    # Folder: an absolute template is used as is; a relative one hangs off the original's own folder.
    # Characters that are illegal anywhere in a path go first: on Windows PowerShell 5.1 even asking
    # whether such a path is rooted throws.
    $text = [regex]::Replace($folderPart.Text, '[<>"|*?\x00-\x1f]', '')
    $root = ''
    if ($text -ne '' -and [System.IO.Path]::IsPathRooted($text)) {
        $root = [System.IO.Path]::GetPathRoot($text)
        $text = $text.Substring($root.Length)
    }
    $segments = New-Object System.Collections.Generic.List[string]
    foreach ($raw in ($text -split '[\\/]')) {
        if ($raw -eq '..') { $segments.Add('..'); continue }
        $seg = ConvertTo-SafeSegment $raw
        if ($seg -ne '' -and $seg -ne '.') { $segments.Add($seg) }
    }
    if ($root -ne '') { $baseDir = $root } else { $baseDir = [System.IO.Path]::GetDirectoryName($InputPath) }
    if (-not $baseDir) { $baseDir = (Get-Location).Path }
    $folder = $baseDir
    if ($segments.Count -gt 0) { $folder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($baseDir, ($segments.ToArray() -join [System.IO.Path]::DirectorySeparatorChar))) }

    # File name: one segment, any separators typed here become underscores.
    $name = ConvertTo-SafeSegment ($namePart.Text -replace '[\\/]', '_')
    if ($name -eq '') { $name = ConvertTo-SafeSegment $context['source'] }
    if ($name -eq '') { $name = 'video' }
    # Keep the whole path under the classic Windows limit (PowerShell 5.1 is not long-path aware).
    $maxName = 245 - $folder.Length - 6
    if ($maxName -lt 20) { $maxName = 20 }
    if ($name.Length -gt $maxName) { $name = $name.Substring(0, $maxName).TrimEnd('.', ' ') }

    return [PSCustomObject]@{
        Folder   = $folder
        BaseName = $name
        FileName = $name + '.mp4'
        Path     = [System.IO.Path]::Combine($folder, $name + '.mp4')
        Unknown  = $unknown
    }
}

function Get-UnknownVariableMessage {
    param($Location)
    $valid = ((Get-TemplateVariables | ForEach-Object { '{' + $_.Name + '}' }) -join ' ')
    return ("Unknown variable in the output folder or file name: $(@($Location.Unknown) -join ', '). Valid variables: $valid")
}

function Assert-KnownTemplateVariables {
    param($Location)
    if (@($Location.Unknown | Where-Object { $_ }).Count -gt 0) { throw (Get-UnknownVariableMessage $Location) }
}

function Get-OutputPath {
    # Resolves the templates, creates the folder, and returns a path that does not exist yet:
    # an existing file (including the original) is never overwritten, " (2)", " (3)" ... is added instead.
    param(
        [Parameter(Mandatory = $true)][string]$InputPath,
        [Parameter(Mandatory = $true)]$Settings,
        $Plan = $null,
        [datetime]$BatchTime = (Get-Date)
    )
    $loc = Resolve-OutputLocation -InputPath $InputPath -Settings $Settings -Plan $Plan -BatchTime $BatchTime
    Assert-KnownTemplateVariables $loc
    if (-not (Test-Path -LiteralPath $loc.Folder)) {
        try {
            # No -Force: it would let a path component that is an existing FILE be replaced by a folder.
            New-Item -ItemType Directory -Path $loc.Folder -ErrorAction Stop | Out-Null
        } catch {
            throw ("Could not create the output folder '$($loc.Folder)' ($($_.Exception.Message)). " +
                   'If the original is on read-only media, choose a full folder path such as C:\Videos\Encoded in Output folder.')
        }
    }
    $candidate = $loc.Path
    $n = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = [System.IO.Path]::Combine($loc.Folder, $loc.BaseName + " ($n).mp4")
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
        quality                 = 32
        mode                    = 'quality'
        audioKbps               = 96
        maxHeight               = 0
        outputFolder            = 'Encoded'
        fileName                = '{source}'
        skipIfAlreadyUnderLimit = $true
        maxRetries              = 2
    }
}

$script:SettingsPathOverride = $null   # set by tests so they never touch the real settings.json
function Get-SettingsPath {
    if ($script:SettingsPathOverride) { return $script:SettingsPathOverride }
    return (Join-Path (Get-ToolRoot) 'settings.json')
}

function Get-Settings {
    param([string]$Path = '')    # tests pass a temporary file; normally settings.json next to the scripts
    $defaults = Get-DefaultSettings
    $obj = New-Object PSObject
    foreach ($k in $defaults.Keys) { $obj | Add-Member -MemberType NoteProperty -Name $k -Value $defaults[$k] }
    $file = $Path
    if (-not $file) { $file = Get-SettingsPath }
    if (Test-Path -LiteralPath $file) {
        try {
            $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            # Files from versions before output templates have outputMode/outputSuffix. Carry the
            # user's explicit folder over; the old default "next to the original" becomes the new Encoded default.
            $legacy = ($null -ne $json.PSObject.Properties['outputMode']) -and ($null -eq $json.PSObject.Properties['fileName'])
            foreach ($prop in $json.PSObject.Properties) {
                if ($legacy -and $prop.Name -eq 'outputFolder') { continue }
                if ($defaults.Contains($prop.Name)) { $obj.($prop.Name) = $prop.Value }
            }
            if ($legacy) {
                if ("$($json.outputMode)" -eq 'folder' -and -not [string]::IsNullOrWhiteSpace([string]$json.outputFolder)) {
                    $obj.outputFolder = [string]$json.outputFolder
                }
                $oldSuffix = ''
                if ($null -ne $json.PSObject.Properties['outputSuffix']) { $oldSuffix = [string]$json.outputSuffix }
                if ($oldSuffix.Trim() -ne '' -and $oldSuffix -ne '.compressed') { $obj.fileName = '{source}' + $oldSuffix }
            }
        } catch {
            Write-Log "settings.json could not be read, using defaults: $($_.Exception.Message)"
        }
    }
    # Sanity limits: nothing below 720p is ever produced; quality stays in a usable range.
    if ([int]$obj.maxHeight -gt 0 -and [int]$obj.maxHeight -lt 720) { $obj.maxHeight = 720 }
    $q = [double]$obj.quality
    if ($q -lt 18) { $q = 18 } elseif ($q -gt 45) { $q = 45 }
    $obj.quality = $q
    if ("$($obj.mode)".ToLowerInvariant() -ne 'fill') { $obj.mode = 'quality' } else { $obj.mode = 'fill' }
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
