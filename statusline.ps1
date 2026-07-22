#Requires -Version 5.1
<#
  coralline ??native PowerShell port of statusline.sh for Claude Code on
  Windows without Git Bash (see issue #8).

  Design goals for this port:
    * No jq, no bash, no WSL. Only `git.exe` on PATH is used, and only when a
      git-dependent segment (git/stash/project) is actually enabled.
    * Reads the SAME ~/.claude/coralline.conf (and its `. theme.conf` include)
      that statusline.sh reads. The config file is plain `KEY=value` /
      `KEY="value"` assignments with a single `. "path"` include line, so this
      script parses that shape directly with a small regex-based reader
      instead of requiring a new config format or an installer change (see
      Import-CorallineConfLines below). Existing coralline.conf files and
      every shipped theme work unmodified with this script.
    * Targets Windows PowerShell 5.1 (the interpreter that ships on every
      Windows 10/11 box; no PowerShell 7 dependency), since that is what a
      "no Git Bash" user already has available.

  Scope (first native slice ??see handoff/coralline-8-scope.md for the parity
  matrix): the "pill" style (VL_STYLE default) in "fixed" layout (VL_LAYOUT
  default) with every main-bar JSON-driven segment statusline.sh ships except
  `burn` (cross-session sampling with an awk slope fit) and the `--subagent`
  panel-row protocol. `lean`/`classic` styles and the `auto` responsive-wrap
  layout are not yet ported; VL_STYLE/VL_LAYOUT values other than the defaults
  fall back to pill/fixed so an imported bash config still renders instead of
  erroring.

  Usage (settings.json), matching the shape proposed in issue #8:
    "statusLine": {
      "type": "command",
      "command": "powershell -NoProfile -File C:/Users/you/.claude/coralline/statusline.ps1"
    }
#>

param(
    # statusline.sh's --subagent panel-row protocol is not ported yet. Accept
    # the flag and exit clean (no output) so Claude Code keeps its own default
    # panel rows instead of erroring on an unregistered command.
    [switch]$Subagent
)

if ($Subagent) { exit 0 }

# Left at the default ('Continue'): a native helper (git) writing to stderr
# must not become a terminating error here even when its stream is
# redirected away below, and every render must still print something rather
# than aborting on one bad segment.
$ErrorActionPreference = 'Continue'

# Windows PowerShell 5.1 defaults stdout to the console/OEM codepage, which
# mangles every non-ASCII glyph below (the p10k caps, the segment icons) once
# Claude Code captures this process's raw stdout bytes. Force UTF-8 (no BOM)
# on both the read and write sides so the bytes Claude Code reads back match
# what statusline.sh's Nerd-Font/Unicode segments look like on bash.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch { }
try { [Console]::InputEncoding = $Utf8NoBom } catch { }
$OutputEncoding = $Utf8NoBom

# ---- stdin --------------------------------------------------------------
$rawInput = [Console]::In.ReadToEnd()

$Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# ---- glyphs (codepoint literals, not source-embedded UTF-8, so this file
# renders correctly under Windows PowerShell 5.1's default ANSI-codepage
# script parsing regardless of the file's on-disk BOM) ---------------------
function Glyph([int]$Codepoint) { [System.Char]::ConvertFromUtf32($Codepoint) }

$G = @{
    CapL      = Glyph 0xE0B6
    CapR      = Glyph 0xE0B4
    Sep       = Glyph 0xE0B0
    Node      = Glyph 0xE718
    Python    = Glyph 0xE73C
    Project   = Glyph 0x2B22
    Branch    = Glyph 0x2387
    Diamond   = Glyph 0x25C6
    Hex       = Glyph 0x2B21
    Flag      = Glyph 0x2691
    Dot       = Glyph 0x2299
    Pencil    = Glyph 0x270E
    Hourglass = Glyph 0x29D6
    Psi       = Glyph 0x03C8
    Ahead     = Glyph 0x21E1
    Behind    = Glyph 0x21E3
    Ellipsis  = Glyph 0x2026
    BarFill   = Glyph 0x25B0
    BarEmpty  = Glyph 0x25B1
    Up        = Glyph 0x2191
    Down      = Glyph 0x2193
    Reset     = Glyph 0x21BA
}

$Esc  = [char]27
$Rst  = "$Esc[0m"
$Bold = "$Esc[1m"
$Norm = "$Esc[22m"

# ---- config: defaults (mirrors statusline.sh's hardcoded defaults for the
# segments this port renders) ----------------------------------------------
$Cfg = [ordered]@{
    VL_STYLE          = 'pill'
    VL_LAYOUT         = 'fixed'
    VL_SEGMENTS       = 'dir git model ctx limit5h limit7d cost clock'
    VL_SEGMENTS2      = ''
    VL_SEGMENTS3      = ''
    VL_BAR_WIDTH      = '5'
    VL_CLOCK          = '12h'
    VL_CLOCK_SECONDS  = '1'
    VL_PATH_DEPTH     = '4'
    VL_NAME_MAX       = '0'
    VL_COST_DECIMALS  = '2'
    VL_WARN_PCT       = '50'
    VL_HOT_PCT        = '75'
    VL_ASCII          = '0'
    VL_RUNTIME_PROBE  = '0'
    VL_NOCOLOR        = '0'

    VL_BG_DIR      = '81,166,199'
    VL_BG_PROJECT  = ''
    VL_BG_GIT_OK   = '65'
    VL_BG_STASH    = ''
    VL_BG_GIT_DIRTY = '130'
    VL_BG_MODEL    = '173'
    VL_BG_CTX      = '238'
    VL_BG_5H       = '237'
    VL_BG_7D       = '236'
    VL_BG_COST     = '212,125,145'
    VL_BG_CLOCK    = '70,80,110'
    VL_BG_LINES    = '240'
    VL_BG_STYLE    = '96'
    VL_BG_DURATION = '60'
    VL_BG_EFFORT   = '141'
    VL_BG_NODE     = ''
    VL_BG_PYTHON   = ''

    VL_FG_TEXT = '231'
    VL_FG_DIM  = '245'
    VL_FG_OK   = '114'
    VL_FG_WARN = '179'
    VL_FG_HOT  = '167'
}

# ---- config: parser -------------------------------------------------------
# Reads the same bash-syntax coralline.conf / theme.conf files statusline.sh
# sources. Handles the two shapes those files actually contain: the leading
# `. "path"` theme include, and `KEY=value` / `KEY="value"` assignments with
# an optional trailing `# comment`. Anything else (bash logic, conditionals)
# is silently ignored, which is fine here since every shipped config and
# theme is exactly this shape (write_candidate_config in configure.sh never
# emits anything else). This means the SAME coralline.conf a bash install
# wrote works for this script unmodified ??no new config format needed.
function Strip-ConfValue([string]$Raw) {
    $v = $Raw.Trim()
    if ($v.Length -ge 1 -and $v[0] -eq '"') {
        $endIdx = $v.IndexOf('"', 1)
        if ($endIdx -ge 0) { return $v.Substring(1, $endIdx - 1) }
        return $v.Substring(1)
    }
    if ($v.Length -ge 1 -and $v[0] -eq "'") {
        $endIdx = $v.IndexOf("'", 1)
        if ($endIdx -ge 0) { return $v.Substring(1, $endIdx - 1) }
        return $v.Substring(1)
    }
    $hashIdx = $v.IndexOf('#')
    if ($hashIdx -ge 0) { $v = $v.Substring(0, $hashIdx) }
    return $v.Trim()
}

function Import-CorallineConfLines([string]$Path, [System.Collections.Specialized.OrderedDictionary]$Target, [int]$Depth = 0) {
    if ($Depth -gt 4) { return }              # guard against an include cycle
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^\.\s+"?([^"]+?)"?\s*$') {
            Import-CorallineConfLines -Path $matches[1] -Target $Target -Depth ($Depth + 1)
            continue
        }
        if ($t -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $Target[$matches[1]] = Strip-ConfValue $matches[2]
        }
    }
}

$ConfigPath = $env:CORALLINE_CONFIG
if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $HOME '.claude\coralline.conf' }
Import-CorallineConfLines -Path $ConfigPath -Target $Cfg

# Unsupported style/layout values fall back to this port's supported pair
# rather than erroring, so an existing bash config (lean/classic, auto) still
# renders ??just without that style/layout's extra behavior yet.
if ($Cfg.VL_STYLE -ne 'pill') { $Cfg.VL_STYLE = 'pill' }
if ($Cfg.VL_LAYOUT -ne 'fixed') { $Cfg.VL_LAYOUT = 'fixed' }

$AsciiMode = ($Cfg.VL_ASCII -eq '1')
if ($AsciiMode) {
    $G.CapL = ''; $G.CapR = ''; $G.Sep = ''
    $G.BarFill = '#'; $G.BarEmpty = '-'
    $G.Node = 'node'; $G.Python = 'py'
}

$NoColor = ($Cfg.VL_NOCOLOR -eq '1')

# ---- ANSI primitives --------------------------------------------------------
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

# ---- formatting helpers (mirrors statusline.sh's make_bar/fmt_tok/etc.) ----
function New-Bar([double]$Pct, [int]$Width) {
    if ($Pct -lt 0) { $Pct = 0 }
    $filled = [math]::Floor(($Pct * $Width + 50) / 100)
    if ($filled -lt 0) { $filled = 0 }
    if ($filled -gt $Width) { $filled = $Width }
    $empty = $Width - $filled
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $filled; $i++) { [void]$sb.Append($G.BarFill) }
    for ($i = 0; $i -lt $empty; $i++) { [void]$sb.Append($G.BarEmpty) }
    return $sb.ToString()
}

function Format-Tok([string]$Raw) {
    $n = 0L
    if (-not [long]::TryParse($Raw, [ref]$n)) { return $Raw }
    if ($n -ge 1000000) { return ('{0}.{1}M' -f [math]::Floor($n / 1000000), ([math]::Floor(($n % 1000000) / 100000))) }
    if ($n -ge 1000) { return ('{0}.{1}k' -f [math]::Floor($n / 1000), ([math]::Floor(($n % 1000) / 100))) }
    return "$n"
}

function Get-PctFg([double]$Pct) {
    if ($Pct -ge [double]$Cfg.VL_HOT_PCT) { return $Cfg.VL_FG_HOT }
    if ($Pct -ge [double]$Cfg.VL_WARN_PCT) { return $Cfg.VL_FG_WARN }
    return $Cfg.VL_FG_OK
}

function Get-Trunc([string]$S, [int]$Max) {
    if ($Max -le 0 -or $S.Length -le $Max) { return $S }
    if ($Max -lt 3) { return $S.Substring(0, $Max) }
    $head = [math]::Floor(($Max - 1) / 2)
    $tail = $Max - 1 - $head
    return $S.Substring(0, $head) + $G.Ellipsis + $S.Substring($S.Length - $tail)
}

# Accepts epoch seconds (int/float string) or an ISO 8601 timestamp -> epoch
# seconds, or $null when unparseable. .NET's DateTimeOffset parser replaces
# statusline.sh's hand-rolled iso_epoch/to_epoch civil-calendar math.
function ConvertTo-Epoch([string]$Raw) {
    if ([string]::IsNullOrEmpty($Raw)) { return $null }
    if ($Raw -match '^[0-9]+(\.[0-9]+)?$') { return [long][double]$Raw }
    try {
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $dto = [DateTimeOffset]::Parse($Raw, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return $dto.ToUnixTimeSeconds()
    } catch { return $null }
}

function Format-Countdown([string]$ResetsAt) {
    $ep = ConvertTo-Epoch $ResetsAt
    if ($null -eq $ep) { return '' }
    $diff = $ep - $Now
    if ($diff -le 0) { return 'now' }
    $d = [math]::Floor($diff / 86400)
    $h = [math]::Floor(($diff % 86400) / 3600)
    $m = [math]::Floor(($diff % 3600) / 60)
    if ($d -gt 0) { return ('{0}d{1:00}h' -f $d, $h) }
    if ($h -gt 0) { return ('{0}h{1:00}m' -f $h, $m) }
    return "${m}m"
}

function Format-Duration([double]$Ms, [bool]$IncludeSeconds) {
    $s = [math]::Floor($Ms / 1000)
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
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Cfg.VL_CLOCK -eq '24h') {
        if ($Cfg.VL_CLOCK_SECONDS -eq '1') { return $now.ToString('HH:mm:ss', $inv) }
        return $now.ToString('HH:mm', $inv)
    }
    $fmt = if ($Cfg.VL_CLOCK_SECONDS -eq '1') { 'hh:mm:ss tt' } else { 'hh:mm tt' }
    $t = $now.ToString($fmt, $inv)
    if ($t.EndsWith('AM')) { return ($t.Substring(0, $t.Length - 2) + 'am') }
    if ($t.EndsWith('PM')) { return ($t.Substring(0, $t.Length - 2) + 'pm') }
    return $t
}

# ---- git state (single `git status` call, parsed once; mirrors read_git) --
$env:GIT_OPTIONAL_LOCKS = '0'

function Get-GitState([string]$Cwd) {
    $state = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
    if ([string]::IsNullOrEmpty($Cwd)) { return $state }
    $lines = & git -C $Cwd status --porcelain=v2 --branch 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $lines) { return $state }
    $oid = ''; $head = ''; $a = 0; $b = 0
    $staged = $false; $unstaged = $false; $untracked = $false
    foreach ($line in $lines) {
        if ($line.StartsWith('# branch.oid ')) { $oid = $line.Substring(13) }
        elseif ($line.StartsWith('# branch.head ')) { $head = $line.Substring(14) }
        elseif ($line.StartsWith('# branch.ab ')) {
            if ($line -match '\+(\d+)\s+-(\d+)') { $a = [int]$matches[1]; $b = [int]$matches[2] }
        }
        elseif ($line.StartsWith('? ')) { $untracked = $true }
        elseif ($line -match '^[12] ') {
            $rest = $line.Substring(2)
            if ($rest.Length -ge 1 -and $rest[0] -ne '.') { $staged = $true }
            if ($rest.Length -ge 2 -and $rest[1] -ne '.') { $unstaged = $true }
        }
        elseif ($line.StartsWith('u ')) { $unstaged = $true }
    }
    if ([string]::IsNullOrEmpty($oid)) { return $state }
    if ($head -eq '(detached)' -or [string]::IsNullOrEmpty($head)) {
        $state.Branch = $oid.Substring(0, [Math]::Min(7, $oid.Length))
    } else {
        $state.Branch = $head
    }
    if ($staged) { $state.Marks += '+' }
    if ($unstaged) { $state.Marks += '!' }
    if ($untracked) { $state.Marks += '?' }
    if ($a -gt 0) { $state.Ab += "$($G.Ahead)$a" }
    if ($b -gt 0) { $state.Ab += "$($G.Behind)$b" }
    if ($state.Marks) { $state.Dirty = $true }
    return $state
}

function Get-GitRoot([string]$Cwd) {
    if ([string]::IsNullOrEmpty($Cwd)) { return '' }
    $root = & git -C $Cwd rev-parse --path-format=absolute --git-common-dir 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $root) {
        $root = & git -C $Cwd rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $root) { return '' }
    }
    $root = ($root -replace '\\', '/').TrimEnd('/')
    if ($root.EndsWith('/.git')) { $root = $root.Substring(0, $root.Length - 5) }
    $parts = $root.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
    if ($parts.Length -eq 0) { return '' }
    return $parts[$parts.Length - 1]
}

function Get-StashCount([string]$Cwd) {
    $n = & git -C $Cwd rev-list --walk-reflogs --count refs/stash 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $n) { return 0 }
    $count = 0
    if ([int]::TryParse(($n | Select-Object -First 1), [ref]$count)) { return $count }
    return 0
}

# ---- node/python runtime detection (pin-file walk; mirrors runtime_node /
# runtime_python) -------------------------------------------------------------
function Get-NodeVersion([string]$Dir) {
    $d = $Dir
    while ($d -and (Test-Path -LiteralPath $d -PathType Container)) {
        foreach ($f in '.nvmrc', '.node-version') {
            $p = Join-Path $d $f
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $v = (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction SilentlyContinue)
                if ($v) { $v = $v.Trim(); if ($v) { return $v.TrimStart('v') } }
            }
        }
        $parent = Split-Path -Path $d -Parent
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $v = (& node --version 2>$null | Select-Object -First 1)
        if ($v) { return $v.TrimStart('v') }
    }
    return ''
}

function Get-PythonVersion([string]$Dir) {
    if ($env:VIRTUAL_ENV) { return (Split-Path -Leaf $env:VIRTUAL_ENV) }
    if ($env:CONDA_DEFAULT_ENV -and $env:CONDA_DEFAULT_ENV -ne 'base') { return $env:CONDA_DEFAULT_ENV }
    $d = $Dir
    while ($d -and (Test-Path -LiteralPath $d -PathType Container)) {
        $p = Join-Path $d '.python-version'
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            $v = (Get-Content -LiteralPath $p -TotalCount 1 -ErrorAction SilentlyContinue)
            if ($v) { $v = $v.Trim(); if ($v) { return $v } }
        }
        $parent = Split-Path -Path $d -Parent
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    if ($Cfg.VL_RUNTIME_PROBE -eq '1') {
        $v = (& python3 --version 2>&1 | Select-Object -First 1)
        if ($v) { return ($v -replace '^Python ', '').Trim() }
    }
    return ''
}

# ---- JSON input -------------------------------------------------------------
try { $J = $rawInput | ConvertFrom-Json } catch { $J = $null }

function Str($Value) { if ($null -eq $Value) { '' } else { [string]$Value } }

$cwd = Str $J.workspace.current_dir
if (-not $cwd) { $cwd = Str $J.cwd }
$model     = Str $J.model.display_name
$ctxPct    = Str $J.context_window.used_percentage
$tokIn     = Str $J.context_window.total_input_tokens
$tokOut    = Str $J.context_window.total_output_tokens
$tokCr     = Str $J.context_window.current_usage.cache_read_input_tokens
$tokCw     = Str $J.context_window.current_usage.cache_creation_input_tokens
$fhPct     = Str $J.rate_limits.five_hour.used_percentage
$fhRst     = Str $J.rate_limits.five_hour.resets_at
$wdPct     = Str $J.rate_limits.seven_day.used_percentage
$wdRst     = Str $J.rate_limits.seven_day.resets_at
$cost      = Str $J.cost.total_cost_usd
$linesAdd  = Str $J.cost.total_lines_added
$linesDel  = Str $J.cost.total_lines_removed
$outStyle  = Str $J.output_style.name
$durMs     = Str $J.cost.total_duration_ms
$effort    = Str $J.effort.level

$segScan = " $($Cfg.VL_SEGMENTS) $($Cfg.VL_SEGMENTS2) $($Cfg.VL_SEGMENTS3) "
$GitState = @{ Branch = ''; Marks = ''; Ab = ''; Dirty = $false }
$GitRoot = ''
if ($segScan -match ' (git|stash|project) ') { $GitState = Get-GitState $cwd }
if ($segScan -match ' project ') { $GitRoot = Get-GitRoot $cwd }

# ---- segments (each Add-*Segment mirrors one seg_* function) --------------
$SegBgs = New-Object System.Collections.Generic.List[string]
$SegTxt = New-Object System.Collections.Generic.List[string]
function Push-Segment([string]$Bg, [string]$Text) {
    [void]$SegBgs.Add($Bg)
    [void]$SegTxt.Add($Text)
}

function Add-DirSegment {
    if (-not $cwd) { return }
    $short = $cwd -replace '\\', '/'
    if ($HOME) {
        $homeFwd = $HOME -replace '\\', '/'
        if ($short.StartsWith($homeFwd)) { $short = '~' + $short.Substring($homeFwd.Length) }
    }
    $parts = $short.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
    $depth = [int]$Cfg.VL_PATH_DEPTH
    if ($parts.Length -gt $depth -and $parts.Length -ge 1) {
        $last = $parts[$parts.Length - 1]
        $p1 = if ($parts.Length -ge 1) { $parts[0] } else { '' }
        $p2 = if ($parts.Length -ge 2) { $parts[1] } else { '' }
        $short = "$p1/$p2/$($G.Ellipsis)/$last"
    }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DIR "${Bold}${fg} $short ${Norm}"
}

function Add-ProjectSegment {
    if (-not $GitRoot) {
        if ($segScan -notmatch ' dir ') { Add-DirSegment }
        return
    }
    $tr = Get-Trunc $GitRoot ([int]$Cfg.VL_NAME_MAX)
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = if ($Cfg.VL_BG_PROJECT) { $Cfg.VL_BG_PROJECT } else { $Cfg.VL_BG_DIR }
    Push-Segment $bg "${Bold}${fg} $($G.Project) $tr ${Norm}"
}

function Add-GitSegment {
    if (-not $GitState.Branch) { return }
    $bgc = if ($GitState.Dirty) { $Cfg.VL_BG_GIT_DIRTY } else { $Cfg.VL_BG_GIT_OK }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $tr = Get-Trunc $GitState.Branch ([int]$Cfg.VL_NAME_MAX)
    Push-Segment $bgc "${Bold}${fg} $($G.Branch) ${tr}$($GitState.Marks)$($GitState.Ab) ${Norm}"
}

function Add-StashSegment {
    if (-not $GitState.Branch) { return }
    $n = Get-StashCount $cwd
    if ($n -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = if ($Cfg.VL_BG_STASH) { $Cfg.VL_BG_STASH } else { $Cfg.VL_BG_GIT_OK }
    Push-Segment $bg "${fg} $($G.Flag) $n "
}

function Add-ModelSegment {
    if (-not $model) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $shown = $model -replace '^Claude ', ''
    Push-Segment $Cfg.VL_BG_MODEL "${Bold}${fg} $($G.Diamond) $shown ${Norm}"
}

function Add-EffortSegment {
    if (-not $effort) { return }
    $label = $effort
    if ($effort -eq 'medium') { $label = 'med' }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_EFFORT "${fg} $($G.Psi) $label "
}

function Add-CtxSegment {
    if (-not $ctxPct) { return }
    $ci = [math]::Round([double]$ctxPct)
    $bar = New-Bar $ci ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $ci)
    $dfg = Get-Fg $Cfg.VL_FG_DIM
    $ti = Format-Tok $tokIn
    $to = Format-Tok $tokOut
    $tcr = Format-Tok $tokCr
    $tcw = Format-Tok $tokCw
    Push-Segment $Cfg.VL_BG_CTX "${pfg} $($G.Hex) ${bar} ${ci}% ${dfg}$($G.Up)${ti} $($G.Down)${to} cr:${tcr} cw:${tcw} "
}

function Add-LimitSegment([string]$Label, [string]$Pct, [string]$ResetsAt, [string]$Bg) {
    if (-not $Pct) { return }
    $v = [math]::Round([double]$Pct)
    $bar = New-Bar $v ([int]$Cfg.VL_BAR_WIDTH)
    $pfg = Get-Fg (Get-PctFg $v)
    $cd = Format-Countdown $ResetsAt
    $rst = ''
    if ($cd) { $dfg = Get-Fg $Cfg.VL_FG_DIM; $rst = "${dfg}$($G.Reset)${cd}" }
    Push-Segment $Bg "${pfg} $Label ${bar} ${v}% ${rst} "
}

function Add-Cost {
    if (-not $cost -or $cost -eq '0') { return }
    $decimals = [int]$Cfg.VL_COST_DECIMALS
    $fmt = ''
    try { $fmt = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "`$" + '{0:F' + $decimals + '}', [double]$cost) } catch { $fmt = "`$$cost" }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_COST "${fg} $fmt "
}

function Add-Clock {
    if ($Cfg.VL_CLOCK -eq 'off') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_CLOCK "${fg} $($G.Dot) $(Get-ClockText) "
}

function Add-Lines {
    $add = 0; $del = 0
    [int]::TryParse($linesAdd, [ref]$add) | Out-Null
    [int]::TryParse($linesDel, [ref]$del) | Out-Null
    if ($add -le 0 -and $del -le 0) { return }
    $fgo = Get-Fg $Cfg.VL_FG_OK
    $fgh = Get-Fg $Cfg.VL_FG_HOT
    Push-Segment $Cfg.VL_BG_LINES " ${fgo}+${add} ${fgh}-${del} "
}

function Add-Style {
    if (-not $outStyle -or $outStyle -eq 'default') { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_STYLE "${fg} $($G.Pencil) $outStyle "
}

function Add-Duration {
    $ms = 0.0
    if (-not [double]::TryParse($durMs, [ref]$ms) -or $ms -le 0) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    Push-Segment $Cfg.VL_BG_DURATION "${fg} $($G.Hourglass) $(Format-Duration $ms $true) "
}

function Add-Node {
    if (-not $cwd) { return }
    $v = Get-NodeVersion $cwd
    if (-not $v) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = if ($Cfg.VL_BG_NODE) { $Cfg.VL_BG_NODE } else { $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($G.Node) $v "
}

function Add-Python {
    if (-not $cwd) { return }
    $v = Get-PythonVersion $cwd
    if (-not $v) { return }
    $fg = Get-Fg $Cfg.VL_FG_TEXT
    $bg = if ($Cfg.VL_BG_PYTHON) { $Cfg.VL_BG_PYTHON } else { $Cfg.VL_BG_MODEL }
    Push-Segment $bg "${fg} $($G.Python) $v "
}

$SegmentBuilders = @{
    dir      = { Add-DirSegment }
    project  = { Add-ProjectSegment }
    git      = { Add-GitSegment }
    stash    = { Add-StashSegment }
    model    = { Add-ModelSegment }
    effort   = { Add-EffortSegment }
    ctx      = { Add-CtxSegment }
    limit5h  = { Add-LimitSegment '5h' $fhPct $fhRst $Cfg.VL_BG_5H }
    limit7d  = { Add-LimitSegment '7d' $wdPct $wdRst $Cfg.VL_BG_7D }
    cost     = { Add-Cost }
    clock    = { Add-Clock }
    lines    = { Add-Lines }
    style    = { Add-Style }
    duration = { Add-Duration }
    node     = { Add-Node }
    python   = { Add-Python }
    # burn (cross-session rate sampling) and the subagent panel row segments
    # are not ported in this slice; see handoff/coralline-8-scope.md.
}

function Build-Segments([string]$List) {
    $SegBgs.Clear(); $SegTxt.Clear()
    foreach ($name in ($List -split '\s+' | Where-Object { $_ })) {
        if ($SegmentBuilders.ContainsKey($name)) { & $SegmentBuilders[$name] }
    }
}

function Render-Row {
    if ($SegBgs.Count -eq 0) { return '' }
    $out = $Rst + (Get-Fg $SegBgs[0]) + $G.CapL
    for ($i = 0; $i -lt $SegBgs.Count; $i++) {
        $out += (Get-Bg $SegBgs[$i]) + $SegTxt[$i]
        if ($i -lt ($SegBgs.Count - 1)) {
            $out += (Get-Bg $SegBgs[$i + 1]) + (Get-Fg $SegBgs[$i]) + $G.Sep
        }
    }
    $out += $Rst + (Get-Fg $SegBgs[$SegBgs.Count - 1]) + $G.CapR + $Rst
    return $out
}

foreach ($list in @($Cfg.VL_SEGMENTS, $Cfg.VL_SEGMENTS2, $Cfg.VL_SEGMENTS3)) {
    if ([string]::IsNullOrWhiteSpace($list)) { continue }
    Build-Segments $list
    if ($SegBgs.Count -gt 0) { Write-Output (Render-Row) }
}
