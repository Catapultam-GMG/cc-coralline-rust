<#
  Regression tests for statusline.ps1 (issue #8: native PowerShell support
  without Git Bash). Mirrors the check()-per-assertion convention the bash
  tests in this directory use, translated to PowerShell.

  Run:
    powershell -NoProfile -File test/test-statusline-ps1.ps1

  Needs: git.exe on PATH (already required by statusline.sh's own git
  segment). No jq, no bash.
#>

$ErrorActionPreference = 'Continue'
$Here = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$Repo = Split-Path -Path $Here -Parent
$Script = Join-Path $Repo 'statusline.ps1'
$SampleInput = Join-Path $Here 'sample-input.json'

$script:fail = 0
function Check([string]$Name, [bool]$Cond) {
    if ($Cond) { Write-Output "ok    $Name" }
    else { Write-Output "FAIL  $Name"; $script:fail = 1 }
}

function Invoke-Statusline([string]$Json, [string]$ConfigPath, [string]$Cwd) {
    $prevConfig = $env:CORALLINE_CONFIG
    if ($ConfigPath) { $env:CORALLINE_CONFIG = $ConfigPath } else { Remove-Item Env:\CORALLINE_CONFIG -ErrorAction SilentlyContinue }
    $prevLoc = Get-Location
    if ($Cwd) { Set-Location -LiteralPath $Cwd }
    try {
        $out = $Json | & powershell -NoProfile -File $Script 2>&1
        return @{ Output = ($out -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
        Set-Location $prevLoc
        if ($prevConfig) { $env:CORALLINE_CONFIG = $prevConfig } else { Remove-Item Env:\CORALLINE_CONFIG -ErrorAction SilentlyContinue }
    }
}

# --- Case 1: default segments render from the shared sample-input.json -----
$sampleJson = Get-Content -LiteralPath $SampleInput -Raw
$r1 = Invoke-Statusline $sampleJson '' ''
Check 'exits 0 on the shared sample input' ($r1.ExitCode -eq 0)
Check 'dir segment shows the sample cwd' ($r1.Output -like '*projects/coralline*')
Check 'model segment shows the display name' ($r1.Output -like '*Fable 5*')
Check 'ctx segment shows the used percentage' ($r1.Output -like '*62%*')
Check '5h limit segment renders' ($r1.Output -like '*5h*')
Check '7d limit segment renders' ($r1.Output -like '*7d*')
Check 'cost segment renders' ($r1.Output -like '*$1.23*')
Check 'no PowerShell errors on stderr (git/jq/bash-free path)' ($r1.Output -notmatch 'Split-Path|ParameterBindingException|CommandNotFoundException')

# --- Case 2: VL_ASCII=1 swaps the gauge fill/empty glyphs, no crash --------
$h2 = Join-Path ([System.IO.Path]::GetTempPath()) ("coralline-ps1-$([guid]::NewGuid())")
New-Item -ItemType Directory -Path $h2 | Out-Null
$asciiConf = Join-Path $h2 'coralline.conf'
Set-Content -LiteralPath $asciiConf -Value @('VL_ASCII="1"', 'VL_SEGMENTS="ctx limit5h"') -Encoding UTF8
$r2 = Invoke-Statusline $sampleJson $asciiConf ''
Check 'ASCII mode exits 0' ($r2.ExitCode -eq 0)
Check 'ASCII mode uses # for the filled gauge' ($r2.Output -like '*#*')
Check 'ASCII mode uses - for the empty gauge' ($r2.Output -like '*-*')
Remove-Item -Recurse -Force $h2

# --- Case 3: missing config file falls back to the built-in defaults -------
$missingConf = Join-Path ([System.IO.Path]::GetTempPath()) ("coralline-ps1-missing-$([guid]::NewGuid()).conf")
$r3 = Invoke-Statusline $sampleJson $missingConf ''
Check 'missing config file does not error' ($r3.ExitCode -eq 0)
Check 'missing config file still renders the default segments' ($r3.Output -like '*Fable 5*')

# --- Case 4: malformed / empty stdin degrades to a clock-only render -------
$r4 = Invoke-Statusline '' '' ''
Check 'empty stdin exits 0' ($r4.ExitCode -eq 0)
$r5 = Invoke-Statusline 'not json {{{' '' ''
Check 'malformed stdin exits 0' ($r5.ExitCode -eq 0)

# --- Case 5: theme include (`. "path"`) resolves without a config-format
# change — same coralline.conf a bash install already wrote works here -----
$h5 = Join-Path ([System.IO.Path]::GetTempPath()) ("coralline-ps1-$([guid]::NewGuid())")
New-Item -ItemType Directory -Path $h5 | Out-Null
$themeConf = Join-Path $h5 'coralline.conf'
$draculaTheme = Join-Path $Repo 'themes\dracula.conf'
Set-Content -LiteralPath $themeConf -Value @(". `"$draculaTheme`"", 'VL_SEGMENTS="model"') -Encoding UTF8
$r6 = Invoke-Statusline $sampleJson $themeConf ''
Check 'theme include resolves and its color reaches the render' ($r6.Output -like '*38;2;189;147;249*')

Remove-Item -Recurse -Force $h5

# --- Case 6: git segment reflects a real repo (branch + dirty marker) ------
$h6 = Join-Path ([System.IO.Path]::GetTempPath()) ("coralline-ps1-git-$([guid]::NewGuid())")
New-Item -ItemType Directory -Path $h6 | Out-Null
Push-Location $h6
try {
    git init -q -b main .
    git config user.email test@example.com
    git config user.name test
    'one' | Set-Content -LiteralPath (Join-Path $h6 'a.txt')
    git add a.txt
    git commit -q -m 'init'
    $gitConf = Join-Path $h6 'coralline.conf'
    Set-Content -LiteralPath $gitConf -Value 'VL_SEGMENTS="git"' -Encoding UTF8
    # statusline.ps1 (like statusline.sh) reads cwd from the session JSON, not
    # from this process's own working directory, so the fixture repo must be
    # named there explicitly.
    $gitCwd = ($h6 -replace '\\', '/')
    $gitJson = "{`"cwd`":`"$gitCwd`"}"
    $rClean = Invoke-Statusline $gitJson $gitConf $h6
    Check 'git segment shows the branch name on a clean repo' ($rClean.Output -like '*main*')

    'two' | Add-Content -LiteralPath (Join-Path $h6 'a.txt')
    $rDirty = Invoke-Statusline $gitJson $gitConf $h6
    Check 'git segment marks a modified working tree' ($rDirty.Output -like '*main!*')
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $h6
}

if ($script:fail -eq 0) { Write-Output 'ALL PASS'; exit 0 }
Write-Output 'SOME FAILED'
exit 1
