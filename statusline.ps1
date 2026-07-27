#Requires -Version 5.1
<#
  coralline - native Windows PowerShell statusline for Claude Code.

  This runtime implements the main bar and optional float producer without Bash,
  jq, WSL, or PowerShell 7. Config is read from the same coralline.conf through a
  narrow, non-executing Bash-word parser. Burn and synced limit state share the
  same immutable store as Bash; subagent rows remain a later protocol slice.
#>

# Claude Code registers this exact literal. It must leave before stdin, config,
# executable discovery, or any other main-bar work.
if ($args.Count -gt 0 -and [string]$args[0] -ceq '--subagent') {
    [Environment]::Exit(0)
}

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$InputStream = [Console]::OpenStandardInput()
$InputReader = New-Object System.IO.StreamReader($InputStream, $StrictUtf8, $false, 4096, $false)
try { $rawInput = $InputReader.ReadToEnd() } catch { $rawInput = '' }
$InputReader.Dispose()

$OutputStream = [Console]::OpenStandardOutput()
$OutputWriter = New-Object System.IO.StreamWriter($OutputStream, $Utf8NoBom, 4096, $false)
$OutputWriter.NewLine = "`n"
$OutputWriter.AutoFlush = $true
$OutputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom

function Glyph([int]$Codepoint) {
    return [System.Char]::ConvertFromUtf32($Codepoint)
}

function Remove-ControlChars([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [regex]::Replace($Value, '[\u0000-\u001f\u007f-\u009f]', '')
}

function Copy-Config([System.Collections.IDictionary]$Source) {
    $copy = [ordered]@{}
    foreach ($key in $Source.Keys) { $copy[$key] = [string]$Source[$key] }
    return ,$copy
}

$HomeDir = [string]$HOME
if ([string]::IsNullOrEmpty($HomeDir)) { $HomeDir = [Environment]::GetFolderPath('UserProfile') }
$ScriptDir = [System.IO.Path]::GetDirectoryName($MyInvocation.MyCommand.Path)
$ScriptPath = [string]$MyInvocation.MyCommand.Path
$DefaultFloatFile = [System.IO.Path]::Combine($HomeDir, '.claude\coralline\float.txt')
$DefaultBurnFile = [string]$env:CORALLINE_BURN_FILE
if ([string]::IsNullOrEmpty($DefaultBurnFile)) {
    $DefaultBurnFile = [System.IO.Path]::Combine($HomeDir, '.claude\coralline\burn-5h.tsv')
}
$DefaultRl5File = [string]$env:CORALLINE_RL5H_FILE
if ([string]::IsNullOrEmpty($DefaultRl5File)) {
    $DefaultRl5File = [System.IO.Path]::Combine($HomeDir, '.claude\coralline\limit-5h.tsv')
}
$DefaultRl7File = [string]$env:CORALLINE_RL7D_FILE
if ([string]::IsNullOrEmpty($DefaultRl7File)) {
    $DefaultRl7File = [System.IO.Path]::Combine($HomeDir, '.claude\coralline\limit-7d.tsv')
}

$Defaults = [ordered]@{
    VL_STYLE = 'pill'
    VL_LEAN_SEP = ''
    VL_LEAN_BG = ''
    VL_LEAN_FG = ''
    VL_LEAN_CAP_R = ''
    VL_LEAN_CAP_L = ''
    VL_LAYOUT = 'fixed'
    VL_MAX_LINES = '3'
    VL_WRAP_MARGIN = '4'
    VL_SEGMENTS = 'dir git model ctx limit5h limit7d cost clock'
    VL_SEGMENTS2 = ''
    VL_SEGMENTS3 = ''
    VL_BAR_WIDTH = '5'
    VL_BAR_FILL = (Glyph 0x25B0)
    VL_BAR_EMPTY = (Glyph 0x25B1)
    VL_CTX_GLYPH = (Glyph 0x2B21)
    VL_PROJECT_GLYPH = (Glyph 0x2B22)
    VL_CLOCK = '12h'
    VL_CLOCK_SECONDS = '1'
    VL_PATH_DEPTH = '4'
    VL_NAME_MAX = '0'
    VL_COST_DECIMALS = '2'
    VL_WARN_PCT = '50'
    VL_HOT_PCT = '75'
    VL_ASCII = '0'
    VL_FLOAT = '0'
    VL_FLOAT_SEGMENTS = 'model ctx cost'
    VL_FLOAT_SEP = ('  ' + (Glyph 0x00B7) + '  ')
    VL_FLOAT_FILE = $DefaultFloatFile
    VL_NOCOLOR = '0'

    VL_SUB_SEGMENTS = 'name model ctx elapsed'
    VL_BG_SUB_NAME = ''
    VL_BG_SUB_MODEL = ''
    VL_BG_SUB_CTX = ''
    VL_BG_SUB_ELAPSED = ''

    CORALLINE_BURN_WINDOW = '600'
    VL_BURN_GLYPH = (Glyph 0x2197)
    VL_BG_BURN = ''
    BURN_FILE = $DefaultBurnFile
    BURN_TRIM = '1500'
    VL_LIMIT_SYNC = '0'
    RL5H_FILE = $DefaultRl5File
    RL7D_FILE = $DefaultRl7File
    RL_MAX_5H = '21600'
    RL_MAX_7D = '691200'

    VL_CAP_L = (Glyph 0xE0B6)
    VL_CAP_R = (Glyph 0xE0B4)
    VL_SEP = (Glyph 0xE0B0)

    VL_BG_DIR = '81,166,199'
    VL_BG_PROJECT = ''
    VL_BG_GIT_OK = '65'
    VL_BG_STASH = ''
    VL_BG_GIT_DIRTY = '130'
    VL_BG_MODEL = '173'
    VL_BG_CTX = '238'
    VL_BG_5H = '237'
    VL_BG_7D = '236'
    VL_BG_COST = '212,125,145'
    VL_BG_CLOCK = '70,80,110'
    VL_BG_LINES = '240'
    VL_BG_STYLE = '96'
    VL_BG_DURATION = '60'
    VL_BG_EFFORT = '141'
    VL_BG_NODE = ''
    VL_BG_PYTHON = ''
    VL_BG_BAR = ''
    VL_NODE_GLYPH = (Glyph 0xE718)
    VL_PY_GLYPH = (Glyph 0xE73C)
    VL_RUNTIME_PROBE = '0'

    VL_FG_TEXT = '231'
    VL_FG_DIM = '245'
    VL_FG_OK = '114'
    VL_FG_WARN = '179'
    VL_FG_HOT = '167'
}

$PathConfigKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($key in @('VL_FLOAT_FILE', 'BURN_FILE', 'RL5H_FILE', 'RL7D_FILE')) { [void]$PathConfigKeys.Add($key) }

function Add-Utf8Text([System.Collections.Generic.List[byte]]$Bytes, [string]$Text) {
    try {
        $encoded = $StrictUtf8.GetBytes($Text)
        $Bytes.AddRange($encoded)
        return $true
    } catch { return $false }
}

function Read-WordChar([string]$Text, [ref]$Index) {
    $i = [int]$Index.Value
    if ($i -ge $Text.Length) { return $null }
    $count = 1
    if ([char]::IsHighSurrogate($Text[$i])) {
        if (($i + 1) -ge $Text.Length -or -not [char]::IsLowSurrogate($Text[$i + 1])) { return $null }
        $count = 2
    } elseif ([char]::IsLowSurrogate($Text[$i])) { return $null }
    $piece = $Text.Substring($i, $count)
    $Index.Value = $i + $count
    return $piece
}

function Decode-ShellWord([string]$Text, [bool]$PathContext) {
    if ($null -eq $Text) { return [pscustomobject]@{ Success = $false; Value = '' } }
    $bytes = New-Object 'System.Collections.Generic.List[byte]'
    $i = 0
    $started = $false

    if ($Text.Length -eq 0) { return [pscustomobject]@{ Success = $true; Value = '' } }
    if ($Text[0] -eq ' ' -or $Text[0] -eq "`t") {
        $rest = $Text.TrimStart(' ', "`t")
        if ($rest.Length -eq 0 -or $rest[0] -eq '#') {
            return [pscustomobject]@{ Success = $true; Value = '' }
        }
        return [pscustomobject]@{ Success = $false; Value = '' }
    }

    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq ' ' -or $ch -eq "`t") { break }
        $started = $true

        if ($ch -eq "'") {
            $i++
            $closed = $false
            while ($i -lt $Text.Length) {
                if ($Text[$i] -eq "'") { $i++; $closed = $true; break }
                $ri = [ref]$i
                $piece = Read-WordChar $Text $ri
                if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $i = $ri.Value
                if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '"') {
            $i++
            $closed = $false
            while ($i -lt $Text.Length) {
                $ch = $Text[$i]
                if ($ch -eq '"') { $i++; $closed = $true; break }
                if ($ch -eq '\') {
                    $i++
                    if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $next = $Text[$i]
                    if ($next -ne '"' -and $next -ne '\' -and $next -ne '$' -and $next -ne '`') {
                        return [pscustomobject]@{ Success = $false; Value = '' }
                    }
                    if (-not (Add-Utf8Text $bytes ([string]$next))) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $i++
                    continue
                }
                if ($ch -eq '$') {
                    if (-not $PathContext) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    if ($Text.Substring($i).StartsWith('${HOME}', [System.StringComparison]::Ordinal)) { $i += 7 }
                    elseif ($Text.Substring($i).StartsWith('$HOME', [System.StringComparison]::Ordinal)) { $i += 5 }
                    else { return [pscustomobject]@{ Success = $false; Value = '' } }
                    if (-not (Add-Utf8Text $bytes $HomeDir)) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    continue
                }
                if ($ch -eq '`') { return [pscustomobject]@{ Success = $false; Value = '' } }
                $ri = [ref]$i
                $piece = Read-WordChar $Text $ri
                if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $i = $ri.Value
                if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '$' -and ($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq "'") {
            $i += 2
            $closed = $false
            while ($i -lt $Text.Length) {
                $ch = $Text[$i]
                if ($ch -eq "'") { $i++; $closed = $true; break }
                if ($ch -ne '\') {
                    $ri = [ref]$i
                    $piece = Read-WordChar $Text $ri
                    if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    $i = $ri.Value
                    if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
                    continue
                }

                $i++
                if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                $esc = $Text[$i]
                $i++
                $byteValue = -1
                switch ($esc) {
                    'a' { $byteValue = 7 }
                    'b' { $byteValue = 8 }
                    'e' { $byteValue = 27 }
                    'E' { $byteValue = 27 }
                    'f' { $byteValue = 12 }
                    'n' { $byteValue = 10 }
                    'r' { $byteValue = 13 }
                    't' { $byteValue = 9 }
                    'v' { $byteValue = 11 }
                    '\' { $byteValue = 92 }
                    "'" { $byteValue = 39 }
                    '"' { $byteValue = 34 }
                    default {
                        if ($esc -ge '0' -and $esc -le '7') {
                            $digits = [string]$esc
                            while ($digits.Length -lt 3 -and $i -lt $Text.Length -and $Text[$i] -ge '0' -and $Text[$i] -le '7') {
                                $digits += $Text[$i]
                                $i++
                            }
                            try { $byteValue = [Convert]::ToInt32($digits, 8) } catch { $byteValue = -1 }
                            if ($byteValue -gt 255) { $byteValue = -1 }
                        } elseif ($esc -eq 'x') {
                            $digits = ''
                            while ($digits.Length -lt 2 -and $i -lt $Text.Length -and $Text[$i] -match '[0-9A-Fa-f]') {
                                $digits += $Text[$i]
                                $i++
                            }
                            if ($digits.Length -eq 0) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            try { $byteValue = [Convert]::ToInt32($digits, 16) } catch { $byteValue = -1 }
                        } elseif ($esc -eq 'u' -or $esc -eq 'U') {
                            $need = 4
                            if ($esc -eq 'U') { $need = 8 }
                            if (($i + $need) -gt $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            $digits = $Text.Substring($i, $need)
                            if ($digits -notmatch ('^[0-9A-Fa-f]{' + $need + '}$')) { return [pscustomobject]@{ Success = $false; Value = '' } }
                            $i += $need
                            try { $cp = [Convert]::ToInt32($digits, 16) } catch { return [pscustomobject]@{ Success = $false; Value = '' } }
                            if ($cp -gt 0x10FFFF -or ($cp -ge 0xD800 -and $cp -le 0xDFFF)) {
                                return [pscustomobject]@{ Success = $false; Value = '' }
                            }
                            if (-not (Add-Utf8Text $bytes ([char]::ConvertFromUtf32($cp)))) {
                                return [pscustomobject]@{ Success = $false; Value = '' }
                            }
                            continue
                        } else { return [pscustomobject]@{ Success = $false; Value = '' } }
                    }
                }
                if ($byteValue -lt 0 -or $byteValue -gt 255) { return [pscustomobject]@{ Success = $false; Value = '' } }
                [void]$bytes.Add([byte]$byteValue)
            }
            if (-not $closed) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '\') {
            $i++
            if ($i -ge $Text.Length) { return [pscustomobject]@{ Success = $false; Value = '' } }
            $ri = [ref]$i
            $piece = Read-WordChar $Text $ri
            if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
            $i = $ri.Value
            if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '$') {
            if (-not $PathContext) { return [pscustomobject]@{ Success = $false; Value = '' } }
            if ($Text.Substring($i).StartsWith('${HOME}', [System.StringComparison]::Ordinal)) { $i += 7 }
            elseif ($Text.Substring($i).StartsWith('$HOME', [System.StringComparison]::Ordinal)) { $i += 5 }
            else { return [pscustomobject]@{ Success = $false; Value = '' } }
            if (-not (Add-Utf8Text $bytes $HomeDir)) { return [pscustomobject]@{ Success = $false; Value = '' } }
            continue
        }

        if ($ch -eq '`' -or $ch -eq ';' -or $ch -eq '|' -or $ch -eq '&' -or $ch -eq '<' -or $ch -eq '>' -or $ch -eq '(' -or $ch -eq ')') {
            return [pscustomobject]@{ Success = $false; Value = '' }
        }

        $ri = [ref]$i
        $piece = Read-WordChar $Text $ri
        if ($null -eq $piece) { return [pscustomobject]@{ Success = $false; Value = '' } }
        $i = $ri.Value
        if (-not (Add-Utf8Text $bytes $piece)) { return [pscustomobject]@{ Success = $false; Value = '' } }
    }

    if (-not $started) { return [pscustomobject]@{ Success = $false; Value = '' } }
    while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t")) { $i++ }
    if ($i -lt $Text.Length -and $Text[$i] -ne '#') { return [pscustomobject]@{ Success = $false; Value = '' } }

    try { $value = $StrictUtf8.GetString($bytes.ToArray()) } catch { return [pscustomobject]@{ Success = $false; Value = '' } }
    if ($PathContext -and $value.StartsWith('~', [System.StringComparison]::Ordinal)) {
        if ($value -eq '~') { $value = $HomeDir }
        elseif ($value.StartsWith('~/', [System.StringComparison]::Ordinal) -or $value.StartsWith('~\', [System.StringComparison]::Ordinal)) {
            $value = $HomeDir.TrimEnd('\', '/') + $value.Substring(1)
        } else { return [pscustomobject]@{ Success = $false; Value = '' } }
    }
    return [pscustomobject]@{ Success = $true; Value = $value }
}

function Test-DosDeviceComponent([string]$Component) {
    if ([string]::IsNullOrEmpty($Component)) { return $false }
    $name = $Component.TrimEnd('.', ' ')
    $dot = $name.IndexOf('.')
    if ($dot -ge 0) { $name = $name.Substring(0, $dot) }
    return $name -match '^(?i:CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])$'
}

function Test-LocalPathSyntax([string]$Path, [ref]$Normalized) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 4096) { return $false }
    if ($Path -match '[\u0000-\u001f\u007f-\u009f]') { return $false }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//', [System.StringComparison]::Ordinal)) { return $false }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//?/', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//./', [System.StringComparison]::Ordinal)) { return $false }

    $p = $Path
    if ($p -match '^/([A-Za-z])(?:/|$)') {
        $drive = $Matches[1].ToUpperInvariant()
        $p = $drive + ':\' + $p.Substring(2).TrimStart('/')
    }
    $p = $p.Replace('/', '\')
    if ($p.StartsWith('\', [System.StringComparison]::Ordinal)) { return $false }

    $colon = $p.IndexOf(':')
    if ($colon -ge 0 -and ($colon -ne 1 -or $p.Length -lt 3 -or -not [char]::IsLetter($p[0]) -or $p[2] -ne '\' -or $p.IndexOf(':', 2) -ge 0)) { return $false }
    try { $root = [System.IO.Path]::GetPathRoot($p) } catch { return $false }
    $rest = $p
    if (-not [string]::IsNullOrEmpty($root)) { $rest = $p.Substring($root.Length) }
    foreach ($component in $rest.Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($component -eq '.' -or $component -eq '..') { continue }
        if ($component.EndsWith('.') -or $component.EndsWith(' ')) { return $false }
        if ($component -match '[<>"\|\?\*:]') { return $false }
        if (Test-DosDeviceComponent $component) { return $false }
    }
    $Normalized.Value = $p
    return $true
}

function ConvertTo-LocalFullPath([string]$Path, [string]$BaseDir) {
    if ([string]::IsNullOrEmpty($Path) -or $Path.Length -gt 4096) { return $null }
    $p = ''
    $normalized = $null
    if (-not (Test-LocalPathSyntax $Path ([ref]$normalized))) { return $null }
    $p = $normalized
    try {
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = [System.IO.Path]::Combine($BaseDir, $p) }
        $full = [System.IO.Path]::GetFullPath($p)
    } catch { return $null }
    if ([string]::IsNullOrEmpty($full) -or $full.Length -gt 4096 -or $full.StartsWith('\\', [System.StringComparison]::Ordinal)) { return $null }
    return $full
}

function Test-PathInside([string]$Path, [string]$Root) {
    if ([string]::IsNullOrEmpty($Path) -or [string]::IsNullOrEmpty($Root)) { return $false }
    $trimmed = $Root.TrimEnd('\')
    if ($trimmed.Length -eq 2 -and $trimmed[1] -eq ':') { $trimmed += '\' }
    if ($Path.Equals($trimmed, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $trimmed
    if (-not $prefix.EndsWith('\', [System.StringComparison]::Ordinal)) { $prefix += '\' }
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-NoReparseComponents([string]$Path) {
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { return $false }
    if ([string]::IsNullOrEmpty($root)) { return $false }
    $parts = $Path.Substring($root.Length).Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)
    $current = $root
    for ($i=0; $i -lt $parts.Length; $i++) {
        $current = [System.IO.Path]::Combine($current, $parts[$i])
        try { $attrs = [System.IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] { return $true }
        catch [System.IO.DirectoryNotFoundException] { return $true }
        catch { return $false }
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($i -lt ($parts.Length - 1) -and ($attrs -band [System.IO.FileAttributes]::Directory) -eq 0) { return $false }
    }
    return $true
}

function Test-SafeRegularFile([string]$Path) {
    if (-not (Test-NoReparseComponents $Path)) { return $false }
    try { $attrs = [System.IO.File]::GetAttributes($Path) } catch { return $false }
    if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return $false }
    return $true
}

function Read-StrictUtf8File([string]$Path) {
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return $null }
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -gt 1048576) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $text = $StrictUtf8.GetString($bytes)
        if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
        return $text
    } catch { return $null }
}

function Import-ConfigFile(
    [string]$Path,
    [System.Collections.IDictionary]$BaseConfig,
    [hashtable]$State,
    [int]$Depth,
    [string[]]$ApprovedRoots
) {
    $failed = [pscustomobject]@{ Success = $false; Config = $BaseConfig }
    if ($Depth -gt 8) { return $failed }
    if ($State.Visited.Contains($Path)) { return $failed }
    [void]$State.Visited.Add($Path)
    if (-not (Test-SafeRegularFile $Path)) { return $failed }
    $text = Read-StrictUtf8File $Path
    if ($null -eq $text) { return $failed }

    $candidate = Copy-Config $BaseConfig
    $rootFloatAuthorized = $false
    $stack = New-Object System.Collections.ArrayList
    $active = $true
    $valid = $true
    $lines = [regex]::Split($text, "`r`n|`n|`r")

    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t.StartsWith('#', [System.StringComparison]::Ordinal)) { continue }
        $statement = $line.TrimStart(' ', "`t")

        if ($t -match '^if[ \t]+\[[ \t]+"\$\{REMORA_ACTIVE:-0\}"[ \t]+(=|!=)[ \t]+"([^"\r\n]*)"[ \t]+\];[ \t]+then$') {
            $op = $Matches[1]
            $literal = $Matches[2]
            $envValue = [string]$env:REMORA_ACTIVE
            if ([string]::IsNullOrEmpty($envValue)) { $envValue = '0' }
            $condition = $envValue -ceq $literal
            if ($op -eq '!=') { $condition = -not $condition }
            $frame = [pscustomobject]@{ ParentActive = $active; Condition = $condition; ElseSeen = $false }
            [void]$stack.Add($frame)
            $active = $active -and $condition
            continue
        }
        if ($t -match '^if(?:[ \t]|$)') { $valid = $false; break }
        if ($t -eq 'else') {
            if ($stack.Count -eq 0) { $valid = $false; break }
            $frame = $stack[$stack.Count - 1]
            if ($frame.ElseSeen) { $valid = $false; break }
            $frame.ElseSeen = $true
            $active = $frame.ParentActive -and (-not $frame.Condition)
            continue
        }
        if ($t -eq 'fi') {
            if ($stack.Count -eq 0) { $valid = $false; break }
            $frame = $stack[$stack.Count - 1]
            $active = $frame.ParentActive
            $stack.RemoveAt($stack.Count - 1)
            continue
        }
        if (-not $active) { continue }

        if ($statement -eq '.' -or $statement -match '^\.[ \t]+') {
            if ([int]$State.IncludeCount -ge 16) { continue }
            $State.IncludeCount = [int]$State.IncludeCount + 1
            $wordText = ''
            if ($statement.Length -gt 1) { $wordText = $statement.Substring(1).TrimStart(' ', "`t") }
            $decoded = Decode-ShellWord $wordText $true
            if (-not $decoded.Success) { continue }
            $includePath = ConvertTo-LocalFullPath $decoded.Value ([System.IO.Path]::GetDirectoryName($Path))
            if ([string]::IsNullOrEmpty($includePath)) { continue }
            if (-not [System.IO.Path]::GetExtension($includePath).Equals('.conf', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $inside = $false
            foreach ($root in $ApprovedRoots) {
                if (Test-PathInside $includePath $root) { $inside = $true; break }
            }
            if (-not $inside) { continue }
            $child = Import-ConfigFile $includePath $candidate $State ($Depth + 1) $ApprovedRoots
            if ($child.Success) { $candidate = $child.Config }
            continue
        }

        if ($statement -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $name = $Matches[1]
            $raw = $Matches[2]
            $pathContext = $PathConfigKeys.Contains($name) -or $name -ieq 'VL_FLOAT_FILE'
            $decoded = Decode-ShellWord $raw $pathContext
            if (-not $decoded.Success) { $valid = $false; break }
            if ($pathContext -and $decoded.Value -match '[ -\u007f-\u009f]') { $valid = $false; break }
            if ($name -ieq 'VL_FLOAT_FILE') {
                if ($Depth -eq 0 -and $name -ceq 'VL_FLOAT_FILE') {
                    $candidate['VL_FLOAT_FILE'] = $decoded.Value
                    $rootFloatAuthorized = $true
                }
                continue
            }
            $candidate[$name] = $decoded.Value
            continue
        }

        $valid = $false
        break
    }

    if ($stack.Count -ne 0) { $valid = $false }
    if (-not $valid) { return $failed }
    return [pscustomobject]@{ Success = $true; Config = $candidate; FloatFileAuthorized = ($Depth -eq 0 -and $rootFloatAuthorized) }
}

$Cfg = Copy-Config $Defaults
$FloatFileRootAuthorized = $false
$ConfigInput = [string]$env:CORALLINE_CONFIG
if ([string]::IsNullOrEmpty($ConfigInput)) { $ConfigInput = [System.IO.Path]::Combine($HomeDir, '.claude\coralline.conf') }
$ConfigPath = ConvertTo-LocalFullPath $ConfigInput ([Environment]::CurrentDirectory)
if (-not [string]::IsNullOrEmpty($ConfigPath)) {
    $ConfigRoot = [System.IO.Path]::GetDirectoryName($ConfigPath)
    $ThemesRoot = ConvertTo-LocalFullPath ([System.IO.Path]::Combine($ScriptDir, 'themes')) $ScriptDir
    $approved = @($ConfigRoot)
    if (-not [string]::IsNullOrEmpty($ThemesRoot)) { $approved += $ThemesRoot }
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $state = @{ IncludeCount = 0; Visited = $visited }
    $parsed = Import-ConfigFile $ConfigPath $Cfg $state 0 $approved
    if ($parsed.Success) {
        $Cfg = $parsed.Config
        $FloatFileRootAuthorized = [bool]$parsed.FloatFileAuthorized
    }
}
$ConfigVisitedPaths = @()
if ($null -ne $visited) {
    foreach ($visitedPath in $visited) { $ConfigVisitedPaths += [string]$visitedPath }
}

# Config never supplies terminal controls. The renderer is the sole ANSI source.
foreach ($key in @($Cfg.Keys)) { $Cfg[$key] = Remove-ControlChars ([string]$Cfg[$key]) }

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$IntegerStyle = [System.Globalization.NumberStyles]::Integer
$FloatStyle = [System.Globalization.NumberStyles]::Float

function Get-BoundedInt([string]$Raw, [int]$Fallback, [int]$Min, [int]$Max) {
    $value = 0
    if (-not [int]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value)) { return $Fallback }
    if ($value -lt $Min -or $value -gt $Max) { return $Fallback }
    return $value
}

function Try-BoundedDouble([string]$Raw, [double]$Min, [double]$Max, [ref]$Result) {
    $value = 0.0
    if ([string]::IsNullOrEmpty($Raw)) { return $false }
    if (-not [double]::TryParse($Raw, $FloatStyle, $Invariant, [ref]$value)) { return $false }
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt $Min -or $value -gt $Max) { return $false }
    $Result.Value = $value
    return $true
}

function Test-Color([string]$Spec) {
    if ([string]::IsNullOrEmpty($Spec)) { return $true }
    if ($Spec -match '^([0-9]{1,3})$') {
        $n = 0
        return [int]::TryParse($Matches[1], $IntegerStyle, $Invariant, [ref]$n) -and $n -ge 0 -and $n -le 255
    }
    if ($Spec -match '^([0-9]{1,3}),([0-9]{1,3}),([0-9]{1,3})$') {
        foreach ($part in @($Matches[1], $Matches[2], $Matches[3])) {
            $n = 0
            if (-not [int]::TryParse($part, $IntegerStyle, $Invariant, [ref]$n) -or $n -lt 0 -or $n -gt 255) { return $false }
        }
        return $true
    }
    return $false
}

$Cfg.VL_BAR_WIDTH = [string](Get-BoundedInt $Cfg.VL_BAR_WIDTH ([int]$Defaults.VL_BAR_WIDTH) 0 64)
$Cfg.VL_PATH_DEPTH = [string](Get-BoundedInt $Cfg.VL_PATH_DEPTH ([int]$Defaults.VL_PATH_DEPTH) 1 256)
$Cfg.VL_NAME_MAX = [string](Get-BoundedInt $Cfg.VL_NAME_MAX ([int]$Defaults.VL_NAME_MAX) 0 4096)
$Cfg.VL_COST_DECIMALS = [string](Get-BoundedInt $Cfg.VL_COST_DECIMALS ([int]$Defaults.VL_COST_DECIMALS) 0 9)
$Cfg.VL_WARN_PCT = [string](Get-BoundedInt $Cfg.VL_WARN_PCT ([int]$Defaults.VL_WARN_PCT) 0 100)
$Cfg.VL_HOT_PCT = [string](Get-BoundedInt $Cfg.VL_HOT_PCT ([int]$Defaults.VL_HOT_PCT) 0 100)
$Cfg.VL_MAX_LINES = [string](Get-BoundedInt $Cfg.VL_MAX_LINES ([int]$Defaults.VL_MAX_LINES) 1 64)
$Cfg.VL_WRAP_MARGIN = [string](Get-BoundedInt $Cfg.VL_WRAP_MARGIN ([int]$Defaults.VL_WRAP_MARGIN) 0 32767)
if ([int]$Cfg.VL_HOT_PCT -lt [int]$Cfg.VL_WARN_PCT) {
    $Cfg.VL_WARN_PCT = $Defaults.VL_WARN_PCT
    $Cfg.VL_HOT_PCT = $Defaults.VL_HOT_PCT
}
foreach ($key in @($Cfg.Keys | Where-Object { $_ -like 'VL_BG_*' -or $_ -like 'VL_FG_*' })) {
    if (-not (Test-Color $Cfg[$key])) { $Cfg[$key] = $Defaults[$key] }
}
if (-not (Test-Color $Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = '' }
if (-not (Test-Color $Cfg.VL_LEAN_FG)) { $Cfg.VL_LEAN_FG = '' }

$Cfg.VL_STYLE = switch ([string]$Cfg.VL_STYLE) {
    'pill' { 'pill'; break }
    'lean' { 'lean'; break }
    'classic' { 'classic'; break }
    default { 'pill' }
}
$Cfg.VL_LAYOUT = switch ([string]$Cfg.VL_LAYOUT) {
    'fixed' { 'fixed'; break }
    'auto' { 'auto'; break }
    default { 'fixed' }
}

# Bash applies ASCII first, then classic's lean defaults, then lean overrides.
if ($Cfg.VL_ASCII -eq '1') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_SEP = ''
    $Cfg.VL_BAR_FILL = '#'
    $Cfg.VL_BAR_EMPTY = '-'
    $Cfg.VL_NODE_GLYPH = 'node'
    $Cfg.VL_PY_GLYPH = 'py'
}
if ($Cfg.VL_STYLE -eq 'classic') {
    $Cfg.VL_STYLE = 'lean'
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) { $Cfg.VL_LEAN_BG = if ([string]::IsNullOrEmpty($Cfg.VL_BG_BAR)) { '238' } else { $Cfg.VL_BG_BAR } }
    if ([string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_R)) { $Cfg.VL_LEAN_CAP_R = $Cfg.VL_SEP }
}
if ($Cfg.VL_STYLE -eq 'lean') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_FG_TEXT = $Cfg.VL_LEAN_FG
}

$NoColor = $Cfg.VL_NOCOLOR -eq '1'
$Esc = [char]27
$Rst = "$Esc[0m"
$Bold = "$Esc[1m"
$Norm = "$Esc[22m"
$G = @{
    Branch = Glyph 0x2387
    Diamond = Glyph 0x25C6
    Flag = Glyph 0x2691
    Dot = Glyph 0x2299
    Pencil = Glyph 0x270E
    Hourglass = Glyph 0x29D6
    Psi = Glyph 0x03C8
    Ahead = Glyph 0x21E1
    Behind = Glyph 0x21E3
    Ellipsis = Glyph 0x2026
    Up = Glyph 0x2191
    Down = Glyph 0x2193
    Reset = Glyph 0x21BA
    Check = Glyph 0x2713
    BurnTo = Glyph 0x21E2
}

function Get-Fg([string]$Spec) {
    if ($NoColor -or [string]::IsNullOrEmpty($Spec)) { return '' }
    if ($Spec.Contains(',')) {
        $p = $Spec.Split(',')
        return "$Esc[38;2;$($p[0]);$($p[1]);$($p[2])m"
    }
    return "$Esc[38;5;${Spec}m"
}

function Get-Bg([string]$Spec) {
    if ($NoColor -or [string]::IsNullOrEmpty($Spec)) { return '' }
    if ($Spec.Contains(',')) {
        $p = $Spec.Split(',')
        return "$Esc[48;2;$($p[0]);$($p[1]);$($p[2])m"
    }
    return "$Esc[48;5;${Spec}m"
}

function New-Bar([int]$Pct, [int]$Width) {
    if ($Pct -lt 0) { $Pct = 0 }
    if ($Pct -gt 100) { $Pct = 100 }
    $filled = [int][math]::Floor(($Pct * $Width + 50) / 100)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $filled; $i++) { [void]$sb.Append($Cfg.VL_BAR_FILL) }
    for ($i = $filled; $i -lt $Width; $i++) { [void]$sb.Append($Cfg.VL_BAR_EMPTY) }
    return $sb.ToString()
}

function Format-Tok([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return '0' }
    if ($Raw -notmatch '^[0-9]+$') { return $Raw }
    $n = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$n)) { return '0' }
    if ($n -ge 1000000) { return ('{0}.{1}M' -f [math]::Floor($n / 1000000), [math]::Floor(($n % 1000000) / 100000)) }
    if ($n -ge 1000) { return ('{0}.{1}k' -f [math]::Floor($n / 1000), [math]::Floor(($n % 1000) / 100)) }
    return [string]$n
}

function Get-PctValue([string]$Raw, [ref]$Result) {
    if ([string]::IsNullOrEmpty($Raw)) { return $false }
    $value = 0.0
    if (-not (Try-BoundedDouble $Raw -1000000 1000000 ([ref]$value))) { $value = 0 }
    if ($value -lt 0) { $value = 0 }
    if ($value -gt 100) { $value = 100 }
    $Result.Value = [int][math]::Round($value, [System.MidpointRounding]::ToEven)
    return $true
}

function Get-PctFg([int]$Pct) {
    if ($Pct -ge [int]$Cfg.VL_HOT_PCT) { return $Cfg.VL_FG_HOT }
    if ($Pct -ge [int]$Cfg.VL_WARN_PCT) { return $Cfg.VL_FG_WARN }
    return $Cfg.VL_FG_OK
}

function Get-Trunc([string]$S, [int]$Max) {
    if ($null -eq $S) { return '' }
    if ($Max -le 0 -or $S.Length -le $Max) { return $S }
    if ($Max -lt 3) { return $S.Substring(0, $Max) }
    $head = [int][math]::Floor(($Max - 1) / 2)
    $tail = $Max - 1 - $head
    return $S.Substring(0, $head) + $G.Ellipsis + $S.Substring($S.Length - $tail)
}

function ConvertTo-Epoch([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    $numeric = 0.0
    if (Try-BoundedDouble $Raw 0 253402300799 ([ref]$numeric)) { return [long][math]::Floor($numeric) }
    $dto = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([DateTimeOffset]::TryParse($Raw, $Invariant, $styles, [ref]$dto)) { return $dto.ToUnixTimeSeconds() }
    return $null
}

$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Immutable burn and limit state. Percentages are integer milli-percent and all
# midpoint decisions use exact Int64 quotient/remainder arithmetic.
function ConvertTo-StatePct([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    $match = [regex]::Match($Raw, '\A(0|[1-9][0-9]?|100)(?:\.([0-9]{1,6}))?\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $whole = 0
    if (-not [int]::TryParse($match.Groups[1].Value, $IntegerStyle, $Invariant, [ref]$whole)) { return $null }
    $fraction = $match.Groups[2].Value
    if ($whole -eq 100 -and $fraction -match '[1-9]') { return $null }
    $six = ($fraction + '000000').Substring(0, 6)
    $keep = 0
    $rest = 0
    if (-not [int]::TryParse($six.Substring(0, 3), $IntegerStyle, $Invariant, [ref]$keep)) { return $null }
    if (-not [int]::TryParse($six.Substring(3, 3), $IntegerStyle, $Invariant, [ref]$rest)) { return $null }
    $milli = $whole * 1000 + $keep
    if ($rest -gt 500 -or ($rest -eq 500 -and ($milli % 2) -eq 1)) { $milli++ }
    if ($milli -lt 0 -or $milli -gt 100000) { return $null }
    $q = 0L
    $r = 0L
    $q = [Math]::DivRem([long]$milli, 1000L, [ref]$r)
    return [pscustomobject]@{
        Milli = [int]$milli
        Canonical = [string]::Format($Invariant, '{0:000}.{1:000}', $q, $r)
    }
}

function ConvertTo-StateEpoch([string]$Raw, [int]$Width) {
    if ([string]::IsNullOrEmpty($Raw) -or $Raw -notmatch '\A(?:0|[1-9][0-9]{0,11})\z') { return $null }
    $value = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value)) { return $null }
    if ($value -lt 0 -or $value -gt 253402300799L) { return $null }
    if ($Width -eq 10 -and $value -gt 9999999999L) { return $null }
    $format = 'D' + [string]$Width
    return [pscustomobject]@{ Value = $value; Padded = $value.ToString($format, $Invariant) }
}

function ConvertTo-StatePayloadEpoch([string]$Raw, [int]$Width) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    if ($Raw.IndexOf('T') -ge 0) {
        $value = ConvertTo-Epoch $Raw
        if ($null -eq $value) { return $null }
        return ConvertTo-StateEpoch ([string]$value) $Width
    }
    return ConvertTo-StateEpoch $Raw $Width
}

function Get-RoundEvenInt64([long]$Numerator, [long]$Denominator) {
    if ($Numerator -lt 0 -or $Denominator -le 0) { return 0L }
    $remainder = 0L
    $quotient = [Math]::DivRem($Numerator, $Denominator, [ref]$remainder)
    $twice = $remainder * 2L
    if ($twice -gt $Denominator -or ($twice -eq $Denominator -and ($quotient % 2L) -eq 1L)) { $quotient++ }
    return $quotient
}

function Format-StateRate([long]$ScaledNumerator, [long]$Denominator) {
    if ($ScaledNumerator -lt 0 -or $Denominator -le 0) { return '0.0000000000' }
    $scaled = Get-RoundEvenInt64 $ScaledNumerator $Denominator
    $fraction = 0L
    $whole = [Math]::DivRem($scaled, 10000000000L, [ref]$fraction)
    return [string]::Format($Invariant, '{0}.{1:0000000000}', $whole, $fraction)
}

function Format-StatePct([int]$Milli) {
    $fraction = 0L
    $whole = [Math]::DivRem([long]$Milli, 1000L, [ref]$fraction)
    return [string]::Format($Invariant, '{0:000}.{1:000}', $whole, $fraction)
}

function Get-StatePaths([string]$Base) {
    $full = ConvertTo-LocalFullPath $Base ([Environment]::CurrentDirectory)
    if ([string]::IsNullOrEmpty($full)) { return $null }
    $root = $full
    if ($root.EndsWith('.tsv', [StringComparison]::Ordinal)) { $root = $root.Substring(0, $root.Length - 4) }
    $root += '.d'
    return [pscustomobject]@{ Base = $full; Root = $root }
}

function Test-StateRoot([string]$Root) {
    if ([string]::IsNullOrEmpty($Root) -or -not (Test-NoReparseComponents $Root)) { return $false }
    try {
        $attrs = [IO.File]::GetAttributes($Root)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        return ($attrs -band [IO.FileAttributes]::Directory) -ne 0
    } catch [IO.FileNotFoundException] { return $true }
    catch [IO.DirectoryNotFoundException] { return $true }
    catch { return $false }
}

function Test-StateRegularFile([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-NoReparseComponents $Path)) { return $false }
    try {
        $attrs = [IO.File]::GetAttributes($Path)
        return (($attrs -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and ($attrs -band [IO.FileAttributes]::Directory) -eq 0)
    } catch { return $false }
}

function Get-EmptyStateDirectoryStatus([string]$Path) {
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-NoReparseComponents $Path)) { return [pscustomobject]@{ Success=$false; Empty=$false } }
    $enumerator = $null
    try {
        $attrs = [IO.File]::GetAttributes($Path)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attrs -band [IO.FileAttributes]::Directory) -eq 0) { return [pscustomobject]@{ Success=$true; Empty=$false } }
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($Path).GetEnumerator()
        return [pscustomobject]@{ Success=$true; Empty=(-not $enumerator.MoveNext()) }
    } catch { return [pscustomobject]@{ Success=$false; Empty=$false } }
    finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
}

function Test-EmptyStateDirectory([string]$Path) {
    $status = Get-EmptyStateDirectoryStatus $Path
    return $status.Success -and $status.Empty
}

function Test-StateObjectExists([string]$Path) {
    try { [void][IO.File]::GetAttributes($Path); return $true }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { return $true }
}

function ConvertFrom-CanonicalStatePct([string]$Raw) {
    if ($Raw -notmatch '\A(?:0[0-9]{2}|100)\.[0-9]{3}\z') { return $null }
    $whole = 0
    $fraction = 0
    if (-not [int]::TryParse($Raw.Substring(0, 3), $IntegerStyle, $Invariant, [ref]$whole)) { return $null }
    if (-not [int]::TryParse($Raw.Substring(4, 3), $IntegerStyle, $Invariant, [ref]$fraction)) { return $null }
    $milli = $whole * 1000 + $fraction
    if ($milli -gt 100000) { return $null }
    return $milli
}

function ConvertFrom-BurnName([string]$Name, [long]$NowValue) {
    $match = [regex]::Match($Name, '\Ab_([0-9]{12})_([0-9]{12})_((?:0[0-9]{2}|100)\.[0-9]{3})_([0-9]{4})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $reset = 0L
    $sample = 0L
    if (-not [long]::TryParse($match.Groups[1].Value, $IntegerStyle, $Invariant, [ref]$reset)) { return $null }
    if (-not [long]::TryParse($match.Groups[2].Value, $IntegerStyle, $Invariant, [ref]$sample)) { return $null }
    if ($reset -gt 253402300799L -or $sample -gt 253402300799L) { return $null }
    $pct = ConvertFrom-CanonicalStatePct $match.Groups[3].Value
    if ($null -eq $pct) { return $null }
    $plausible = $sample -le ($NowValue + 300L) -and $reset -ge $sample -and $reset -le ($NowValue + 21600L)
    return [pscustomobject]@{ Name=$Name; Reset=$reset; Sample=$sample; Pct=[int]$pct; Plausible=$plausible }
}

function ConvertFrom-LimitName([string]$Name, [long]$NowValue, [long]$MaxAhead) {
    $match = [regex]::Match($Name, '\A([0-9]{10})_((?:0[0-9]{2}|100)\.[0-9]{3})\z', [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $null }
    $reset = 0L
    if (-not [long]::TryParse($match.Groups[1].Value, $IntegerStyle, $Invariant, [ref]$reset)) { return $null }
    $pct = ConvertFrom-CanonicalStatePct $match.Groups[2].Value
    if ($null -eq $pct) { return $null }
    $plausible = $reset -gt $NowValue -and $reset -le ($NowValue + $MaxAhead)
    return [pscustomobject]@{ Name=$Name; Reset=$reset; Pct=[int]$pct; Plausible=$plausible }
}

function Get-StateDirectorySnapshot([string]$Root, [string]$Kind, [int]$Cap, [long]$NowValue, [long]$MaxAhead) {
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-StateRoot $Root)) { return [pscustomobject]@{ Complete=$false; Raw=0; Entries=@() } }
    if (-not [IO.Directory]::Exists($Root)) { return [pscustomobject]@{ Complete=$true; Raw=0; Entries=@() } }
    $raw = 0
    $enumerator = $null
    try {
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries($Root).GetEnumerator()
        while ($enumerator.MoveNext()) {
            $path = [string]$enumerator.Current
            $raw++
            if ($raw -gt $Cap) { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            $full = ConvertTo-LocalFullPath $path $Root
            if ([string]::IsNullOrEmpty($full) -or -not (Test-PathInside $full $Root)) { continue }
            if (-not [IO.Path]::GetDirectoryName($full).Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $name = [IO.Path]::GetFileName($full)
            try { $attrs = [IO.File]::GetAttributes($full) } catch { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if ($Kind -eq 'burn') {
                $parsed = ConvertFrom-BurnName $name $NowValue
                if ($null -eq $parsed -or ($attrs -band [IO.FileAttributes]::Directory) -ne 0) { continue }
                try { if ((New-Object IO.FileInfo($full)).Length -ne 0) { continue } } catch { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
            } else {
                $parsed = ConvertFrom-LimitName $name $NowValue $MaxAhead
                if ($null -eq $parsed -or ($attrs -band [IO.FileAttributes]::Directory) -eq 0) { continue }
                $emptyStatus = Get-EmptyStateDirectoryStatus $full
                if (-not $emptyStatus.Success) { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
                if (-not $emptyStatus.Empty) { continue }
            }
            $parsed | Add-Member -NotePropertyName Path -NotePropertyValue $full
            [void]$entries.Add($parsed)
        }
    } catch { return [pscustomobject]@{ Complete=$false; Raw=$raw; Entries=@() } }
    finally { if ($null -ne $enumerator) { $enumerator.Dispose() } }
    return [pscustomobject]@{ Complete=$true; Raw=$raw; Entries=$entries.ToArray() }
}

function ConvertFrom-LegacyRecord([string]$Record, [long]$NowValue) {
    $fields = $Record.Split(@("`t"), [StringSplitOptions]::None)
    if ($fields.Length -ne 3) { return $null }
    $sampleValue = ConvertTo-StateEpoch $fields[0] 12
    $pct = ConvertTo-StatePct $fields[1]
    $resetValue = ConvertTo-StateEpoch $fields[2] 12
    if ($null -eq $sampleValue -or $null -eq $pct -or $null -eq $resetValue) { return $null }
    $sample = [long]$sampleValue.Value
    $reset = [long]$resetValue.Value
    if ($sample -gt ($NowValue + 300L) -or $reset -lt $sample -or $reset -gt ($NowValue + 21600L)) { return $null }
    return [pscustomobject]@{ Reset=$reset; Sample=$sample; Pct=[int]$pct.Milli }
}

function Read-LegacyState([string]$Path, [long]$NowValue) {
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    if (-not [IO.File]::Exists($Path)) {
        if (Test-StateObjectExists $Path) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
        if (Test-NoReparseComponents $Path) { return [pscustomobject]@{ Complete=$true; Rows=@() } }
        return [pscustomobject]@{ Complete=$false; Rows=@() }
    }
    if (-not (Test-StateRegularFile $Path)) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share, 4096, [IO.FileOptions]::SequentialScan)
        $length = [long]$stream.Length
        if ($length -gt 1048576L) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
        $buffer = New-Object byte[] 4096
        $builder = New-Object Text.StringBuilder
        $remaining = $length
        $physical = 0
        $recordLength = 0
        $rowAscii = $true
        while ($remaining -gt 0) {
            $want = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $want)
            if ($read -le 0) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
            $remaining -= $read
            for ($i=0; $i -lt $read; $i++) {
                $byte = [int]$buffer[$i]
                if ($byte -eq 10) {
                    $physical++
                    if ($physical -gt 4096) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
                    if ($rowAscii) {
                        $row = ConvertFrom-LegacyRecord $builder.ToString() $NowValue
                        if ($null -ne $row) {
                            if ($queue.Count -eq 512) { [void]$queue.Dequeue() }
                            $queue.Enqueue($row)
                        }
                    }
                    [void]$builder.Clear(); $recordLength=0; $rowAscii=$true
                    continue
                }
                $recordLength++
                if ($recordLength -gt 4096) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
                if ($byte -eq 9 -or $byte -eq 46 -or ($byte -ge 48 -and $byte -le 57)) { [void]$builder.Append([char]$byte) }
                else { $rowAscii=$false }
            }
        }
        if ($recordLength -gt 0) {
            $physical++
            if ($physical -gt 4096) { return [pscustomobject]@{ Complete=$false; Rows=@() } }
            if ($rowAscii) {
                $row = ConvertFrom-LegacyRecord $builder.ToString() $NowValue
                if ($null -ne $row) {
                    if ($queue.Count -eq 512) { [void]$queue.Dequeue() }
                    $queue.Enqueue($row)
                }
            }
        }
        return [pscustomobject]@{ Complete=$true; Rows=$queue.ToArray() }
    } catch { return [pscustomobject]@{ Complete=$false; Rows=@() } }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Sort-StateEntries([object[]]$Entries) {
    $list = New-Object 'System.Collections.Generic.List[object]'
    $list.AddRange($Entries)
    $comparison = [System.Comparison[object]]{
        param($left, $right)
        return [string]::CompareOrdinal([string]$left.Name, [string]$right.Name)
    }
    $list.Sort($comparison)
    return ,($list.ToArray())
}

function Get-BurnRetention([object[]]$Entries, [int]$Trim) {
    $sorted = Sort-StateEntries $Entries
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $representatives = @{}
    foreach ($entry in $sorted) {
        if (-not $entry.Plausible) { [void]$candidates.Add($entry); continue }
        $key = ([string]$entry.Reset) + '_' + ([string]$entry.Sample)
        if (-not $representatives.ContainsKey($key)) { $representatives[$key] = $entry; continue }
        $old = $representatives[$key]
        $replace = $entry.Pct -gt $old.Pct -or ($entry.Pct -eq $old.Pct -and [string]::CompareOrdinal($entry.Name, $old.Name) -lt 0)
        if ($replace) { [void]$candidates.Add($old); $representatives[$key] = $entry }
        else { [void]$candidates.Add($entry) }
    }
    $reps = Sort-StateEntries @($representatives.Values)
    $oldCount = $reps.Count - $Trim
    if ($oldCount -lt 0) { $oldCount = 0 }
    for ($i=0; $i -lt $oldCount; $i++) { [void]$candidates.Add($reps[$i]) }
    return [pscustomobject]@{ Candidates=$candidates.ToArray(); Representatives=$reps }
}

function Get-LimitRetention([object[]]$Entries) {
    $sorted = Sort-StateEntries $Entries
    $winner = $null
    foreach ($entry in $sorted) { if ($entry.Plausible) { $winner = $entry } }
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $sorted) { if ($null -eq $winner -or -not [object]::ReferenceEquals($entry, $winner)) { [void]$candidates.Add($entry) } }
    return [pscustomobject]@{ Candidates=$candidates.ToArray(); Winner=$winner }
}

function Test-BurnDeleteCandidate([string]$Root, $Entry) {
    if ($null -eq $Entry -or -not $Entry.Path.Equals([IO.Path]::Combine($Root, $Entry.Name), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-StateRoot $Root) -or -not [IO.Directory]::Exists($Root)) { return $false }
    if ($null -eq (ConvertFrom-BurnName $Entry.Name $Now)) { return $false }
    try {
        $attrs = [IO.File]::GetAttributes($Entry.Path)
        if (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($attrs -band [IO.FileAttributes]::Directory) -ne 0) { return $false }
        return (New-Object IO.FileInfo($Entry.Path)).Length -eq 0
    } catch { return $false }
}

function Test-LimitDeleteCandidate([string]$Root, $Entry, [long]$MaxAhead) {
    if ($null -eq $Entry -or -not $Entry.Path.Equals([IO.Path]::Combine($Root, $Entry.Name), [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if (-not (Test-StateRoot $Root) -or -not [IO.Directory]::Exists($Root)) { return $false }
    if ($null -eq (ConvertFrom-LimitName $Entry.Name $Now $MaxAhead)) { return $false }
    return Test-EmptyStateDirectory $Entry.Path
}

function Remove-StateCandidates([string]$Root, [object[]]$Candidates, [string]$Kind, [long]$MaxAhead, [bool]$Mutate) {
    if (-not $Mutate) { return [pscustomobject]@{ Resolved=0; Clean=($Candidates.Count -eq 0) } }
    $limit = [Math]::Min(128, $Candidates.Count)
    $resolved = 0
    for ($i=0; $i -lt $limit; $i++) {
        $entry = $Candidates[$i]
        if (-not (Test-StateObjectExists $entry.Path)) { $resolved++; continue }
        $safe = $false
        if ($Kind -eq 'burn') { $safe = Test-BurnDeleteCandidate $Root $entry }
        else { $safe = Test-LimitDeleteCandidate $Root $entry $MaxAhead }
        if (-not $safe) { continue }
        try {
            if ($Kind -eq 'burn') { [IO.File]::Delete($entry.Path) }
            else { [IO.Directory]::Delete($entry.Path, $false) }
        } catch { }
        if (-not (Test-StateObjectExists $entry.Path)) { $resolved++ }
    }
    return [pscustomobject]@{ Resolved=$resolved; Clean=($resolved -eq $Candidates.Count) }
}

function Get-CurrentLimit([string]$RawPct, [string]$RawReset, [long]$NowValue, [long]$MaxAhead) {
    $pct = ConvertTo-StatePct $RawPct
    $reset = ConvertTo-StatePayloadEpoch $RawReset 10
    if ($null -eq $pct -or $null -eq $reset) { return [pscustomobject]@{ Valid=$false; Pct=0; Reset=0L } }
    $value = [long]$reset.Value
    if ($value -le $NowValue -or $value -gt ($NowValue + $MaxAhead)) { return [pscustomobject]@{ Valid=$false; Pct=0; Reset=0L } }
    return [pscustomobject]@{ Valid=$true; Pct=[int]$pct.Milli; Reset=$value }
}

function Select-LimitResult($Snapshot, $Retention, $Current) {
    $valid = $false
    $reset = 0L
    $pct = 0
    if ($Snapshot.Complete -and $null -ne $Retention.Winner) { $valid=$true; $reset=[long]$Retention.Winner.Reset; $pct=[int]$Retention.Winner.Pct }
    if ($Current.Valid -and (-not $valid -or $Current.Reset -gt $reset -or ($Current.Reset -eq $reset -and $Current.Pct -gt $pct))) {
        $valid=$true; $reset=[long]$Current.Reset; $pct=[int]$Current.Pct
    }
    return [pscustomobject]@{ Valid=$valid; Reset=$reset; Pct=$pct }
}

function Publish-LimitState([string]$Root, $Current, $Snapshot, $Gc, [long]$MaxAhead, [bool]$Mutate) {
    if (-not $Mutate -or -not $Snapshot.Complete -or -not $Gc.Clean -or -not $Current.Valid) { return $false }
    if (($Snapshot.Raw - $Gc.Resolved) -ge 384) { return $false }
    if (-not (Test-StateRoot $Root)) { return $false }
    $name = $Current.Reset.ToString('D10', $Invariant) + '_' + (Format-StatePct $Current.Pct)
    $path = [IO.Path]::Combine($Root, $name)
    if (-not (Test-NoReparseComponents $path)) { return $false }
    try { [void][IO.Directory]::CreateDirectory($path) } catch { return $false }
    return Test-LimitDeleteCandidate $Root ([pscustomobject]@{ Name=$name; Path=$path }) $MaxAhead
}

function Publish-BurnState([string]$Root, $Current, $Snapshot, $Gc, [bool]$Mutate) {
    if (-not $Mutate -or -not $Snapshot.Complete -or -not $Gc.Clean -or -not $Current.Valid) { return $false }
    if (($Snapshot.Raw - $Gc.Resolved) -ge 3968) { return $false }
    if (-not (Test-StateRoot $Root)) { return $false }
    try { [void][IO.Directory]::CreateDirectory($Root) } catch { return $false }
    if (-not (Test-StateRoot $Root) -or -not [IO.Directory]::Exists($Root)) { return $false }
    for ($slot=0; $slot -lt 32; $slot++) {
        $name = 'b_' + $Current.Reset.ToString('D12', $Invariant) + '_' + $Current.Sample.ToString('D12', $Invariant) + '_' + (Format-StatePct $Current.Pct) + '_' + $slot.ToString('D4', $Invariant)
        $path = [IO.Path]::Combine($Root, $name)
        try {
            $stream = New-Object IO.FileStream($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $stream.Dispose()
            return $true
        } catch [IO.IOException] {
            if (Test-StateObjectExists $path) { continue }
            return $false
        } catch { return $false }
    }
    return $false
}

function Get-Burn5Estimate($Snapshot, $Retention, $Legacy, $Current, [long]$NowValue, [int]$Window) {
    $warming = [pscustomobject]@{ State='warming'; Eta='inf'; Rate='0.0000000000'; Ttr=0L }
    if (-not $Snapshot.Complete -or -not $Legacy.Complete) { return $warming }
    $observations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Retention.Representatives) { if ($entry.Plausible) { [void]$observations.Add($entry) } }
    foreach ($row in $Legacy.Rows) { [void]$observations.Add($row) }
    if ($Current.Valid) { [void]$observations.Add($Current) }
    if ($observations.Count -eq 0) { return $warming }
    $maxReset = 0L
    foreach ($observation in $observations) { if ([long]$observation.Reset -gt $maxReset) { $maxReset = [long]$observation.Reset } }
    if ($maxReset -le 0) { return $warming }
    $dedup = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $perSecond = New-Object 'System.Collections.Generic.Dictionary[long,int]'
    foreach ($observation in $observations) {
        if ([long]$observation.Reset -ne $maxReset) { continue }
        $key = ([string]$observation.Reset) + '_' + ([string]$observation.Sample) + '_' + ([string]$observation.Pct)
        if (-not $dedup.Add($key)) { continue }
        $sample = [long]$observation.Sample
        $pct = [int]$observation.Pct
        if (-not $perSecond.ContainsKey($sample) -or $pct -gt $perSecond[$sample]) { $perSecond[$sample] = $pct }
    }
    if ($perSecond.Count -eq 0) { return $warming }
    $samples = [long[]]@($perSecond.Keys)
    [Array]::Sort($samples)
    $ttr = $maxReset - $NowValue
    if ($ttr -lt 0) { $ttr = 0 }
    $cutoff = $NowValue - $Window
    $unusedRemainder = 0L
    $minSpan = [Math]::DivRem([long]$Window, 10L, [ref]$unusedRemainder)
    $firstTime = 0L; $firstPct = -1; $lastTime = 0L; $lastPct = -1; $crossings = 0; $anyCrossing = $false
    for ($i=1; $i -lt $samples.Length; $i++) {
        $aRem = 0L; $bRem = 0L
        $a = [Math]::DivRem([long]$perSecond[$samples[$i-1]], 1000L, [ref]$aRem)
        $b = [Math]::DivRem([long]$perSecond[$samples[$i]], 1000L, [ref]$bRem)
        if ($b -le $a) { continue }
        $anyCrossing = $true
        $crossTime = $samples[$i]
        if ($crossTime -ge $cutoff -and $crossTime -le $NowValue) {
            if ($firstPct -lt 0) { $firstTime=$crossTime; $firstPct=[int]$b }
            $lastTime=$crossTime; $lastPct=[int]$b; $crossings++
        }
    }
    if ($crossings -ge 2 -and $lastTime -gt $firstTime -and $lastPct -gt $firstPct -and ($lastTime - $firstTime) -ge $minSpan) {
        $span = $lastTime - $firstTime
        $delta = [long]($lastPct - $firstPct)
        $latest = [long]$perSecond[$samples[$samples.Length - 1]]
        $eta = Get-RoundEvenInt64 ((100000L - $latest) * $span) ($delta * 1000L)
        $rate = Format-StateRate ($delta * 10000000000L) $span
        return [pscustomobject]@{ State='active'; Eta=$eta; Rate=$rate; Ttr=$ttr }
    }
    if ($anyCrossing -and $crossings -eq 0) { return [pscustomobject]@{ State='idle'; Eta='inf'; Rate='0.0000000000'; Ttr=$ttr } }
    return [pscustomobject]@{ State='warming'; Eta='inf'; Rate='0.0000000000'; Ttr=$ttr }
}

function Get-Burn7Estimate($Limit, [long]$NowValue) {
    if (-not $Limit.Valid) { return [pscustomobject]@{ Eta='inf'; Rate='0.0000000000'; Ttr=0L } }
    $ttr = [long]$Limit.Reset - $NowValue
    if ($ttr -lt 0) { $ttr = 0 }
    $elapsed = $NowValue - ([long]$Limit.Reset - 604800L)
    if ($Limit.Pct -le 0 -or $elapsed -lt 1 -or $elapsed -gt 691200L) { return [pscustomobject]@{ Eta='inf'; Rate='0.0000000000'; Ttr=$ttr } }
    $rate = Format-StateRate ([long]$Limit.Pct * 10000000L) $elapsed
    $eta = Get-RoundEvenInt64 ((100000L - [long]$Limit.Pct) * $elapsed) ([long]$Limit.Pct)
    return [pscustomobject]@{ Eta=$eta; Rate=$rate; Ttr=$ttr }
}

function Get-BurnBinding($Five, $Seven) {
    $fiveFinite = [string]$Five.Eta -ne 'inf'
    $sevenFinite = [string]$Seven.Eta -ne 'inf'
    if ($fiveFinite -and (-not $sevenFinite -or [long]$Five.Eta -le [long]$Seven.Eta)) {
        return [pscustomobject]@{ State='active'; Label='5h'; Eta=[long]$Five.Eta; Rate=$Five.Rate; Ttr=[long]$Five.Ttr }
    }
    if ($sevenFinite) { return [pscustomobject]@{ State='active'; Label='7d'; Eta=[long]$Seven.Eta; Rate=$Seven.Rate; Ttr=[long]$Seven.Ttr } }
    $state = 'warming'
    if ($Five.State -eq 'idle') { $state = 'idle' }
    return [pscustomobject]@{ State=$state; Label=''; Eta='inf'; Rate='0.0000000000'; Ttr=0L }
}

function Get-CorallineState([bool]$BurnGate, [bool]$Limit5Gate, [bool]$Limit7Gate) {
    $mutate = [string]$env:CORALLINE_NO_SAMPLE -ne '1'
    $window = Get-BoundedInt $Cfg.CORALLINE_BURN_WINDOW 600 60 86400
    $trim = Get-BoundedInt $Cfg.BURN_TRIM 1500 1 3000
    $current5 = Get-CurrentLimit $fhPct $fhRst $Now 21600L
    $current7 = Get-CurrentLimit $wdPct $wdRst $Now 691200L
    $currentBurn = [pscustomobject]@{ Valid=$false; Reset=0L; Sample=$Now; Pct=0 }
    if ($current5.Valid -and $current5.Reset -ge $Now) { $currentBurn = [pscustomobject]@{ Valid=$true; Reset=[long]$current5.Reset; Sample=$Now; Pct=[int]$current5.Pct } }

    $emptySnapshot = [pscustomobject]@{ Complete=$false; Raw=0; Entries=@() }
    $emptyLegacy = [pscustomobject]@{ Complete=$false; Rows=@() }
    $burnSnapshot=$emptySnapshot; $limit5Snapshot=$emptySnapshot; $limit7Snapshot=$emptySnapshot; $legacy=$emptyLegacy
    $burnPaths=$null; $limit5Paths=$null; $limit7Paths=$null
    if ($BurnGate) { $burnPaths = Get-StatePaths $Cfg.BURN_FILE }
    if ($Limit5Gate) { $limit5Paths = Get-StatePaths $Cfg.RL5H_FILE }
    if ($Limit7Gate) { $limit7Paths = Get-StatePaths $Cfg.RL7D_FILE }
    $collision = $false
    $roots = New-Object 'System.Collections.Generic.List[object]'
    foreach ($candidateRoot in @($burnPaths, $limit5Paths, $limit7Paths)) { if ($null -ne $candidateRoot) { [void]$roots.Add($candidateRoot) } }
    for ($i=0; $i -lt $roots.Count; $i++) {
        for ($j=$i+1; $j -lt $roots.Count; $j++) { if ($roots[$i].Root.Equals($roots[$j].Root, [StringComparison]::OrdinalIgnoreCase)) { $collision=$true } }
    }
    if (-not $collision) {
        if ($BurnGate -and $null -ne $burnPaths) {
            $burnSnapshot = Get-StateDirectorySnapshot $burnPaths.Root 'burn' 4096 $Now 21600L
            $legacy = Read-LegacyState $burnPaths.Base $Now
            if (-not $legacy.Complete) { $burnSnapshot = [pscustomobject]@{ Complete=$false; Raw=$burnSnapshot.Raw; Entries=@() } }
        }
        if ($Limit5Gate -and $null -ne $limit5Paths) { $limit5Snapshot = Get-StateDirectorySnapshot $limit5Paths.Root 'limit' 512 $Now 21600L }
        if ($Limit7Gate -and $null -ne $limit7Paths) { $limit7Snapshot = Get-StateDirectorySnapshot $limit7Paths.Root 'limit' 512 $Now 691200L }
    }

    $burnRetention = [pscustomobject]@{ Candidates=@(); Representatives=@() }
    $limit5Retention = [pscustomobject]@{ Candidates=@(); Winner=$null }
    $limit7Retention = [pscustomobject]@{ Candidates=@(); Winner=$null }
    if ($burnSnapshot.Complete) { $burnRetention = Get-BurnRetention $burnSnapshot.Entries $trim }
    if ($limit5Snapshot.Complete) { $limit5Retention = Get-LimitRetention $limit5Snapshot.Entries }
    if ($limit7Snapshot.Complete) { $limit7Retention = Get-LimitRetention $limit7Snapshot.Entries }

    $burnGc = [pscustomobject]@{ Resolved=0; Clean=$false }
    $limit5Gc = [pscustomobject]@{ Resolved=0; Clean=$false }
    $limit7Gc = [pscustomobject]@{ Resolved=0; Clean=$false }
    if ($burnSnapshot.Complete) { $burnGc = Remove-StateCandidates $burnPaths.Root $burnRetention.Candidates 'burn' 21600L $mutate }
    if ($limit5Snapshot.Complete) { $limit5Gc = Remove-StateCandidates $limit5Paths.Root $limit5Retention.Candidates 'limit' 21600L $mutate }
    if ($limit7Snapshot.Complete) { $limit7Gc = Remove-StateCandidates $limit7Paths.Root $limit7Retention.Candidates 'limit' 691200L $mutate }

    $limit5 = Select-LimitResult $limit5Snapshot $limit5Retention $current5
    $limit7 = Select-LimitResult $limit7Snapshot $limit7Retention $current7
    if ($BurnGate -and $burnSnapshot.Complete) { [void](Publish-BurnState $burnPaths.Root $currentBurn $burnSnapshot $burnGc $mutate) }
    if ($Limit5Gate -and $limit5Snapshot.Complete) { [void](Publish-LimitState $limit5Paths.Root $current5 $limit5Snapshot $limit5Gc 21600L $mutate) }
    if ($Limit7Gate -and $limit7Snapshot.Complete) { [void](Publish-LimitState $limit7Paths.Root $current7 $limit7Snapshot $limit7Gc 691200L $mutate) }

    $five = Get-Burn5Estimate $burnSnapshot $burnRetention $legacy $currentBurn $Now $window
    if ($Cfg.VL_LIMIT_SYNC -eq '1') { $seven = Get-Burn7Estimate $limit7 $Now }
    else { $seven = Get-Burn7Estimate $current7 $Now }
    $burn = Get-BurnBinding $five $seven
    $burn | Add-Member -NotePropertyName Reported -NotePropertyValue ($current5.Valid -or $current7.Valid)
    return [pscustomobject]@{
        Burn=$burn; Five=$five; Seven=$seven; Limit5=$limit5; Limit7=$limit7
        Current5=$current5; Current7=$current7; BurnSnapshotComplete=$burnSnapshot.Complete
        Limit5SnapshotComplete=$limit5Snapshot.Complete; Limit7SnapshotComplete=$limit7Snapshot.Complete
    }
}

function Format-Countdown([string]$ResetsAt) {
    $ep = ConvertTo-Epoch $ResetsAt
    if ($null -eq $ep) { return '' }
    $diff = [long]$ep - $Now
    if ($diff -le 0) { return 'now' }
    $d = [math]::Floor($diff / 86400)
    $h = [math]::Floor(($diff % 86400) / 3600)
    $m = [math]::Floor(($diff % 3600) / 60)
    if ($d -gt 0) { return ('{0}d{1:00}h' -f $d, $h) }
    if ($h -gt 0) { return ('{0}h{1:00}m' -f $h, $m) }
    return "${m}m"
}

function Format-Duration([double]$Ms, [bool]$IncludeSeconds) {
    $s = [long][math]::Floor($Ms / 1000)
    $h = [math]::Floor($s / 3600)
    $m = [math]::Floor(($s % 3600) / 60)
    $sec = $s % 60
    if ($IncludeSeconds) {
        if ($h -gt 0) { return ('{0}h{1:00}m{2:00}s' -f $h, $m, $sec) }
        if ($m -gt 0) { return ('{0}m{1:00}s' -f $m, $sec) }
        return "${s}s"
    }
    if ($h -gt 0) { return ('{0}h{1:00}m' -f $h, $m) }
    if ($m -gt 0) { return "${m}m" }
    return "${s}s"
}

function Get-ClockText {
    $now = Get-Date
    if ($Cfg.VL_CLOCK -eq '24h') {
        if ($Cfg.VL_CLOCK_SECONDS -eq '1') { return $now.ToString('HH:mm:ss', $Invariant) }
        return $now.ToString('HH:mm', $Invariant)
    }
    $format = 'hh:mm tt'
    if ($Cfg.VL_CLOCK_SECONDS -eq '1') { $format = 'hh:mm:ss tt' }
    $text = $now.ToString($format, $Invariant)
    if ($text.EndsWith('AM', [System.StringComparison]::Ordinal)) { return $text.Substring(0, $text.Length - 2) + 'am' }
    if ($text.EndsWith('PM', [System.StringComparison]::Ordinal)) { return $text.Substring(0, $text.Length - 2) + 'pm' }
    return $text
}

function Get-JsonMember($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    try {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    } catch { return $null }
}

function Get-JsonPath($Object, [string[]]$Names) {
    $value = $Object
    foreach ($name in $Names) {
        $value = Get-JsonMember $value $name
        if ($null -eq $value) { return $null }
    }
    return $value
}

function To-InvariantString($Value) {
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return [string]$Value }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [System.IFormattable] -and -not ($Value -is [System.Array])) {
        return $Value.ToString($null, $Invariant)
    }
    return ''
}

try { $J = $rawInput | ConvertFrom-Json -ErrorAction Stop } catch { $J = $null }

$cwd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('workspace', 'current_dir')))
if ([string]::IsNullOrEmpty($cwd)) { $cwd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cwd'))) }
$model = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('model', 'display_name')))
$ctxPct = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'used_percentage')))
$tokIn = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'total_input_tokens')))
$tokOut = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'total_output_tokens')))
$tokCr = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'current_usage', 'cache_read_input_tokens')))
$tokCw = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('context_window', 'current_usage', 'cache_creation_input_tokens')))
$fhPct = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'five_hour', 'used_percentage')))
$fhRst = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'five_hour', 'resets_at')))
$wdPct = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'seven_day', 'used_percentage')))
$wdRst = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('rate_limits', 'seven_day', 'resets_at')))
$cost = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_cost_usd')))
$linesAdd = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_lines_added')))
$linesDel = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_lines_removed')))
$outStyle = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('output_style', 'name')))
$durMs = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('cost', 'total_duration_ms')))
$effort = Remove-ControlChars (To-InvariantString (Get-JsonPath $J @('effort', 'level')))

function ConvertTo-ProbePath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $full = ConvertTo-LocalFullPath $Path ([Environment]::CurrentDirectory)
    if ($null -eq $full) { return '' }
    return $full
}

$ProbeCwd = ConvertTo-ProbePath $cwd

function Get-DisplayPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $short = $Path.Replace('\', '/')
    $homeFwd = $HomeDir.Replace('\', '/').TrimEnd('/')
    if (-not [string]::IsNullOrEmpty($homeFwd)) {
        if ($short.Equals($homeFwd, [System.StringComparison]::OrdinalIgnoreCase)) { $short = '~' }
        elseif ($short.StartsWith($homeFwd + '/', [System.StringComparison]::OrdinalIgnoreCase)) { $short = '~' + $short.Substring($homeFwd.Length) }
    }
    if ($short -eq '/') { return '/' }
    if ($short -match '^[A-Za-z]:/?$') { return $short.Substring(0, 2) + '/' }

    $parts = New-Object System.Collections.Generic.List[string]
    $prefix = ''
    if ($short.StartsWith('//', [System.StringComparison]::Ordinal)) {
        $raw = $short.Substring(2).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
        if ($raw.Length -eq 0) { return '//' }
        if ($raw.Length -eq 1) { return '//' + $raw[0] }
        $prefix = '//' + $raw[0] + '/' + $raw[1]
        for ($i = 2; $i -lt $raw.Length; $i++) { [void]$parts.Add($raw[$i]) }
        $logicalCount = 2 + $parts.Count
    } elseif ($short -match '^([A-Za-z]:)(?:/(.*))?$') {
        $prefix = $Matches[1]
        $rest = $Matches[2]
        if (-not [string]::IsNullOrEmpty($rest)) {
            foreach ($part in $rest.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        }
        $logicalCount = 1 + $parts.Count
    } elseif ($short.StartsWith('/', [System.StringComparison]::Ordinal)) {
        $prefix = '/'
        foreach ($part in $short.Substring(1).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        $logicalCount = 1 + $parts.Count
    } elseif ($short -eq '~' -or $short.StartsWith('~/', [System.StringComparison]::Ordinal)) {
        $prefix = '~'
        if ($short.Length -gt 2) {
            foreach ($part in $short.Substring(2).Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        }
        $logicalCount = 1 + $parts.Count
    } else {
        foreach ($part in $short.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)) { [void]$parts.Add($part) }
        $logicalCount = $parts.Count
    }

    if ($logicalCount -le [int]$Cfg.VL_PATH_DEPTH) { return $short.TrimEnd('/') }
    $last = ''
    if ($parts.Count -gt 0) { $last = $parts[$parts.Count - 1] }
    if ($prefix.StartsWith('//', [System.StringComparison]::Ordinal)) { return $prefix + '/' + $G.Ellipsis + '/' + $last }
    if ($prefix -eq '/') {
        $first = ''
        if ($parts.Count -gt 0) { $first = $parts[0] }
        return '/' + $first + '/' + $G.Ellipsis + '/' + $last
    }
    if ($prefix -eq '~' -or $prefix -match '^[A-Za-z]:$') {
        $first = ''
        if ($parts.Count -gt 0) { $first = $parts[0] }
        return $prefix + '/' + $first + '/' + $G.Ellipsis + '/' + $last
    }
    if ($parts.Count -ge 2) { return $parts[0] + '/' + $parts[1] + '/' + $G.Ellipsis + '/' + $last }
    return $short
}

$AppCache = @{}
function Get-ApplicationPath([string]$Name) {
    if ($AppCache.ContainsKey($Name)) { return [string]$AppCache[$Name] }
    $path = ''
    try {
        $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { $path = [string]$cmd.Source }
    } catch { $path = '' }
    $AppCache[$Name] = $path
    return $path
}

$env:GIT_OPTIONAL_LOCKS = '0'

function Get-GitState([string]$Cwd) {
    $state = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
    if ([string]::IsNullOrEmpty($Cwd)) { return $state }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return $state }
    try {
        $LASTEXITCODE = 0
        $lines = @(& $git -C $Cwd status --porcelain=v2 --branch 2>$null)
        if ($LASTEXITCODE -ne 0 -or $lines.Count -eq 0) { return $state }
    } catch { return $state }
    $oid = ''
    $head = ''
    $ahead = 0
    $behind = 0
    $staged = $false
    $unstaged = $false
    $untracked = $false
    foreach ($item in $lines) {
        $line = [string]$item
        if ($line.StartsWith('# branch.oid ', [System.StringComparison]::Ordinal)) { $oid = $line.Substring(13) }
        elseif ($line.StartsWith('# branch.head ', [System.StringComparison]::Ordinal)) { $head = $line.Substring(14) }
        elseif ($line.StartsWith('# branch.ab ', [System.StringComparison]::Ordinal)) {
            if ($line -match '\+([0-9]+)[ \t]+-([0-9]+)') {
                [void][int]::TryParse($Matches[1], $IntegerStyle, $Invariant, [ref]$ahead)
                [void][int]::TryParse($Matches[2], $IntegerStyle, $Invariant, [ref]$behind)
            }
        } elseif ($line.StartsWith('? ', [System.StringComparison]::Ordinal)) { $untracked = $true }
        elseif ($line -match '^[12] ') {
            $xy = $line.Substring(2)
            if ($xy.Length -ge 1 -and $xy[0] -ne '.') { $staged = $true }
            if ($xy.Length -ge 2 -and $xy[1] -ne '.') { $unstaged = $true }
        } elseif ($line.StartsWith('u ', [System.StringComparison]::Ordinal)) { $unstaged = $true }
    }
    if ([string]::IsNullOrEmpty($oid)) { return $state }
    if ($head -eq '(detached)' -or [string]::IsNullOrEmpty($head)) { $state.Branch = $oid.Substring(0, [Math]::Min(7, $oid.Length)) }
    else { $state.Branch = Remove-ControlChars $head }
    if ($staged) { $state.Marks += '+' }
    if ($unstaged) { $state.Marks += '!' }
    if ($untracked) { $state.Marks += '?' }
    if ($ahead -gt 0) { $state.Ab += $G.Ahead + [string]$ahead }
    if ($behind -gt 0) { $state.Ab += $G.Behind + [string]$behind }
    if (-not [string]::IsNullOrEmpty($state.Marks)) { $state.Dirty = $true }
    return $state
}

function Get-GitRoot([string]$Cwd) {
    if ([string]::IsNullOrEmpty($Cwd)) { return '' }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return '' }
    $root = ''
    try {
        $LASTEXITCODE = 0
        $result = @(& $git -C $Cwd rev-parse --path-format=absolute --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { $root = [string]$result[0] }
        if ([string]::IsNullOrEmpty($root)) {
            $LASTEXITCODE = 0
            $result = @(& $git -C $Cwd rev-parse --show-toplevel 2>$null)
            if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) { return '' }
            $root = [string]$result[0]
        }
    } catch { return '' }
    $root = (Remove-ControlChars $root).Replace('\', '/').TrimEnd('/')
    if ($root.EndsWith('/.git', [System.StringComparison]::OrdinalIgnoreCase)) { $root = $root.Substring(0, $root.Length - 5) }
    $parts = $root.Split(@('/'), [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -eq 0) { return '' }
    return $parts[$parts.Length - 1]
}

function Get-StashCount([string]$Cwd) {
    if ([string]::IsNullOrEmpty($Cwd)) { return 0 }
    $git = Get-ApplicationPath 'git'
    if ([string]::IsNullOrEmpty($git)) { return 0 }
    try {
        $LASTEXITCODE = 0
        $result = @(& $git -C $Cwd rev-list --walk-reflogs --count refs/stash 2>$null)
        if ($LASTEXITCODE -ne 0 -or $result.Count -eq 0) { return 0 }
        return Get-BoundedInt ([string]$result[0]) 0 0 1000000
    } catch { return 0 }
}

function Read-PinFile([string]$Path) {
    try {
        $attrs = [System.IO.File]::GetAttributes($Path)
        if (($attrs -band [System.IO.FileAttributes]::Directory) -ne 0) { return '' }
        $info = New-Object System.IO.FileInfo($Path)
        if ($info.Length -gt 65536) { return '' }
        $reader = New-Object System.IO.StreamReader($Path, $StrictUtf8, $true)
        try { $line = $reader.ReadLine() } finally { $reader.Dispose() }
        return (Remove-ControlChars ([string]$line)).Trim()
    } catch { return '' }
}

function Get-NodeVersion-Uncached([string]$Dir) {
    if ([string]::IsNullOrEmpty($Dir)) { return '' }
    try { $d = New-Object System.IO.DirectoryInfo($Dir) } catch { $d = $null }
    while ($null -ne $d) {
        foreach ($name in @('.nvmrc', '.node-version')) {
            $value = Read-PinFile ([System.IO.Path]::Combine($d.FullName, $name))
            if (-not [string]::IsNullOrEmpty($value)) { return $value.TrimStart('v') }
        }
        $d = $d.Parent
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $node = Get-ApplicationPath 'node'
        if (-not [string]::IsNullOrEmpty($node)) {
            try {
                $LASTEXITCODE = 0
                $result = @(& $node --version 2>$null)
                if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { return (Remove-ControlChars ([string]$result[0])).Trim().TrimStart('v') }
            } catch { }
        }
    }
    return ''
}

function Get-PythonVersion-Uncached([string]$Dir) {
    $venv = Remove-ControlChars ([string]$env:VIRTUAL_ENV)
    if (-not [string]::IsNullOrEmpty($venv)) {
        try { return [System.IO.Path]::GetFileName($venv.TrimEnd('\', '/')) } catch { }
    }
    $conda = Remove-ControlChars ([string]$env:CONDA_DEFAULT_ENV)
    if (-not [string]::IsNullOrEmpty($conda) -and $conda -ne 'base') { return $conda }
    if (-not [string]::IsNullOrEmpty($Dir)) {
        try { $d = New-Object System.IO.DirectoryInfo($Dir) } catch { $d = $null }
        while ($null -ne $d) {
            $value = Read-PinFile ([System.IO.Path]::Combine($d.FullName, '.python-version'))
            if (-not [string]::IsNullOrEmpty($value)) { return $value }
            $d = $d.Parent
        }
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $python = Get-ApplicationPath 'python3'
        if (-not [string]::IsNullOrEmpty($python)) {
            try {
                $LASTEXITCODE = 0
                $result = @(& $python --version 2>&1)
                if ($LASTEXITCODE -eq 0 -and $result.Count -gt 0) { return ((Remove-ControlChars ([string]$result[0])) -replace '^Python ', '').Trim() }
            } catch { }
        }
    }
    return ''
}

$script:StashCacheSet = $false
$script:StashCache = 0
$script:NodeCacheSet = $false
$script:NodeCache = ''
$script:PythonCacheSet = $false
$script:PythonCache = ''

function Get-StashCount-Cached([string]$Cwd) {
    if (-not $script:StashCacheSet) {
        $script:StashCache = Get-StashCount $Cwd
        $script:StashCacheSet = $true
    }
    return [int]$script:StashCache
}

function Get-NodeVersion([string]$Dir) {
    if (-not $script:NodeCacheSet) {
        $script:NodeCache = [string](Get-NodeVersion-Uncached $Dir)
        $script:NodeCacheSet = $true
    }
    return [string]$script:NodeCache
}

function Get-PythonVersion([string]$Dir) {
    if (-not $script:PythonCacheSet) {
        $script:PythonCache = [string](Get-PythonVersion-Uncached $Dir)
        $script:PythonCacheSet = $true
    }
    return [string]$script:PythonCache
}

function Get-SegmentTokens([string]$List) {
    if ([string]::IsNullOrWhiteSpace($List)) { return @() }
    return @([regex]::Split($List.Trim(), '\s+') | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

$MainSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$MainSegmentLists = @([string]$Cfg.VL_SEGMENTS, [string]$Cfg.VL_SEGMENTS2, [string]$Cfg.VL_SEGMENTS3)
foreach ($list in $MainSegmentLists) {
    foreach ($name in (Get-SegmentTokens $list)) { [void]$MainSegmentNames.Add($name) }
}
$FloatSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$FloatTokens = @(Get-SegmentTokens ([string]$Cfg.VL_FLOAT_SEGMENTS))
$FloatEnabled = $Cfg.VL_FLOAT -eq '1' -and ([string]$Cfg.VL_FLOAT_SEGMENTS).Length -le 4096 -and $FloatTokens.Count -le 64 -and ([string]$Cfg.VL_FLOAT_SEP).Length -le 256
if ($FloatEnabled) { foreach ($name in $FloatTokens) { [void]$FloatSegmentNames.Add($name) } }
$ProbeSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($name in $MainSegmentNames) { [void]$ProbeSegmentNames.Add($name) }
foreach ($name in $FloatSegmentNames) { [void]$ProbeSegmentNames.Add($name) }

# Collision derivation is lexical only and runs even when all state gates are off.
$AllStatePaths = New-Object 'System.Collections.Generic.List[object]'
foreach ($base in @($Cfg.BURN_FILE, $Cfg.RL5H_FILE, $Cfg.RL7D_FILE)) {
    $statePath = Get-StatePaths $base
    if ($null -ne $statePath) { [void]$AllStatePaths.Add($statePath) }
}

$BurnStateGate = $ProbeSegmentNames.Contains('burn')
$Limit5StateGate = $Cfg.VL_LIMIT_SYNC -eq '1' -and $ProbeSegmentNames.Contains('limit5h')
$Limit7StateGate = $Cfg.VL_LIMIT_SYNC -eq '1' -and ($ProbeSegmentNames.Contains('limit7d') -or $BurnStateGate)
$State = $null
if ($BurnStateGate -or $Limit5StateGate -or $Limit7StateGate) {
    $State = Get-CorallineState $BurnStateGate $Limit5StateGate $Limit7StateGate
}

$GitState = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
$GitRoot = ''
if ($ProbeSegmentNames.Contains('git') -or $ProbeSegmentNames.Contains('stash') -or $ProbeSegmentNames.Contains('project')) {
    $GitState = Get-GitState $ProbeCwd
}
if ($ProbeSegmentNames.Contains('project') -and -not [string]::IsNullOrEmpty($GitState.Branch)) { $GitRoot = Get-GitRoot $ProbeCwd }

$SegBgs = New-Object System.Collections.Generic.List[string]
$SegTxt = New-Object System.Collections.Generic.List[string]
$SegLen = New-Object 'System.Collections.Generic.List[int]'

function Remove-Sgr([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return [regex]::Replace($Value, ([string][char]27 + '\[[0-9;]*m'), '')
}

function Get-DisplayWidth([string]$Value) {
    $plain = Remove-Sgr $Value
    $width = 0
    $i = 0
    while ($i -lt $plain.Length) {
        $advance = 1
        try {
            $cp = [char]::ConvertToUtf32($plain, $i)
            if ([char]::IsHighSurrogate($plain[$i])) { $advance = 2 }
        } catch {
            $cp = 0xFFFD
        }
        if ($cp -ge 0x300 -and $cp -le 0x36F -or $cp -ge 0x200B -and $cp -le 0x200F -or $cp -ge 0xFE00 -and $cp -le 0xFE0F) {
            $i += $advance
            continue
        }
        if ($cp -ge 0x1100 -and $cp -le 0x115F -or $cp -ge 0x2E80 -and $cp -le 0xA4CF -or $cp -ge 0xAC00 -and $cp -le 0xD7A3 -or $cp -ge 0xF900 -and $cp -le 0xFAFF -or $cp -ge 0xFE10 -and $cp -le 0xFE19 -or $cp -ge 0xFE30 -and $cp -le 0xFE6F -or $cp -ge 0xFF00 -and $cp -le 0xFF60 -or $cp -ge 0xFFE0 -and $cp -le 0xFFE6 -or $cp -ge 0x1F300 -and $cp -le 0x1FAFF -or $cp -ge 0x20000 -and $cp -le 0x3FFFF) {
            $width += 2
        } else {
            $width++
        }
        $i += $advance
    }
    return $width
}

function Push-Segment([string]$Bg, [string]$Text) {
    [void]$SegBgs.Add($Bg)
    [void]$SegTxt.Add($Text)
    if ($Cfg.VL_LAYOUT -eq 'auto') { [void]$SegLen.Add((Get-DisplayWidth $Text)) }
    else { [void]$SegLen.Add(0) }
}

function Add-DirSegment {
    if ([string]::IsNullOrEmpty($cwd)) { return }
    $short = Get-DisplayPath $cwd
    if ([string]::IsNullOrEmpty($short)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DIR "${Bold}${fg} $short ${Norm}"
}

function Add-ProjectSegment {
    if ([string]::IsNullOrEmpty($GitRoot)) {
        if (-not $MainSegmentNames.Contains('dir')) { Add-DirSegment }
        return
    }
    $tr = Get-Trunc $GitRoot ([int]$Cfg.VL_NAME_MAX)
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_PROJECT
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_DIR }
    Push-Segment $bg "${Bold}${fg} $($Cfg.VL_PROJECT_GLYPH) $tr ${Norm}"
}

function Add-GitSegment {
    if ([string]::IsNullOrEmpty($GitState.Branch)) { return }
    $bg = $Cfg.VL_BG_GIT_OK
    if ($GitState.Dirty) { $bg = $Cfg.VL_BG_GIT_DIRTY }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $tr = Get-Trunc $GitState.Branch ([int]$Cfg.VL_NAME_MAX)
    Push-Segment $bg "${Bold}${fg} $($G.Branch) ${tr}$($GitState.Marks)$($GitState.Ab) ${Norm}"
}

function Add-StashSegment {
    if ([string]::IsNullOrEmpty($GitState.Branch)) { return }
    $count = Get-StashCount-Cached $ProbeCwd
    if ($count -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_STASH
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_GIT_OK }
    Push-Segment $bg "${fg} $($G.Flag) $count "
}

function Add-ModelSegment {
    if ([string]::IsNullOrEmpty($model)) { return }
    $shown = $model -replace '^Claude ', ''
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_MODEL "${Bold}${fg} $($G.Diamond) $shown ${Norm}"
}

function Add-EffortSegment {
    if ([string]::IsNullOrEmpty($effort)) { return }
    $label = $effort
    if ($effort -eq 'medium') { $label = 'med' }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_EFFORT "${fg} $($G.Psi) $label "
}

function Add-CtxSegment {
    $pct = 0
    if (-not (Get-PctValue $ctxPct ([ref]$pct))) { return }
    $bar = New-Bar $pct ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $pct)
    $dfg = Get-Fg $Cfg.VL_FG_DIM
    $ti = Format-Tok $tokIn
    $to = Format-Tok $tokOut
    $tcr = Format-Tok $tokCr
    $tcw = Format-Tok $tokCw
    Push-Segment $Cfg.VL_BG_CTX "${pfg} $($Cfg.VL_CTX_GLYPH) ${bar} ${pct}% ${dfg}$($G.Up)${ti} $($G.Down)${to} cr:${tcr} cw:${tcw} "
}

function Add-LimitSegment([string]$Label, [string]$RawPct, [string]$ResetsAt, [string]$Bg, [int]$PctMilli = -1) {
    $pct = 0
    if ($PctMilli -ge 0) { $pct = [int](Get-RoundEvenInt64 ([long]$PctMilli) 1000L) }
    elseif (-not (Get-PctValue $RawPct ([ref]$pct))) { return }
    $bar = New-Bar $pct ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $pct)
    $countdown = Format-Countdown $ResetsAt
    $reset = ''
    if (-not [string]::IsNullOrEmpty($countdown)) {
        $dfg = Get-Fg $Cfg.VL_FG_DIM
        $reset = "${dfg}$($G.Reset)${countdown}"
    }
    Push-Segment $Bg "${pfg} $Label ${bar} ${pct}% ${reset} "
}

function Add-Limit5Segment {
    if ($Cfg.VL_LIMIT_SYNC -eq '1') {
        if ($null -eq $State -or -not $State.Limit5.Valid) { return }
        Add-LimitSegment '5h' (Format-StatePct $State.Limit5.Pct) ([string]$State.Limit5.Reset) $Cfg.VL_BG_5H $State.Limit5.Pct
        return
    }
    Add-LimitSegment '5h' $fhPct $fhRst $Cfg.VL_BG_5H
}

function Add-Limit7Segment {
    if ($Cfg.VL_LIMIT_SYNC -eq '1') {
        if ($null -eq $State -or -not $State.Limit7.Valid) { return }
        Add-LimitSegment '7d' (Format-StatePct $State.Limit7.Pct) ([string]$State.Limit7.Reset) $Cfg.VL_BG_7D $State.Limit7.Pct
        return
    }
    Add-LimitSegment '7d' $wdPct $wdRst $Cfg.VL_BG_7D
}

function Format-Eta([long]$Seconds) {
    $remainder = 0L
    $days = [Math]::DivRem($Seconds, 86400L, [ref]$remainder)
    $minutesRemainder = 0L
    $hours = [Math]::DivRem($remainder, 3600L, [ref]$minutesRemainder)
    $unused = 0L
    $minutes = [Math]::DivRem($minutesRemainder, 60L, [ref]$unused)
    if ($days -gt 0) { return [string]::Format($Invariant, '{0}d{1:00}h', $days, $hours) }
    if ($hours -gt 0) { return [string]::Format($Invariant, '{0}h{1:00}m', $hours, $minutes) }
    return [string]::Format($Invariant, '{0}m', $minutes)
}

function Add-BurnSegment {
    if ($null -eq $State -or -not $State.Burn.Reported) { return }
    $bg = $Cfg.VL_BG_BURN
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_5H }
    if ($State.Burn.State -ne 'active') {
        $fg = Get-Fg $Cfg.VL_FG_DIM
        if ($State.Burn.State -eq 'warming') { Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Ellipsis) " }
        else { Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Check) " }
        return
    }
    $window = 604800L
    if ($State.Burn.Label -eq '5h') { $window = 18000L }
    $eta = [long]$State.Burn.Eta
    $ttr = [long]$State.Burn.Ttr
    if ($eta -gt $window) {
        $fg = Get-Fg $Cfg.VL_FG_OK
        Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($G.Check) "
        return
    }
    if ($eta -le $ttr) { $color = $Cfg.VL_FG_HOT }
    elseif ((10L * $ttr) -ge (8L * $eta)) { $color = $Cfg.VL_FG_WARN }
    else { $color = $Cfg.VL_FG_OK }
    $fg = Get-Fg $color
    Push-Segment $bg "${fg} $($Cfg.VL_BURN_GLYPH) $($State.Burn.Label) $($G.BurnTo) $(Format-Eta $eta) "
}

function Add-CostSegment {
    $value = 0.0
    if (-not (Try-BoundedDouble $cost 0 1000000000 ([ref]$value)) -or $value -eq 0) { return }
    $format = '$' + $value.ToString('F' + $Cfg.VL_COST_DECIMALS, $Invariant)
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_COST "${fg} $format "
}

function Add-ClockSegment {
    if ($Cfg.VL_CLOCK -eq 'off') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_CLOCK "${fg} $($G.Dot) $(Get-ClockText) "
}

function Get-NonNegativeLong([string]$Raw) {
    $value = 0L
    if (-not [long]::TryParse($Raw, $IntegerStyle, $Invariant, [ref]$value) -or $value -lt 0 -or $value -gt 1000000000000000) { return 0L }
    return $value
}

function Add-LinesSegment {
    $add = Get-NonNegativeLong $linesAdd
    $del = Get-NonNegativeLong $linesDel
    if ($add -le 0 -and $del -le 0) { return }
    $ok = Get-Fg $Cfg.VL_FG_OK
    $hot = Get-Fg $Cfg.VL_FG_HOT
    Push-Segment $Cfg.VL_BG_LINES " ${ok}+${add} ${hot}-${del} "
}

function Add-StyleSegment {
    if ([string]::IsNullOrEmpty($outStyle) -or $outStyle -eq 'default') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_STYLE "${fg} $($G.Pencil) $outStyle "
}

function Add-DurationSegment {
    $value = 0.0
    if (-not (Try-BoundedDouble $durMs 0 1000000000000000 ([ref]$value)) -or $value -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DURATION "${fg} $($G.Hourglass) $(Format-Duration $value $false) "
}

function Add-NodeSegment {
    $version = Get-NodeVersion $ProbeCwd
    if ([string]::IsNullOrEmpty($version)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_NODE
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($Cfg.VL_NODE_GLYPH) $version "
}

function Add-PythonSegment {
    if ([string]::IsNullOrEmpty($ProbeCwd)) { return }
    $version = Get-PythonVersion $ProbeCwd
    if ([string]::IsNullOrEmpty($version)) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = $Cfg.VL_BG_PYTHON
    if ([string]::IsNullOrEmpty($bg)) { $bg = $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($Cfg.VL_PY_GLYPH) $version "
}

$SegmentBuilders = [ordered]@{
    burn = { Add-BurnSegment }
    clock = { Add-ClockSegment }
    cost = { Add-CostSegment }
    ctx = { Add-CtxSegment }
    dir = { Add-DirSegment }
    duration = { Add-DurationSegment }
    effort = { Add-EffortSegment }
    git = { Add-GitSegment }
    limit5h = { Add-Limit5Segment }
    limit7d = { Add-Limit7Segment }
    lines = { Add-LinesSegment }
    model = { Add-ModelSegment }
    node = { Add-NodeSegment }
    project = { Add-ProjectSegment }
    python = { Add-PythonSegment }
    stash = { Add-StashSegment }
    style = { Add-StyleSegment }
}

function Build-Segments([string]$List) {
    $SegBgs.Clear()
    $SegTxt.Clear()
    $SegLen.Clear()
    foreach ($name in (Get-SegmentTokens $List)) {
        if ($SegmentBuilders.Contains($name)) { & $SegmentBuilders[$name] }
    }
}

function Render-Range([int]$Start, [int]$End) {
    if ($SegBgs.Count -eq 0 -or $Start -lt 0 -or $End -lt $Start -or $End -ge $SegBgs.Count) { return '' }
    if ($Cfg.VL_STYLE -eq 'lean') {
        $lbg = ''
        if (-not [string]::IsNullOrEmpty($Cfg.VL_LEAN_BG)) { $lbg = Get-Bg $Cfg.VL_LEAN_BG }
        $out = ''
        if (-not [string]::IsNullOrEmpty($lbg) -and -not [string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_L)) {
            $out = $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_L
        }
        for ($i = $Start; $i -le $End; $i++) {
            $out += $Rst + $lbg + (Get-Fg $SegBgs[$i]) + $SegTxt[$i]
            if ($i -lt $End) { $out += $Rst + $lbg + $Cfg.VL_LEAN_SEP }
        }
        if (-not [string]::IsNullOrEmpty($lbg) -and -not [string]::IsNullOrEmpty($Cfg.VL_LEAN_CAP_R)) {
            $out += $Rst + (Get-Fg $Cfg.VL_LEAN_BG) + $Cfg.VL_LEAN_CAP_R
        }
        return $out + $Rst
    }
    $out = $Rst + (Get-Fg $SegBgs[$Start]) + $Cfg.VL_CAP_L
    for ($i = $Start; $i -le $End; $i++) {
        $out += (Get-Bg $SegBgs[$i]) + $SegTxt[$i]
        if ($i -lt $End) {
            $out += (Get-Bg $SegBgs[$i + 1]) + (Get-Fg $SegBgs[$i]) + $Cfg.VL_SEP
        }
    }
    $out += $Rst + (Get-Fg $SegBgs[$End]) + $Cfg.VL_CAP_R + $Rst
    return $out
}

function Get-ScalarCount([string]$Value) {
    if ([string]::IsNullOrEmpty($Value)) { return 0 }
    $count = 0
    $i = 0
    while ($i -lt $Value.Length) {
        if ([char]::IsHighSurrogate($Value[$i]) -and $i + 1 -lt $Value.Length -and [char]::IsLowSurrogate($Value[$i + 1])) { $i++ }
        $count++
        $i++
    }
    return $count
}

function Test-FloatCollision([string]$Target) {
    $runtime = ''
    try { $runtime = [IO.Path]::GetFullPath($ScriptPath) } catch { }
    $collisionPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($ConfigPath, $runtime)) { if (-not [string]::IsNullOrEmpty($path)) { [void]$collisionPaths.Add($path) } }
    foreach ($path in $ConfigVisitedPaths) { if (-not [string]::IsNullOrEmpty([string]$path)) { [void]$collisionPaths.Add([string]$path) } }
    foreach ($statePath in $AllStatePaths) {
        if ($null -eq $statePath) { continue }
        foreach ($path in @($statePath.Base, $statePath.Root)) { if (-not [string]::IsNullOrEmpty($path)) { [void]$collisionPaths.Add($path) } }
    }
    foreach ($path in $collisionPaths) {
        if ($Target.Equals([string]$path, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-FloatTarget {
    if (-not $FloatEnabled) { return $null }
    if ($FloatFileRootAuthorized -and [string]::IsNullOrEmpty([string]$Cfg.VL_FLOAT_FILE)) { return $null }
    if (([string]$Cfg.VL_FLOAT_FILE).Length -gt 4096) { return $null }
    $target = ConvertTo-LocalFullPath ([string]$Cfg.VL_FLOAT_FILE) ([Environment]::CurrentDirectory)
    if ([string]::IsNullOrEmpty($target) -or (Test-FloatCollision $target)) { return $null }
    return $target
}

function Write-FloatAtomic([string]$Target, [byte[]]$Bytes) {
    $parent = $null
    try { $parent = [IO.Path]::GetDirectoryName($Target) } catch { return $false }
    if ([string]::IsNullOrEmpty($parent) -or -not (Test-NoReparseComponents $parent)) { return $false }
    try {
        # WIN03_TEST_BEFORE_PARENT_CREATE
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    } catch { return $false }
    # WIN03_TEST_AFTER_PARENT_CREATE
    if (-not (Test-NoReparseComponents $parent) -or -not [IO.Directory]::Exists($parent)) { return $false }
    if ((Test-StateObjectExists $Target) -and -not (Test-SafeRegularFile $Target)) { return $false }

    $temp = ''
    $backup = ''
    try {
        for ($attempt = 0; $attempt -lt 8; $attempt++) {
            $candidate = [IO.Path]::Combine($parent, '.float.tmp.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
            if ($candidate.Length -gt 4096) { return $false }
            $stream = $null
            try {
                $stream = New-Object IO.FileStream($candidate, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
                if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
                $stream.Flush($true)
                $stream.Dispose()
                $stream = $null
                # WIN03_TEST_AFTER_TEMP_CLOSE
                $temp = $candidate
                break
            } catch [IO.IOException] {
                if ($null -ne $stream) { $stream.Dispose() }
            } catch {
                if ($null -ne $stream) { $stream.Dispose() }
                return $false
            }
        }
        if ([string]::IsNullOrEmpty($temp)) { return $false }
        if (-not (Test-NoReparseComponents $parent)) { return $false }
        if (Test-StateObjectExists $Target) {
            if (-not (Test-SafeRegularFile $Target)) { return $false }
            for ($attempt = 0; $attempt -lt 8; $attempt++) {
                $backup = [IO.Path]::Combine($parent, '.float.bak.' + [string]$PID + '.' + [guid]::NewGuid().ToString('N'))
                if ($backup.Length -gt 4096) { $backup = ''; return $false }
                if (-not (Test-StateObjectExists $backup)) { break }
                $backup = ''
            }
            if ([string]::IsNullOrEmpty($backup)) { return $false }
            [IO.File]::Replace($temp, $Target, $backup)
            if (Test-SafeRegularFile $backup) { [IO.File]::Delete($backup); $backup = '' }
            elseif (-not (Test-StateObjectExists $backup)) { $backup = '' }
        } else {
            [IO.File]::Move($temp, $Target)
        }
        $temp = ''
        return $true
    } catch { return $false }
    finally {
        foreach ($path in @($temp, $backup)) {
            if (-not [string]::IsNullOrEmpty($path)) {
                try {
                    if (Test-SafeRegularFile $path) { [IO.File]::Delete($path) }
                } catch { }
            }
        }
    }
}

function Test-FloatText([string]$Value) {
    if ($null -eq $Value) { return $false }
    foreach ($ch in $Value.ToCharArray()) {
        $code = [int][char]$ch
        if ($code -lt 0x20 -or $code -eq 0x7F -or $code -ge 0x80 -and $code -le 0x9F -or $code -eq 0x1B) { return $true }
    }
    return $false
}

function Invoke-Float {
    if (-not $FloatEnabled) { return }
    $target = Get-FloatTarget
    if ([string]::IsNullOrEmpty($target)) { return }
    $oldNoColor = $NoColor
    $oldBold = $Bold
    $oldNorm = $Norm
    $oldRst = $Rst
    $oldLayout = $Cfg.VL_LAYOUT
    try {
        $NoColor = $true
        $Bold = ''
        $Norm = ''
        $Rst = ''
        $Cfg.VL_LAYOUT = 'fixed'
        Build-Segments ([string]$Cfg.VL_FLOAT_SEGMENTS)
        $parts = New-Object 'System.Collections.Generic.List[string]'
        for ($i = 0; $i -lt $SegTxt.Count; $i++) {
            $plain = (Remove-Sgr ([string]$SegTxt[$i])).Trim()
            if ([string]::IsNullOrEmpty($plain)) { continue }
            if (Test-FloatText $plain) { return }
            [void]$parts.Add($plain)
        }
        $line = [string]::Join([string]$Cfg.VL_FLOAT_SEP, $parts.ToArray())
        if (Test-FloatText $line) { return }
        $payload = $line + "`n"
        $bytes = $StrictUtf8.GetBytes($payload)
        if ($bytes.Length -gt 65536) { return }
        [void](Write-FloatAtomic $target $bytes)
    } catch { }
    finally {
        $NoColor = $oldNoColor
        $Bold = $oldBold
        $Norm = $oldNorm
        $Rst = $oldRst
        $Cfg.VL_LAYOUT = $oldLayout
    }
}

function Get-TerminalColumns {
    $raw = [string]$env:COLUMNS
    if (-not [string]::IsNullOrEmpty($raw)) {
        if ($raw -notmatch '^([0-9]+)$') { return 0 }
        $value = 0
        if (-not [int]::TryParse($raw, $IntegerStyle, $Invariant, [ref]$value) -or $value -lt 1 -or $value -gt 32767) { return 0 }
        return $value
    }
    if ($Host.Name -ne 'ConsoleHost') { return 0 }
    try {
        $value = [int]$Host.UI.RawUI.WindowSize.Width
        if ($value -ge 1 -and $value -le 32767) { return $value }
    } catch { }
    return 0
}

try {
    Invoke-Float
    if ($Cfg.VL_LAYOUT -eq 'auto') {
        Build-Segments ([string]$Cfg.VL_SEGMENTS)
        $total = $SegBgs.Count
        if ($total -gt 0) {
            $width = Get-TerminalColumns
            $maxLines = [int]$Cfg.VL_MAX_LINES
            if ($width -le 0 -or $maxLines -le 1) {
                $OutputWriter.WriteLine((Render-Range 0 ($total - 1)))
            } else {
                $width -= [int]$Cfg.VL_WRAP_MARGIN
                if ($width -lt 1) { $width = 1 }
                if ($Cfg.VL_STYLE -eq 'lean') {
                    $capWidth = (Get-ScalarCount $Cfg.VL_LEAN_CAP_L) + (Get-ScalarCount $Cfg.VL_LEAN_CAP_R)
                    $sepWidth = Get-ScalarCount $Cfg.VL_LEAN_SEP
                } else {
                    $capWidth = 2
                    $sepWidth = 1
                }
                $start = 0
                $line = 1
                $current = $capWidth + [int]$SegLen[0]
                for ($i = 1; $i -lt $total; $i++) {
                    $need = $current + $sepWidth + [int]$SegLen[$i]
                    if ($need -gt $width -and $line -lt $maxLines) {
                        $OutputWriter.WriteLine((Render-Range $start ($i - 1)))
                        $start = $i
                        $line++
                        $current = $capWidth + [int]$SegLen[$i]
                    } else { $current = $need }
                }
                $OutputWriter.WriteLine((Render-Range $start ($total - 1)))
            }
        }
    } else {
        foreach ($list in $MainSegmentLists) {
            if ([string]::IsNullOrWhiteSpace($list)) { continue }
            Build-Segments $list
            if ($SegBgs.Count -gt 0) { $OutputWriter.WriteLine((Render-Range 0 ($SegBgs.Count - 1))) }
        }
    }
} finally {
    $OutputWriter.Flush()
    $OutputWriter.Dispose()
}

exit 0
