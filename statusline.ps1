#Requires -Version 5.1
<#
  coralline - native Windows PowerShell statusline for Claude Code.

  This slice implements the fixed pill main bar without Bash, jq, WSL, or
  PowerShell 7. Config is read from the same coralline.conf through a narrow,
  non-executing Bash-word parser. Burn state, alternate styles/layouts, float
  output, and subagent rows are implemented by later slices.
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

function ConvertTo-LocalFullPath([string]$Path, [string]$BaseDir) {
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($Path -match '[\u0000-\u001f\u007f-\u009f]') { return $null }
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('//', [System.StringComparison]::Ordinal)) { return $null }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [System.StringComparison]::Ordinal) -or $Path -match '^\\\x3f\x3f\\') { return $null }

    $p = $Path
    if ($p -match '^/([A-Za-z])(?:/|$)') {
        $drive = $Matches[1].ToUpperInvariant()
        $p = $drive + ':\' + $p.Substring(2).TrimStart('/')
    }
    $p = $p.Replace('/', '\')

    $colon = $p.IndexOf(':')
    if ($colon -ge 0) {
        if ($colon -ne 1 -or $p.Length -lt 3 -or -not [char]::IsLetter($p[0]) -or $p[2] -ne '\' -or $p.IndexOf(':', 2) -ge 0) { return $null }
    } elseif ($p.StartsWith('\', [System.StringComparison]::Ordinal)) { return $null }

    try {
        if (-not [System.IO.Path]::IsPathRooted($p)) { $p = [System.IO.Path]::Combine($BaseDir, $p) }
        $full = [System.IO.Path]::GetFullPath($p)
    } catch { return $null }
    if ($full.StartsWith('\\', [System.StringComparison]::Ordinal)) { return $null }
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
    $relative = $Path.Substring($root.Length)
    $current = $root
    foreach ($part in $relative.Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [System.IO.Path]::Combine($current, $part)
        try { $attrs = [System.IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] { return $true }
        catch [System.IO.DirectoryNotFoundException] { return $true }
        catch { return $false }
        if (($attrs -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
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
            $pathContext = $PathConfigKeys.Contains($name)
            $decoded = Decode-ShellWord $raw $pathContext
            if (-not $decoded.Success) { $valid = $false; break }
            if ($pathContext -and $decoded.Value -match '[ -\u007f-\u009f]') { $valid = $false; break }
            $candidate[$name] = $decoded.Value
            continue
        }

        $valid = $false
        break
    }

    if ($stack.Count -ne 0) { $valid = $false }
    if (-not $valid) { return $failed }
    return [pscustomobject]@{ Success = $true; Config = $candidate }
}

$Cfg = Copy-Config $Defaults
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
    if ($parsed.Success) { $Cfg = $parsed.Config }
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
if ([int]$Cfg.VL_HOT_PCT -lt [int]$Cfg.VL_WARN_PCT) {
    $Cfg.VL_WARN_PCT = $Defaults.VL_WARN_PCT
    $Cfg.VL_HOT_PCT = $Defaults.VL_HOT_PCT
}
foreach ($key in @($Cfg.Keys | Where-Object { $_ -like 'VL_BG_*' -or $_ -like 'VL_FG_*' })) {
    if (-not (Test-Color $Cfg[$key])) { $Cfg[$key] = $Defaults[$key] }
}

# Later slices add the other styles/layout. Existing configs degrade predictably.
if ($Cfg.VL_STYLE -ne 'pill') { $Cfg.VL_STYLE = 'pill' }
if ($Cfg.VL_LAYOUT -ne 'fixed') { $Cfg.VL_LAYOUT = 'fixed' }

if ($Cfg.VL_ASCII -eq '1') {
    $Cfg.VL_CAP_L = ''
    $Cfg.VL_CAP_R = ''
    $Cfg.VL_SEP = ''
    $Cfg.VL_BAR_FILL = '#'
    $Cfg.VL_BAR_EMPTY = '-'
    $Cfg.VL_NODE_GLYPH = 'node'
    $Cfg.VL_PY_GLYPH = 'py'
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

function Get-NodeVersion([string]$Dir) {
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

function Get-PythonVersion([string]$Dir) {
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

function Get-SegmentTokens([string]$List) {
    if ([string]::IsNullOrWhiteSpace($List)) { return @() }
    return @([regex]::Split($List.Trim(), '\s+') | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

$AllSegmentNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($list in @($Cfg.VL_SEGMENTS, $Cfg.VL_SEGMENTS2, $Cfg.VL_SEGMENTS3)) {
    foreach ($name in (Get-SegmentTokens $list)) { [void]$AllSegmentNames.Add($name) }
}

$GitState = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
$GitRoot = ''
if ($AllSegmentNames.Contains('git') -or $AllSegmentNames.Contains('stash') -or $AllSegmentNames.Contains('project')) {
    $GitState = Get-GitState $ProbeCwd
}
if ($AllSegmentNames.Contains('project') -and -not [string]::IsNullOrEmpty($GitState.Branch)) { $GitRoot = Get-GitRoot $ProbeCwd }

$SegBgs = New-Object System.Collections.Generic.List[string]
$SegTxt = New-Object System.Collections.Generic.List[string]
function Push-Segment([string]$Bg, [string]$Text) {
    [void]$SegBgs.Add($Bg)
    [void]$SegTxt.Add($Text)
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
        if (-not $AllSegmentNames.Contains('dir')) { Add-DirSegment }
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
    $count = Get-StashCount $ProbeCwd
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

function Add-LimitSegment([string]$Label, [string]$RawPct, [string]$ResetsAt, [string]$Bg) {
    $pct = 0
    if (-not (Get-PctValue $RawPct ([ref]$pct))) { return }
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
    clock = { Add-ClockSegment }
    cost = { Add-CostSegment }
    ctx = { Add-CtxSegment }
    dir = { Add-DirSegment }
    duration = { Add-DurationSegment }
    effort = { Add-EffortSegment }
    git = { Add-GitSegment }
    limit5h = { Add-LimitSegment '5h' $fhPct $fhRst $Cfg.VL_BG_5H }
    limit7d = { Add-LimitSegment '7d' $wdPct $wdRst $Cfg.VL_BG_7D }
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
    foreach ($name in (Get-SegmentTokens $List)) {
        if ($SegmentBuilders.Contains($name)) { & $SegmentBuilders[$name] }
    }
}

function Render-Row {
    if ($SegBgs.Count -eq 0) { return '' }
    $out = $Rst + (Get-Fg $SegBgs[0]) + $Cfg.VL_CAP_L
    for ($i = 0; $i -lt $SegBgs.Count; $i++) {
        $out += (Get-Bg $SegBgs[$i]) + $SegTxt[$i]
        if ($i -lt ($SegBgs.Count - 1)) {
            $out += (Get-Bg $SegBgs[$i + 1]) + (Get-Fg $SegBgs[$i]) + $Cfg.VL_SEP
        }
    }
    $out += $Rst + (Get-Fg $SegBgs[$SegBgs.Count - 1]) + $Cfg.VL_CAP_R + $Rst
    return $out
}

try {
    foreach ($list in @($Cfg.VL_SEGMENTS, $Cfg.VL_SEGMENTS2, $Cfg.VL_SEGMENTS3)) {
        if ([string]::IsNullOrWhiteSpace($list)) { continue }
        Build-Segments $list
        if ($SegBgs.Count -gt 0) { $OutputWriter.WriteLine((Render-Row)) }
    }
} finally {
    $OutputWriter.Flush()
    $OutputWriter.Dispose()
}

exit 0
