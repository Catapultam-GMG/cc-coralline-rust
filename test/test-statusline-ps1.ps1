#Requires -Version 5.1
<#
  WIN-01 regression and differential tests for statusline.ps1.

  Run on native Windows PowerShell 5.1. Git Bash is test-only and supplies the
  statusline.sh oracle plus real configure.sh printf %q fixtures.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$Script = Join-Path $Repo 'statusline.ps1'
$BashScript = Join-Path $Repo 'statusline.sh'
$Configure = Join-Path $Repo 'configure.sh'
$PowerShellExe = (Get-Process -Id $PID).Path
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$StrictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
$Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$TempRoot = Join-Path $Repo ('.win01-test-' + [guid]::NewGuid().ToString('N'))
$script:Fail = 0
$script:Pass = 0
$script:Blocked = 0

function Glyph([int]$Codepoint) { return [System.Char]::ConvertFromUtf32($Codepoint) }

function Check([string]$Name, [bool]$Condition) {
    if ($Condition) { [Console]::Out.WriteLine("PASS  $Name"); $script:Pass++ }
    else { [Console]::Out.WriteLine("FAIL  $Name"); $script:Fail++ }
}

function Blocked([string]$Name, [string]$Reason) {
    [Console]::Out.WriteLine("BLOCKED  ${Name}: $Reason")
    $script:Blocked++
}

function Write-Utf8([string]$Path, [string]$Text) {
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Forward-Path([string]$Path) { return $Path.Replace('\', '/') }

function Invoke-CapturedProcess(
    [string]$FileName,
    [string]$Arguments,
    [string]$InputText,
    [hashtable]$Environment,
    [string]$WorkingDirectory,
    [int]$TimeoutMs
) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$psi.EnvironmentVariables.Remove($key) }
        else { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'process did not start' }
        $stdout = New-Object System.IO.MemoryStream
        $stderr = New-Object System.IO.MemoryStream
        $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $inputBytes = $Utf8NoBom.GetBytes($InputText)
        if ($inputBytes.Length -gt 0) { $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length) }
        $process.StandardInput.Close()
        $timedOut = -not $process.WaitForExit($TimeoutMs)
        if ($timedOut) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(2000)
        }
        [void]$outTask.Wait(2000)
        [void]$errTask.Wait(2000)
        $watch.Stop()
        $outBytes = $stdout.ToArray()
        $errBytes = $stderr.ToArray()
        try { $outText = $StrictUtf8.GetString($outBytes) } catch { $outText = $null }
        try { $errText = $StrictUtf8.GetString($errBytes) } catch { $errText = $null }
        $exitCode = -1
        if (-not $timedOut -and $process.HasExited) { $exitCode = $process.ExitCode }
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            ElapsedMs = $watch.ElapsedMilliseconds
            StdoutBytes = $outBytes
            StderrBytes = $errBytes
            Stdout = $outText
            Stderr = $errText
        }
    } catch {
        $watch.Stop()
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            ElapsedMs = $watch.ElapsedMilliseconds
            StdoutBytes = [byte[]]@()
            StderrBytes = $Utf8NoBom.GetBytes($_.Exception.Message)
            Stdout = ''
            Stderr = $_.Exception.Message
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Runtime-Environment([string]$ConfigPath, [hashtable]$Extra) {
    $environment = @{
        CORALLINE_CONFIG = $null
        CORALLINE_NO_SAMPLE = '1'
        REMORA_ACTIVE = $null
        VIRTUAL_ENV = $null
        CONDA_DEFAULT_ENV = $null
    }
    if (-not [string]::IsNullOrEmpty($ConfigPath)) { $environment.CORALLINE_CONFIG = Forward-Path $ConfigPath }
    foreach ($key in $Extra.Keys) { $environment[$key] = $Extra[$key] }
    return $environment
}

function Invoke-Statusline(
    [string]$Json,
    [string]$ConfigPath,
    [hashtable]$ExtraEnvironment,
    [string]$Arguments,
    [int]$TimeoutMs
) {
    $psArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $Script + '"'
    if (-not [string]::IsNullOrEmpty($Arguments)) { $psArgs += ' ' + $Arguments }
    return Invoke-CapturedProcess $PowerShellExe $psArgs $Json (Runtime-Environment $ConfigPath $ExtraEnvironment) $Repo $TimeoutMs
}

function Invoke-BashStatusline([string]$Json, [string]$ConfigPath, [hashtable]$ExtraEnvironment) {
    $environment = Runtime-Environment $ConfigPath $ExtraEnvironment
    $args = '--noprofile --norc "' + (Forward-Path $BashScript) + '"'
    return Invoke-CapturedProcess $script:BashExe $args $Json $environment $Repo 10000
}

function Check-Run([string]$Name, $Run) {
    Check "$Name no timeout" (-not $Run.TimedOut)
    Check "$Name exit 0" ($Run.ExitCode -eq 0)
    Check "$Name stderr empty" ($Run.StderrBytes.Length -eq 0)
    Check "$Name strict UTF-8 stdout" ($null -ne $Run.Stdout)
}

function Plain([string]$Text) {
    if ($null -eq $Text) { return '' }
    return [regex]::Replace($Text, ([string][char]27 + '\[[0-9;]*m'), '')
}

function Check-Exact([string]$Name, $Actual, $Expected) {
    $equal = $Actual.StdoutBytes.Length -eq $Expected.StdoutBytes.Length
    if ($equal) {
        for ($i=0; $i -lt $Actual.StdoutBytes.Length; $i++) {
            if ($Actual.StdoutBytes[$i] -ne $Expected.StdoutBytes[$i]) { $equal = $false; break }
        }
    }
    Check $Name $equal
    if (-not $equal) {
        [Console]::Out.WriteLine('DIAG  PowerShell=' + [Convert]::ToBase64String($Actual.StdoutBytes))
        [Console]::Out.WriteLine('DIAG  Bash=' + [Convert]::ToBase64String($Expected.StdoutBytes))
    }
}

function New-Config([string]$Name, [string[]]$Lines) {
    $path = Join-Path $TempRoot ('config\' + $Name + '.conf')
    Write-Utf8 $path (($Lines -join "`n") + "`n")
    return $path
}

function New-Payload([string]$Cwd) {
    $payload = [ordered]@{
        cwd = $Cwd
        workspace = [ordered]@{ current_dir = $Cwd }
        model = [ordered]@{ display_name = 'Claude MODEL_SENTINEL' }
        output_style = [ordered]@{ name = 'Explanatory' }
        effort = [ordered]@{ level = 'high' }
        context_window = [ordered]@{
            used_percentage = 62.4
            total_input_tokens = 1234567
            total_output_tokens = 45678
            current_usage = [ordered]@{
                cache_read_input_tokens = 98765
                cache_creation_input_tokens = 4321
            }
        }
        rate_limits = [ordered]@{
            five_hour = [ordered]@{ used_percentage = 41.2; resets_at = '' }
            seven_day = [ordered]@{ used_percentage = 78.9; resets_at = '' }
        }
        cost = [ordered]@{
            total_cost_usd = 1.2345
            total_lines_added = 321
            total_lines_removed = 87
            total_duration_ms = 5432100
        }
    }
    return $payload
}

function Json($Object) { return ($Object | ConvertTo-Json -Compress -Depth 12) }
function Clone-Object($Object) { return ((Json $Object) | ConvertFrom-Json) }

function Run-ModelColor([string]$Name, [string]$ConfigPath, [string]$ExpectedSpec, [hashtable]$Environment) {
    $payload = New-Payload ''
    $run = Invoke-Statusline (Json $payload) $ConfigPath $Environment '' 5000
    Check-Run $Name $run
    if ($ExpectedSpec.Contains(',')) {
        $parts = $ExpectedSpec.Split(',')
        $needle = "48;2;$($parts[0]);$($parts[1]);$($parts[2])m"
    } else { $needle = "48;5;${ExpectedSpec}m" }
    $hasColor = $run.Stdout.Contains($needle)
    Check "$Name expected model color" $hasColor
    if (-not $hasColor) {
        [Console]::Out.WriteLine('DIAG  ' + $Name + '=' + [Convert]::ToBase64String($run.StdoutBytes))
        [Console]::Out.WriteLine('DIAG  config=' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($ConfigPath)))
    }
    return $run
}

function Snapshot-File([string]$Path) {
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($Path))).Replace('-', '') }
    finally { $sha.Dispose() }
    $info = New-Object System.IO.FileInfo($Path)
    return "$($info.Length)|$($info.LastWriteTimeUtc.Ticks)|$hash"
}

function Snapshot-Ads([string]$Carrier, [string]$StreamName) {
    try {
        $item = Get-Item -LiteralPath $Carrier -Stream $StreamName -ErrorAction Stop
        $bytes = [byte[]]@(Get-Content -LiteralPath $Carrier -Stream $StreamName -Encoding Byte -ErrorAction Stop)
    } catch { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '') }
    finally { $sha.Dispose() }
    return "$($item.Length)|$hash"
}

function Run-Git([string]$WorkingDirectory, [string]$Arguments) {
    $run = Invoke-CapturedProcess $script:GitExe $Arguments '' @{} $WorkingDirectory 10000
    if ($run.TimedOut -or $run.ExitCode -ne 0) { throw "git failed: $Arguments`n$($run.Stderr)" }
    return $run
}

function Quote-FromConfigure([string]$Value) {
    $environment = @{
        CORALLINE_CONFIGURE = (Forward-Path $Configure)
        CORALLINE_Q_VALUE = $Value
    }
    $run = Invoke-CapturedProcess $script:BashExe ('--noprofile --norc "' + (Forward-Path $script:QuoteHelper) + '"') '' $environment $Repo 5000
    if ($run.ExitCode -ne 0 -or $run.TimedOut -or $run.StderrBytes.Length -ne 0) { throw 'configure.sh shell_quote fixture failed' }
    return $run.Stdout
}

function Assert-NoUnexpectedResidue([string]$Root, [string]$Name) {
    $bad = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like '*.tmp' -or $_.Name -like '*.lock' -or $_.Name -like 'burn-*.tsv' -or $_.Name -like 'limit-*.d'
    })
    Check "$Name no runtime residue" ($bad.Count -eq 0)
}

[void][System.IO.Directory]::CreateDirectory($TempRoot)
$cleanupOk = $false
try {
    $source = [System.IO.File]::ReadAllText($Script, $StrictUtf8)
    $bashSource = [System.IO.File]::ReadAllText($BashScript, $StrictUtf8)

    Check 'static source has no mojibake double question token' (-not $source.Contains(('?' + '?')))
    Check 'static source has no dangling handoff reference' (-not $source.Contains('handoff/'))
    Check 'static source forbids Invoke-Expression' (-not $source.Contains('Invoke-Expression'))
    Check 'static source forbids dynamic ScriptBlock creation' (-not $source.Contains('ScriptBlock]::Create'))
    Check 'literal subagent route precedes stdin open' ($source.IndexOf("-ceq '--subagent'") -ge 0 -and $source.IndexOf("-ceq '--subagent'") -lt $source.IndexOf('OpenStandardInput'))
    Check 'UNC lexical rejection precedes canonicalization' ($source.IndexOf("StartsWith('\\'") -ge 0 -and $source.IndexOf("StartsWith('\\'") -lt $source.IndexOf('GetFullPath($p)'))
    Check 'reparse validation precedes config read' ($source.IndexOf('Test-SafeRegularFile $Path') -lt $source.IndexOf('Read-StrictUtf8File $Path'))
    Check 'Bash oracle main extraction contains central scrub' ($bashSource.Contains('] | map(scrub) | join('))

    $expectedRegistry = @('clock','cost','ctx','dir','duration','effort','git','limit5h','limit7d','lines','model','node','project','python','stash','style')
    $builderBlock = [regex]::Match($source, '(?s)\$SegmentBuilders = \[ordered\]@\{(.*?)\n\}').Groups[1].Value
    $actualRegistry = @([regex]::Matches($builderBlock, '(?m)^    ([A-Za-z0-9]+) =') | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
    Check 'closed PowerShell registry equals WIN-01 inventory' (($actualRegistry -join ' ') -eq (($expectedRegistry | Sort-Object) -join ' '))
    $bashSegments = @([regex]::Matches($bashSource, '(?m)^seg_([A-Za-z0-9_]+)\(\)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne 'len' -and $_ -ne 'limit' -and $_ -ne 'burn' } | Sort-Object -Unique)
    Check 'Bash public registry minus burn equals WIN-01 inventory' (($bashSegments -join ' ') -eq (($expectedRegistry | Sort-Object) -join ' '))

    $script:BashExe = $env:CORALLINE_TEST_BASH
    if ([string]::IsNullOrEmpty($script:BashExe)) { $script:BashExe = 'C:\Program Files\Git\bin\bash.exe' }
    Check 'Git Bash oracle executable exists' ([System.IO.File]::Exists($script:BashExe))
    if (-not [System.IO.File]::Exists($script:BashExe)) { throw 'Git Bash oracle is required for WIN-01 tests' }
    $bashProbe = Invoke-CapturedProcess $script:BashExe '--noprofile --norc -lc "command -v jq >/dev/null && printf ready"' '' @{} $Repo 5000
    Check 'Git Bash jq oracle available' ($bashProbe.ExitCode -eq 0 -and $bashProbe.Stdout -eq 'ready' -and $bashProbe.StderrBytes.Length -eq 0)
    if ($bashProbe.ExitCode -ne 0) { throw 'Git Bash jq oracle unavailable' }

    $script:GitExe = (Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $gitRoot = Join-Path $TempRoot 'fixture-repo'
    [void][System.IO.Directory]::CreateDirectory($gitRoot)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot 'a.txt'), "one`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot '.nvmrc'), "v20.11.1`n", $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $gitRoot '.python-version'), "3.12.2`n", $Utf8NoBom)
    [void](Run-Git $gitRoot 'init -q')
    [void](Run-Git $gitRoot 'checkout -q -b main')
    [void](Run-Git $gitRoot 'config user.email test@example.com')
    [void](Run-Git $gitRoot 'config user.name test')
    [void](Run-Git $gitRoot 'add a.txt .nvmrc .python-version')
    [void](Run-Git $gitRoot 'commit -q -m init')
    [System.IO.File]::AppendAllText((Join-Path $gitRoot 'a.txt'), "stash`n", $Utf8NoBom)
    [void](Run-Git $gitRoot 'stash push -q -m fixture')
    $cwd = Forward-Path $gitRoot
    $repoLeaf = [System.IO.Path]::GetFileName($gitRoot)
    $basePayload = New-Payload $cwd

    $gitParityConfig = New-Config 'git-edge-parity' @('VL_SEGMENTS=git\ project','VL_CLOCK=off')
    $unbornRoot = Join-Path $TempRoot 'empty-repo'
    [void][System.IO.Directory]::CreateDirectory($unbornRoot)
    [void](Run-Git $unbornRoot 'init -q')
    [void](Run-Git $unbornRoot 'checkout -q -b main')
    $unbornPayload = New-Payload (Forward-Path $unbornRoot)
    $unbornPs = Invoke-Statusline (Json $unbornPayload) $gitParityConfig @{} '' 5000
    $unbornBash = Invoke-BashStatusline (Json $unbornPayload) $gitParityConfig @{}
    Check-Run 'PowerShell unborn Git repository' $unbornPs
    Check-Run 'Bash unborn Git repository' $unbornBash
    Check-Exact 'unborn Git repository differential is byte exact' $unbornPs $unbornBash
    Check 'unborn Git renders branch and project' ((Plain $unbornPs.Stdout).Contains('main') -and (Plain $unbornPs.Stdout).Contains('empty-repo'))

    $detachedRoot = Join-Path $TempRoot 'detached-repo'
    [void][System.IO.Directory]::CreateDirectory($detachedRoot)
    Write-Utf8 (Join-Path $detachedRoot 'tracked.txt') "tracked`n"
    [void](Run-Git $detachedRoot 'init -q')
    [void](Run-Git $detachedRoot 'checkout -q -b main')
    [void](Run-Git $detachedRoot 'config user.email test@example.com')
    [void](Run-Git $detachedRoot 'config user.name test')
    [void](Run-Git $detachedRoot 'add tracked.txt')
    [void](Run-Git $detachedRoot 'commit -q -m init')
    $detachedShort = (Run-Git $detachedRoot 'rev-parse --short=7 HEAD').Stdout.Trim()
    [void](Run-Git $detachedRoot 'checkout -q --detach')
    $detachedPayload = New-Payload (Forward-Path $detachedRoot)
    $detachedPs = Invoke-Statusline (Json $detachedPayload) $gitParityConfig @{} '' 5000
    $detachedBash = Invoke-BashStatusline (Json $detachedPayload) $gitParityConfig @{}
    Check-Run 'PowerShell detached Git repository' $detachedPs
    Check-Run 'Bash detached Git repository' $detachedBash
    Check-Exact 'detached Git repository differential is byte exact' $detachedPs $detachedBash
    Check 'detached Git keeps short oid and project' ((Plain $detachedPs.Stdout).Contains($detachedShort) -and (Plain $detachedPs.Stdout).Contains('detached-repo'))

    $unicodeLeaf = (Glyph 0x96EA) + 'repo'
    $unicodeBranch = (Glyph 0x529F) + (Glyph 0x80FD)
    $unicodeRoot = Join-Path $TempRoot $unicodeLeaf
    [void][System.IO.Directory]::CreateDirectory($unicodeRoot)
    Write-Utf8 (Join-Path $unicodeRoot 'tracked.txt') "tracked`n"
    [void](Run-Git $unicodeRoot 'init -q')
    [void](Run-Git $unicodeRoot ('checkout -q -b ' + $unicodeBranch))
    [void](Run-Git $unicodeRoot 'config user.email test@example.com')
    [void](Run-Git $unicodeRoot 'config user.name test')
    [void](Run-Git $unicodeRoot 'add tracked.txt')
    [void](Run-Git $unicodeRoot 'commit -q -m init')
    $unicodePayload = New-Payload (Forward-Path $unicodeRoot)
    $unicodeCommand = '[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(437); & ''' + $Script + ''''
    $unicodeArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $unicodeCommand.Replace('"','\"') + '"'
    $unicodePs = Invoke-CapturedProcess $PowerShellExe $unicodeArgs (Json $unicodePayload) (Runtime-Environment $gitParityConfig @{}) $Repo 5000
    $unicodeBash = Invoke-BashStatusline (Json $unicodePayload) $gitParityConfig @{}
    Check-Run 'PowerShell codepage 437 Unicode Git repository' $unicodePs
    Check-Run 'Bash Unicode Git repository' $unicodeBash
    Check-Exact 'Unicode Git repository differential is byte exact' $unicodePs $unicodeBash
    Check 'Unicode Git keeps project and branch text' ((Plain $unicodePs.Stdout).Contains($unicodeLeaf) -and (Plain $unicodePs.Stdout).Contains($unicodeBranch))

    $script:QuoteHelper = Join-Path $TempRoot 'configure-quote.sh'
    Write-Utf8 $script:QuoteHelper @'
#!/usr/bin/env bash
eval "$(sed -n '/^shell_quote()/,/^}/p' "$CORALLINE_CONFIGURE")"
shell_quote "$CORALLINE_Q_VALUE"
'@
    $quotedSegments = Quote-FromConfigure 'dir git model ctx'
    Check 'real configure shell_quote emits escaped multi-word value' ($quotedSegments.Contains('\ '))
    $quotedConfig = New-Config 'configure-q-segments' @("VL_SEGMENTS=$quotedSegments", 'VL_CLOCK=off')
    $quotedRun = Invoke-Statusline (Json $basePayload) $quotedConfig @{} '' 5000
    Check-Run 'configure %q segment list' $quotedRun
    $quotedPlain = Plain $quotedRun.Stdout
    Check 'configure %q segment list renders every token' ($quotedPlain.Contains($repoLeaf) -and $quotedPlain.Contains('main') -and $quotedPlain.Contains('MODEL_SENTINEL') -and $quotedPlain.Contains('62%'))

    $paddedQuote = Quote-FromConfigure ' model '
    $paddedLine = 'VL_SEGMENTS=' + $paddedQuote
    $paddedConfig = New-Config 'configure-q-padded' @($paddedLine, 'VL_CLOCK=off')
    $paddedRun = Invoke-Statusline (Json $basePayload) $paddedConfig @{} '' 5000
    Check-Run 'configure %q leading and trailing spaces' $paddedRun
    Check 'configure %q preserves one padded shell word' ((Plain $paddedRun.Stdout).Contains('MODEL_SENTINEL') -and -not (Plain $paddedRun.Stdout).Contains((Glyph 0x2299)))

    $spaceRoot = Join-Path $TempRoot 'space root'
    [void][System.IO.Directory]::CreateDirectory($spaceRoot)
    $spaceTheme = Join-Path $spaceRoot 'space theme.conf'
    Write-Utf8 $spaceTheme "VL_BG_MODEL=33`n"
    $quotedInclude = Quote-FromConfigure (Forward-Path $spaceTheme)
    $spaceConfig = Join-Path $spaceRoot 'coralline.conf'
    Write-Utf8 $spaceConfig ('. ' + $quotedInclude + "`nVL_SEGMENTS=model`nVL_CLOCK=off`n")
    [void](Run-ModelColor 'configure %q spaced include' $spaceConfig '33' @{})

    $wordConfig = New-Config 'word-forms' @(
        "VL_SEGMENTS='model'",
        'VL_CLOCK="off"',
        'VL_BG_MODEL=44'
    )
    [void](Run-ModelColor 'single and double shell words' $wordConfig '44' @{})
    $bareConfig = New-Config 'bare-escape' @('VL_SEGMENTS=model\ ctx', 'VL_CLOCK=off')
    $bareRun = Invoke-Statusline (Json $basePayload) $bareConfig @{} '' 5000
    Check-Run 'bare backslash shell word' $bareRun
    Check 'bare backslash shell word decodes spaces' ((Plain $bareRun.Stdout).Contains('MODEL_SENTINEL') -and (Plain $bareRun.Stdout).Contains('62%'))

    $controlQuote = Quote-FromConfigure ("X`nY")
    Check 'real configure quote selects ANSI-C for newline' ($controlQuote.StartsWith("$'", [System.StringComparison]::Ordinal))
    $ansiConfig = New-Config 'ansi-c' @('VL_SEGMENTS=ctx', 'VL_CLOCK=off', "VL_CTX_GLYPH=$controlQuote")
    $ansiRun = Invoke-Statusline (Json $basePayload) $ansiConfig @{} '' 5000
    Check-Run 'ANSI-C percent-q decode' $ansiRun
    Check 'decoded config controls are scrubbed before render' ((Plain $ansiRun.Stdout).Contains('XY') -and -not (Plain $ansiRun.Stdout).Contains("X`nY"))

    $themeInclude = Quote-FromConfigure (Forward-Path (Join-Path $Repo 'themes\dracula.conf'))
    $themeConfig = New-Config 'shipped-theme' @(('. ' + $themeInclude), 'VL_SEGMENTS=model', 'VL_CLOCK=off')
    [void](Run-ModelColor 'approved runtime theme include' $themeConfig '189,147,249' @{})

    $homeRoot = Join-Path $TempRoot 'fake-home'
    $homeThemes = Join-Path $homeRoot 'themes'
    [void][System.IO.Directory]::CreateDirectory($homeThemes)
    foreach ($name in @('dollar','braced','tilde')) { Write-Utf8 (Join-Path $homeThemes "$name.conf") "VL_BG_MODEL=55`n" }
    foreach ($case in @(
        [pscustomobject]@{ Name='HOME include'; Word='$HOME/themes/dollar.conf' },
        [pscustomobject]@{ Name='braced HOME include'; Word='${HOME}/themes/braced.conf' },
        [pscustomobject]@{ Name='tilde include'; Word='~/themes/tilde.conf' }
    )) {
        $config = Join-Path $homeRoot ($case.Name.Replace(' ','-') + '.conf')
        Write-Utf8 $config ('. ' + $case.Word + "`nVL_SEGMENTS=model`nVL_CLOCK=off`n")
        [void](Run-ModelColor $case.Name $config '55' @{ HOME=$homeRoot; USERPROFILE=$homeRoot })
    }

    $driveConfig = New-Config 'msys-root' @('VL_SEGMENTS=model', 'VL_CLOCK=off', 'VL_BG_MODEL=56')
    $drivePath = Forward-Path $driveConfig
    $msysConfig = '/' + $drivePath.Substring(0,1).ToLowerInvariant() + $drivePath.Substring(2)
    $msysRun = Invoke-Statusline (Json $basePayload) $msysConfig @{} '' 5000
    Check-Run 'MSYS root config path' $msysRun
    Check 'MSYS root config path applies config' ($msysRun.Stdout.Contains('48;5;56m'))

    $includeDir = Join-Path $TempRoot 'transactions'
    [void][System.IO.Directory]::CreateDirectory($includeDir)
    $good = Join-Path $includeDir 'good.conf'
    Write-Utf8 $good "VL_BG_MODEL=61`n"
    $beforeAfter = Join-Path $includeDir 'before-after.conf'
    Write-Utf8 $beforeAfter "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=60`n. good.conf`nVL_BG_MODEL=62`n"
    [void](Run-ModelColor 'assignment before and after include' $beforeAfter '62' @{})

    $missing = Join-Path $includeDir 'missing-root.conf'
    Write-Utf8 $missing "VL_SEGMENTS=model`nVL_CLOCK=off`n. missing.conf`nVL_BG_MODEL=63`n"
    [void](Run-ModelColor 'missing include is nested no-op' $missing '63' @{})

    $invalidChild = Join-Path $includeDir 'invalid-child.conf'
    Write-Utf8 $invalidChild "VL_BG_MODEL=99`necho unsupported`n"
    $invalidChildRoot = Join-Path $includeDir 'invalid-child-root.conf'
    Write-Utf8 $invalidChildRoot "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=64`n. invalid-child.conf`n"
    [void](Run-ModelColor 'malformed include rolls back only include delta' $invalidChildRoot '64' @{})

    $cycleA = Join-Path $includeDir 'cycle-a.conf'
    $cycleB = Join-Path $includeDir 'cycle-b.conf'
    Write-Utf8 $cycleA "VL_SEGMENTS=model`nVL_CLOCK=off`n. cycle-b.conf`n"
    Write-Utf8 $cycleB "VL_BG_MODEL=65`n. cycle-a.conf`n"
    [void](Run-ModelColor 'include cycle is silent no-op at cycle edge' $cycleA '65' @{})

    $depthDir = Join-Path $includeDir 'depth'
    [void][System.IO.Directory]::CreateDirectory($depthDir)
    for ($i=1; $i -le 9; $i++) {
        $lines = @("VL_BG_MODEL=$($i + 70)")
        if ($i -lt 9) { $lines += ". d$($i + 1).conf" }
        Write-Utf8 (Join-Path $depthDir "d$i.conf") (($lines -join "`n") + "`n")
    }
    $depthRoot = Join-Path $depthDir 'root.conf'
    Write-Utf8 $depthRoot "VL_SEGMENTS=model`nVL_CLOCK=off`n. d1.conf`n"
    [void](Run-ModelColor 'include depth eight commits and depth nine is no-op' $depthRoot '78' @{})

    $outsideDir = Join-Path $TempRoot 'outside'
    [void][System.IO.Directory]::CreateDirectory($outsideDir)
    Write-Utf8 (Join-Path $outsideDir 'evil.conf') "VL_BG_MODEL=99`n"
    $outRoot = Join-Path $includeDir 'out-root.conf'
    Write-Utf8 $outRoot "VL_SEGMENTS=model`nVL_CLOCK=off`n. ../outside/evil.conf`nVL_BG_MODEL=66`n"
    [void](Run-ModelColor 'out-of-root include is nested no-op' $outRoot '66' @{})

    $malformedRoot = Join-Path $includeDir 'malformed-root.conf'
    Write-Utf8 $malformedRoot "VL_SEGMENTS=model`nVL_CLOCK=off`nVL_BG_MODEL=99`necho unsupported`n"
    [void](Run-ModelColor 'malformed root rolls back all root assignments' $malformedRoot '173' @{})
    $includeThenBad = Join-Path $includeDir 'include-then-bad.conf'
    Write-Utf8 $includeThenBad "VL_SEGMENTS=model`nVL_CLOCK=off`n. good.conf`necho unsupported`n"
    [void](Run-ModelColor 'successful include delta rolls back with malformed root' $includeThenBad '173' @{})

    foreach ($bad in @(
        [pscustomobject]@{ Name='command substitution'; Value='$(whoami)' },
        [pscustomobject]@{ Name='backtick'; Value='`whoami`' },
        [pscustomobject]@{ Name='pipeline'; Value='model|ctx' },
        [pscustomobject]@{ Name='redirect'; Value='model>file' },
        [pscustomobject]@{ Name='semicolon'; Value='model;ctx' },
        [pscustomobject]@{ Name='multiple words'; Value='model ctx' },
        [pscustomobject]@{ Name='incomplete escape'; Value='model\' }
    )) {
        $config = Join-Path $includeDir ('reject-' + $bad.Name.Replace(' ','-') + '.conf')
        Write-Utf8 $config ("VL_BG_MODEL=99`nVL_SEGMENTS=$($bad.Value)`n")
        [void](Run-ModelColor ("reject " + $bad.Name) $config '173' @{})
    }

    $conditional = Join-Path $includeDir 'conditional.conf'
    # Safe-subset rule: parser control flow reads REMORA_ACTIVE only from the process environment.
    Write-Utf8 $conditional @'
VL_SEGMENTS=model
VL_CLOCK=off
REMORA_ACTIVE=1
if [ "${REMORA_ACTIVE:-0}" = "1" ]; then
VL_BG_MODEL=81
else
VL_BG_MODEL=82
fi
'@
    foreach ($case in @(
        [pscustomobject]@{ Name='REMORA unset uses zero'; Env=@{}; Color='82' },
        [pscustomobject]@{ Name='REMORA empty uses zero'; Env=@{ REMORA_ACTIVE='' }; Color='82' },
        [pscustomobject]@{ Name='REMORA zero selects else'; Env=@{ REMORA_ACTIVE='0' }; Color='82' },
        [pscustomobject]@{ Name='REMORA one selects then'; Env=@{ REMORA_ACTIVE='1' }; Color='81' }
    )) { [void](Run-ModelColor $case.Name $conditional $case.Color $case.Env) }

    $notEqual = Join-Path $includeDir 'conditional-ne.conf'
    Write-Utf8 $notEqual @'
VL_SEGMENTS=model
VL_CLOCK=off
if [ "${REMORA_ACTIVE:-0}" != "1" ]; then
VL_BG_MODEL=83
else
VL_BG_MODEL=84
fi
'@
    [void](Run-ModelColor 'REMORA not-equal true branch' $notEqual '83' @{ REMORA_ACTIVE='0' })
    [void](Run-ModelColor 'REMORA not-equal else branch' $notEqual '84' @{ REMORA_ACTIVE='1' })

    $inactive = Join-Path $includeDir 'inactive.conf'
    Write-Utf8 $inactive @'
VL_SEGMENTS=model
VL_CLOCK=off
if [ "${REMORA_ACTIVE:-0}" = "1" ]; then
VL_BG_MODEL=$(unsupported)
. missing.conf
else
VL_BG_MODEL=85
fi
'@
    [void](Run-ModelColor 'inactive branch assignments and includes have no effect' $inactive '85' @{ REMORA_ACTIVE='0' })
    $unsupportedIf = Join-Path $includeDir 'unsupported-if.conf'
    Write-Utf8 $unsupportedIf "VL_BG_MODEL=99`nif test -n x; then`nVL_BG_MODEL=1`nfi`n"
    [void](Run-ModelColor 'unsupported conditional rolls back root' $unsupportedIf '173' @{})

    $budgetDir = Join-Path $includeDir 'budget'
    [void][System.IO.Directory]::CreateDirectory($budgetDir)
    Write-Utf8 (Join-Path $budgetDir 'target16.conf') "VL_BG_MODEL=91`n"
    Write-Utf8 (Join-Path $budgetDir 'target17.conf') "VL_BG_MODEL=92`n"
    Write-Utf8 (Join-Path $budgetDir 'dup.conf') "VL_FG_DIM=1`n"
    foreach ($kind in @('missing','duplicate','cycle','rejected')) {
        $root = Join-Path $budgetDir ("budget-$kind.conf")
        $lines = @('VL_SEGMENTS=model','VL_CLOCK=off')
        for ($i=1; $i -le 15; $i++) {
            switch ($kind) {
                'missing' { $lines += ". missing-$i.conf" }
                'duplicate' { $lines += '. dup.conf' }
                'cycle' { $lines += ('. ' + [System.IO.Path]::GetFileName($root)) }
                'rejected' { $lines += '. ../../outside/evil.conf' }
            }
        }
        $lines += '. target16.conf'
        $lines += '. target17.conf'
        $lines += 'VL_FG_TEXT=42'
        Write-Utf8 $root (($lines -join "`n") + "`n")
        $run = Run-ModelColor ("include budget counts $kind attempts") $root '91' @{}
        Check "include budget $kind leaves later root assignment live" ($run.Stdout.Contains('38;5;42m'))
        Check "include budget $kind makes seventeenth a complete no-op" (-not $run.Stdout.Contains('48;5;92m'))
    }

    $inactiveBudget = Join-Path $budgetDir 'inactive-budget.conf'
    $inactiveLines = @('VL_SEGMENTS=model','VL_CLOCK=off','if [ "${REMORA_ACTIVE:-0}" = "1" ]; then')
    for ($i=1; $i -le 20; $i++) { $inactiveLines += ". inactive-$i.conf" }
    $inactiveLines += 'else'
    for ($i=1; $i -le 15; $i++) { $inactiveLines += ". active-missing-$i.conf" }
    $inactiveLines += '. target16.conf'
    $inactiveLines += 'fi'
    Write-Utf8 $inactiveBudget (($inactiveLines -join "`n") + "`n")
    [void](Run-ModelColor 'inactive includes consume no shared budget' $inactiveBudget '91' @{ REMORA_ACTIVE='0' })

    $baseConfigLines = @('VL_CLOCK=off')
    $segmentCases = [ordered]@{
        clock = [pscustomobject]@{ Show=@('VL_SEGMENTS=clock','VL_CLOCK=24h','VL_CLOCK_SECONDS=0'); Needle=(Glyph 0x2299); Suppress={ param($p) $p }; SuppressConfig=@('VL_SEGMENTS=clock','VL_CLOCK=off') }
        cost = [pscustomobject]@{ Show=@('VL_SEGMENTS=cost','VL_CLOCK=off'); Needle='$1.23'; Suppress={ param($p) $p.cost.total_cost_usd=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=cost' }
        ctx = [pscustomobject]@{ Show=@('VL_SEGMENTS=ctx','VL_CLOCK=off'); Needle='62%'; Suppress={ param($p) $p.context_window.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=ctx' }
        dir = [pscustomobject]@{ Show=@('VL_SEGMENTS=dir','VL_CLOCK=off'); Needle=$repoLeaf; Suppress={ param($p) $p.cwd=''; $p.workspace.current_dir=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=dir' }
        duration = [pscustomobject]@{ Show=@('VL_SEGMENTS=duration','VL_CLOCK=off'); Needle='1h30m'; Suppress={ param($p) $p.cost.total_duration_ms=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=duration' }
        effort = [pscustomobject]@{ Show=@('VL_SEGMENTS=effort','VL_CLOCK=off'); Needle='high'; Suppress={ param($p) $p.effort.level=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=effort' }
        git = [pscustomobject]@{ Show=@('VL_SEGMENTS=git','VL_CLOCK=off'); Needle='main'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-repo'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=git' }
        limit5h = [pscustomobject]@{ Show=@('VL_SEGMENTS=limit5h','VL_CLOCK=off'); Needle='41%'; Suppress={ param($p) $p.rate_limits.five_hour.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=limit5h' }
        limit7d = [pscustomobject]@{ Show=@('VL_SEGMENTS=limit7d','VL_CLOCK=off'); Needle='79%'; Suppress={ param($p) $p.rate_limits.seven_day.used_percentage=$null; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=limit7d' }
        lines = [pscustomobject]@{ Show=@('VL_SEGMENTS=lines','VL_CLOCK=off'); Needle='+321 -87'; Suppress={ param($p) $p.cost.total_lines_added=0; $p.cost.total_lines_removed=0; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=lines' }
        model = [pscustomobject]@{ Show=@('VL_SEGMENTS=model','VL_CLOCK=off'); Needle='MODEL_SENTINEL'; Suppress={ param($p) $p.model.display_name=''; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=model' }
        node = [pscustomobject]@{ Show=@('VL_SEGMENTS=node','VL_CLOCK=off'); Needle='20.11.1'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-pin'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=node' }
        project = [pscustomobject]@{ Show=@('VL_SEGMENTS=project','VL_CLOCK=off'); Needle=[System.IO.Path]::GetFileName($gitRoot); Suppress={ param($p) $p.cwd=''; $p.workspace.current_dir=''; $p }; SuppressConfig=@('VL_SEGMENTS=dir\ project','VL_CLOCK=off') }
        python = [pscustomobject]@{ Show=@('VL_SEGMENTS=python','VL_CLOCK=off'); Needle='3.12.2'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-pin'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=python' }
        stash = [pscustomobject]@{ Show=@('VL_SEGMENTS=stash','VL_CLOCK=off'); Needle='1'; Suppress={ param($p) $p.cwd='C:/tmp/coralline-win01-no-repo'; $p.workspace.current_dir=$p.cwd; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=stash' }
        style = [pscustomobject]@{ Show=@('VL_SEGMENTS=style','VL_CLOCK=off'); Needle='Explanatory'; Suppress={ param($p) $p.output_style.name='default'; $p }; SuppressConfig=$baseConfigLines + 'VL_SEGMENTS=style' }
    }

    foreach ($name in $expectedRegistry) {
        $case = $segmentCases[$name]
        $showConfig = New-Config ("segment-$name-show") $case.Show
        $show = Invoke-Statusline (Json $basePayload) $showConfig @{} '' 5000
        Check-Run "$name show" $show
        Check "$name show/value" ((Plain $show.Stdout).Contains([string]$case.Needle))
        $suppressedPayload = Clone-Object $basePayload
        $suppressedPayload = & $case.Suppress $suppressedPayload
        $suppressConfig = New-Config ("segment-$name-suppress") $case.SuppressConfig
        $suppress = Invoke-Statusline (Json $suppressedPayload) $suppressConfig @{} '' 5000
        Check-Run "$name suppress" $suppress
        Check "$name suppresses without an empty pill" ([string]::IsNullOrEmpty($suppress.Stdout))
    }

    $orderedNames = @('dir','project','git','node','python','model','effort','ctx','limit5h','limit7d','lines','cost','style','duration','stash')
    $orderedValue = $orderedNames -join ' '
    $orderConfig = New-Config 'segment-order' @(('VL_SEGMENTS=' + (Quote-FromConfigure $orderedValue)), 'VL_CLOCK=off')
    $orderRun = Invoke-Statusline (Json $basePayload) $orderConfig @{} '' 5000
    Check-Run 'configured segment order' $orderRun
    $visible = Plain $orderRun.Stdout
    $needles = @($repoLeaf, $repoLeaf, 'main', '20.11.1', '3.12.2', 'MODEL_SENTINEL', 'high', '62%', '5h', '7d', '+321 -87', '$1.23', 'Explanatory', '1h30m', ((Glyph 0x2691) + ' 1'))
    $lastIndex = -1
    $orderOk = $true
    foreach ($needle in $needles) {
        $nextIndex = $visible.IndexOf($needle, $lastIndex + 1, [System.StringComparison]::Ordinal)
        if ($nextIndex -le $lastIndex) { $orderOk = $false; break }
        $lastIndex = $nextIndex
    }
    Check 'configured segment order is preserved exactly' $orderOk

    $bashOrder = Invoke-BashStatusline (Json $basePayload) $orderConfig @{}
    Check-Run 'Bash full stateless oracle' $bashOrder
    Check-Exact 'full fixed-pill differential is byte exact' $orderRun $bashOrder
    if (-not ($orderRun.Stdout -ceq $bashOrder.Stdout)) { [Console]::Out.WriteLine('DIAG  order-config=' + [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($orderConfig))) }

    $themePs = Invoke-Statusline (Json $basePayload) $themeConfig @{} '' 5000
    $themeBash = Invoke-BashStatusline (Json $basePayload) $themeConfig @{}
    Check-Run 'PowerShell theme differential input' $themePs
    Check-Run 'Bash theme differential input' $themeBash
    Check-Exact 'theme include differential is byte exact' $themePs $themeBash

    $glyphConfig = New-Config 'glyph-knobs' @(
        'VL_SEGMENTS=project\ ctx',
        'VL_CLOCK=off',
        'VL_BAR_FILL=F',
        'VL_BAR_EMPTY=E',
        'VL_CTX_GLYPH=C',
        'VL_PROJECT_GLYPH=P'
    )
    $glyphRun = Invoke-Statusline (Json $basePayload) $glyphConfig @{} '' 5000
    Check-Run 'four documented glyph knobs' $glyphRun
    $glyphPlain = Plain $glyphRun.Stdout
    Check 'project and ctx glyph overrides render' ($glyphPlain.Contains(' P ') -and $glyphPlain.Contains(' C '))
    Check 'bar fill and empty overrides render' ($glyphPlain.Contains('FFFEE'))

    $missingTokens = Clone-Object $basePayload
    $missingTokens.context_window.total_input_tokens = $null
    $missingTokens.context_window.total_output_tokens = $null
    $missingTokens.context_window.current_usage.cache_read_input_tokens = $null
    $missingTokens.context_window.current_usage.cache_creation_input_tokens = $null
    $tokenConfig = New-Config 'missing-tokens' @('VL_SEGMENTS=ctx','VL_CLOCK=off')
    $tokenRun = Invoke-Statusline (Json $missingTokens) $tokenConfig @{} '' 5000
    Check-Run 'missing token values' $tokenRun
    Check 'missing token values render zero' ((Plain $tokenRun.Stdout).Contains((Glyph 0x2191) + '0 ' + (Glyph 0x2193) + '0 cr:0 cw:0'))

    $dirConfig = New-Config 'dir-only' @('VL_SEGMENTS=dir','VL_CLOCK=off','VL_PATH_DEPTH=4')
    foreach ($case in @(
        [pscustomobject]@{ Name='Unix root'; Path='/'; Expected=' / ' },
        [pscustomobject]@{ Name='drive root'; Path='C:/'; Expected=' C:/ ' },
        [pscustomobject]@{ Name='deep drive'; Path='C:/one/two/three/four'; Expected=' C:/one/' + (Glyph 0x2026) + '/four ' },
        [pscustomobject]@{ Name='UNC root'; Path='//server/share/'; Expected=' //server/share ' },
        [pscustomobject]@{ Name='deep UNC'; Path='//server/share/one/two/three'; Expected=' //server/share/' + (Glyph 0x2026) + '/three ' }
    )) {
        $payload = New-Payload $case.Path
        $run = Invoke-Statusline (Json $payload) $dirConfig @{} '' 5000
        Check-Run $case.Name $run
        Check "$($case.Name) path semantics" ((Plain $run.Stdout).Contains($case.Expected))
    }

    $durationConfig = New-Config 'duration-main' @('VL_SEGMENTS=duration','VL_CLOCK=off')
    $durationRun = Invoke-Statusline (Json $basePayload) $durationConfig @{} '' 5000
    Check 'main duration omits seconds once minutes render' ((Plain $durationRun.Stdout).Contains('1h30m') -and -not (Plain $durationRun.Stdout).Contains('1h30m54s'))

    $midpointConfig = New-Config 'percent-midpoint' @('VL_SEGMENTS=ctx\ limit5h\ limit7d','VL_CLOCK=off')
    foreach ($raw in @('61.5','62.5')) {
        $payload = Clone-Object $basePayload
        $value = [double]::Parse($raw, $Invariant)
        $payload.context_window.used_percentage = $value
        $payload.rate_limits.five_hour.used_percentage = $value
        $payload.rate_limits.seven_day.used_percentage = $value
        $psRun = Invoke-Statusline (Json $payload) $midpointConfig @{} '' 5000
        $bashRun = Invoke-BashStatusline (Json $payload) $midpointConfig @{}
        Check-Run "PowerShell percentage midpoint $raw" $psRun
        Check-Run "Bash percentage midpoint $raw" $bashRun
        Check-Exact "percentage midpoint $raw differential is byte exact" $psRun $bashRun
    }

    foreach ($raw in @('-5','NaN','Infinity','1e999','999999999999999999999999999999')) {
        $payload = Clone-Object $basePayload
        $payload.context_window.used_percentage = $raw
        $payload.rate_limits.five_hour.used_percentage = $raw
        $payload.cost.total_cost_usd = $raw
        $payload.cost.total_duration_ms = $raw
        $payload.cost.total_lines_added = $raw
        $numericConfig = New-Config ('numeric-' + [Math]::Abs($raw.GetHashCode())) @(
            'VL_SEGMENTS=ctx\ limit5h\ cost\ duration\ lines',
            'VL_CLOCK=off',
            'VL_BAR_WIDTH=999999999999999999999',
            'VL_COST_DECIMALS=-1',
            'VL_WARN_PCT=NaN',
            'VL_HOT_PCT=Infinity',
            'VL_BG_CTX=999'
        )
        $run = Invoke-Statusline (Json $payload) $numericConfig @{} '' 5000
        Check-Run "bounded numeric $raw" $run
        Check "bounded numeric $raw output is finite" ($run.StdoutBytes.Length -lt 4096 -and -not $run.Stdout.Contains('NaN') -and -not $run.Stdout.Contains('Infinity'))
        Check "bounded numeric $raw invalid color falls back" ($run.Stdout.Contains('48;5;238m'))
    }

    $absentConfig = New-Config 'absent-executables' @('VL_SEGMENTS=git\ node\ python\ model','VL_CLOCK=off','VL_RUNTIME_PROBE=1')
    $absentPayload = New-Payload (Forward-Path (Join-Path $TempRoot 'no-pin-dir'))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $TempRoot 'no-pin-dir'))
    $emptyPath = Join-Path $TempRoot 'empty-path'
    [void][System.IO.Directory]::CreateDirectory($emptyPath)
    $absentRun = Invoke-Statusline (Json $absentPayload) $absentConfig @{ PATH=$emptyPath } '' 5000
    Check-Run 'absent Git Node Python executables' $absentRun
    Check 'absent executables suppress only dependent segments' ((Plain $absentRun.Stdout).Contains('MODEL_SENTINEL') -and -not (Plain $absentRun.Stdout).Contains('20.11.1') -and -not (Plain $absentRun.Stdout).Contains('3.12.2'))

    $pythonEnvConfig = New-Config 'python-env-cwd-gate' @('VL_SEGMENTS=python','VL_CLOCK=off')
    foreach ($case in @(
        [pscustomobject]@{ Name='virtualenv'; Environment=@{ VIRTUAL_ENV='C:/venvs/demo' } },
        [pscustomobject]@{ Name='conda'; Environment=@{ CONDA_DEFAULT_ENV='demo' } }
    )) {
        $emptyPs = Invoke-Statusline '{}' $pythonEnvConfig $case.Environment '' 5000
        $emptyBash = Invoke-BashStatusline '{}' $pythonEnvConfig $case.Environment
        Check-Run "PowerShell empty-cwd $($case.Name)" $emptyPs
        Check-Run "Bash empty-cwd $($case.Name)" $emptyBash
        Check-Exact "empty-cwd $($case.Name) differential is byte exact" $emptyPs $emptyBash
        Check "empty-cwd $($case.Name) suppresses python" ($emptyPs.StdoutBytes.Length -eq 0)

        $cwdPs = Invoke-Statusline (Json $basePayload) $pythonEnvConfig $case.Environment '' 5000
        $cwdBash = Invoke-BashStatusline (Json $basePayload) $pythonEnvConfig $case.Environment
        Check-Run "PowerShell cwd $($case.Name)" $cwdPs
        Check-Run "Bash cwd $($case.Name)" $cwdBash
        Check-Exact "cwd $($case.Name) differential is byte exact" $cwdPs $cwdBash
        Check "cwd $($case.Name) renders env label" ((Plain $cwdPs.Stdout).Contains('demo'))
    }

    $controlPayload = New-Payload ''
    $controlPayload.model.display_name = 'Claude A' + [char]0 + 'B' + [char]27 + '[2J' + 'C' + [char]10 + 'D' + [char]13 + 'E' + [char]0x7F + 'F' + [char]0x85 + 'G'
    $controlConfig = New-Config 'control-scrub' @('VL_SEGMENTS=model','VL_CLOCK=off')
    $controlRun = Invoke-Statusline (Json $controlPayload) $controlConfig @{} '' 5000
    Check-Run 'main payload control scrub' $controlRun
    $controlPlain = Plain $controlRun.Stdout
    Check 'main payload controls are removed from visible text' ($controlPlain.Contains('AB[2JCDEFG'))
    $maliciousAnsi = [byte[]]@(27,91,50,74)
    $hasMalicious = $false
    for ($i=0; $i -le $controlRun.StdoutBytes.Length - $maliciousAnsi.Length; $i++) {
        $same = $true
        for ($j=0; $j -lt $maliciousAnsi.Length; $j++) { if ($controlRun.StdoutBytes[$i+$j] -ne $maliciousAnsi[$j]) { $same=$false; break } }
        if ($same) { $hasMalicious=$true; break }
    }
    Check 'payload ESC cannot create terminal ANSI' (-not $hasMalicious)
    Check 'renderer-generated ANSI remains present' ($controlRun.Stdout.Contains(([string][char]27 + '[48;5;173m')))
    Check 'payload CR and C1 bytes are absent' (-not ($controlRun.StdoutBytes -contains [byte]13) -and -not $controlRun.Stdout.Contains([string][char]0x85))
    $controlBash = Invoke-BashStatusline (Json $controlPayload) $controlConfig @{}
    Check-Run 'Bash main payload control scrub' $controlBash
    Check 'Bash and PowerShell scrub have the same observable output' ($controlRun.Stdout -eq $controlBash.Stdout)

    $codepagePayload = New-Payload ''
    $codepagePayload.model.display_name = 'Claude UTF8-' + (Glyph 0x96EA)
    $codepageConfig = New-Config 'codepage' @('VL_SEGMENTS=model','VL_CLOCK=off')
    $command = '[Console]::OutputEncoding=[Text.Encoding]::GetEncoding(437); & ''' + $Script + ''''
    $cpArgs = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + $command.Replace('"','\"') + '"'
    $codepageRun = Invoke-CapturedProcess $PowerShellExe $cpArgs (Json $codepagePayload) (Runtime-Environment $codepageConfig @{}) $Repo 5000
    Check-Run 'codepage 437 raw I/O' $codepageRun
    Check 'stdout is UTF-8 without BOM' ($codepageRun.StdoutBytes.Length -ge 3 -and -not ($codepageRun.StdoutBytes[0] -eq 0xEF -and $codepageRun.StdoutBytes[1] -eq 0xBB -and $codepageRun.StdoutBytes[2] -eq 0xBF) -and $codepageRun.Stdout.Contains((Glyph 0x96EA)))
    Check 'stdout uses LF without CR' (-not ($codepageRun.StdoutBytes -contains [byte]13) -and $codepageRun.StdoutBytes[$codepageRun.StdoutBytes.Length - 1] -eq 10)

    $subagentRun = Invoke-Statusline '' '\\localhost\never\touch.conf' @{} '--subagent' 5000
    Check-Run 'literal subagent early route' $subagentRun
    Check 'literal subagent route emits no main output' ($subagentRun.StdoutBytes.Length -eq 0)

    $secRoot = Join-Path $TempRoot 'security'
    $secConfigRoot = Join-Path $secRoot 'config'
    $secOutside = Join-Path $secRoot 'outside'
    [void][System.IO.Directory]::CreateDirectory($secConfigRoot)
    [void][System.IO.Directory]::CreateDirectory($secOutside)
    $evil = Join-Path $secOutside 'evil.conf'
    Write-Utf8 $evil "VL_BG_MODEL=99`n"
    $evilBefore = Snapshot-File $evil

    $sec01 = Join-Path $secConfigRoot 'sec-inc-01.conf'
    Write-Utf8 $sec01 "VL_SEGMENTS=model`nVL_CLOCK=off`n. ../outside/evil.conf`n"
    $run01 = Run-ModelColor 'SEC-INC-01 traversal rejection' $sec01 '173' @{}
    Check 'SEC-INC-01 outside canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
    Check 'SEC-INC-01 completes within five seconds' ($run01.ElapsedMs -lt 5000)
    Assert-NoUnexpectedResidue $secRoot 'SEC-INC-01'

    $uncCanary = '\\localhost\C$\tmp\' + [System.IO.Path]::GetFileName($Repo) + '\' + [System.IO.Path]::GetFileName($TempRoot) + '\security\outside\evil.conf'
    $probeCommand = "try { [IO.File]::ReadAllText('$uncCanary') | Out-Null; exit 0 } catch { exit 2 }"
    $uncProbe = Invoke-CapturedProcess $PowerShellExe ('-NoLogo -NoProfile -NonInteractive -Command "' + $probeCommand + '"') '' @{} $Repo 3000
    $staticUnc = $source.IndexOf("StartsWith('\\'") -ge 0 -and $source.IndexOf("StartsWith('\\'") -lt $source.IndexOf('GetFullPath($p)')
    if ($uncProbe.ExitCode -eq 0 -and -not $uncProbe.TimedOut) {
        $sec02 = Join-Path $secConfigRoot 'sec-inc-02.conf'
        Write-Utf8 $sec02 ("VL_SEGMENTS=model`nVL_CLOCK=off`n. '$uncCanary'`n")
        $run02 = Run-ModelColor 'SEC-INC-02 UNC rejection' $sec02 '173' @{}
        Check 'SEC-INC-02 rejects before five-second watchdog' ($run02.ElapsedMs -lt 5000)
        Check 'SEC-INC-02 canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-02 static pre-I/O ordering evidence' $staticUnc
    } else {
        Check 'SEC-INC-02 static pre-I/O ordering evidence' $staticUnc
        Blocked 'SEC-INC-02' 'readable loopback UNC share unavailable on host'
    }

    foreach ($device in @('\\?\' + $evil, '\\.\' + $evil)) {
        $sec03 = Join-Path $secConfigRoot ('sec-inc-03-' + [Math]::Abs($device.GetHashCode()) + '.conf')
        Write-Utf8 $sec03 ("VL_SEGMENTS=model`nVL_CLOCK=off`n. '$device'`n")
        $run03 = Run-ModelColor 'SEC-INC-03 device namespace rejection' $sec03 '173' @{}
        Check 'SEC-INC-03 canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-03 completes within five seconds' ($run03.ElapsedMs -lt 5000)
    }

    $carrier = Join-Path $secConfigRoot 'carrier.txt'
    Write-Utf8 $carrier 'PRIMARY'
    $adsAvailable = $true
    try {
        Set-Content -LiteralPath $carrier -Stream 'evil.conf' -Value 'VL_BG_MODEL=99' -Encoding UTF8 -NoNewline -ErrorAction Stop
        $adsBefore = Snapshot-Ads $carrier 'evil.conf'
        if ($null -eq $adsBefore) { $adsAvailable = $false }
    } catch { $adsAvailable = $false }
    if ($adsAvailable) {
        $primaryBefore = Snapshot-File $carrier
        $sec04 = Join-Path $secConfigRoot 'sec-inc-04.conf'
        Write-Utf8 $sec04 "VL_SEGMENTS=model`nVL_CLOCK=off`n. carrier.txt:evil.conf`n"
        [void](Run-ModelColor 'SEC-INC-04 ADS rejection' $sec04 '173' @{})
        Check 'SEC-INC-04 primary stream unchanged' ((Snapshot-File $carrier) -eq $primaryBefore)
        Check 'SEC-INC-04 alternate stream unchanged' ((Snapshot-Ads $carrier 'evil.conf') -eq $adsBefore)
    } else { Blocked 'SEC-INC-04' 'NTFS alternate data streams unavailable' }

    $junction = Join-Path $secConfigRoot 'theme-link'
    $mkArgs = '/d /s /c "mklink /J ""' + $junction + '"" ""' + $secOutside + '"""'
    $mk = Invoke-CapturedProcess $env:ComSpec $mkArgs '' @{} $Repo 5000
    $junctionReady = $mk.ExitCode -eq 0 -and [System.IO.Directory]::Exists($junction)
    $staticReparse = $source.IndexOf('FileAttributes]::ReparsePoint') -ge 0 -and $source.IndexOf('Test-NoReparseComponents $Path') -lt $source.IndexOf('ReadAllBytes($Path)')
    if ($junctionReady) {
        $linkAttrsBefore = [System.IO.File]::GetAttributes($junction)
        $sec05 = Join-Path $secConfigRoot 'sec-inc-05.conf'
        Write-Utf8 $sec05 "VL_SEGMENTS=model`nVL_CLOCK=off`n. theme-link/evil.conf`n"
        [void](Run-ModelColor 'SEC-INC-05 junction rejection' $sec05 '173' @{})
        $linkAttrsAfter = [System.IO.File]::GetAttributes($junction)
        Check 'SEC-INC-05 junction identity remains reparse point' (($linkAttrsBefore -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -and ($linkAttrsAfter -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        Check 'SEC-INC-05 outside canary unchanged' ((Snapshot-File $evil) -eq $evilBefore)
        Check 'SEC-INC-05 static no-follow ordering evidence' $staticReparse
    } else {
        Check 'SEC-INC-05 static no-follow ordering evidence' $staticReparse
        Blocked 'SEC-INC-05' 'junction creation capability unavailable'
    }
    Assert-NoUnexpectedResidue $secRoot 'SEC-INC matrix'

} finally {
    try { Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Stop } catch { }
    $cleanupOk = -not (Test-Path -LiteralPath $TempRoot)
}

Check 'finally removes the harness temp root' $cleanupOk
Write-Output "SUMMARY pass=$script:Pass fail=$script:Fail blocked=$script:Blocked"
if ($script:Fail -ne 0) { exit 1 }
exit 0
