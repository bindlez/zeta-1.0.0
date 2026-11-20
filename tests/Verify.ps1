<#
.SYNOPSIS
    Zeta verification suite. Dependency-free: runs on 5.1 and 7, no Pester required.

.DESCRIPTION
    Exercises the parts that can silently rot: theme parsing, ANSI emission, glyph fallback,
    layout maths, both git implementations (Rust and PowerShell), the frecency index, plugin
    loading, the Windows Terminal fragment and the diagnostics surface.

.EXAMPLE
    .\tests\Verify.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.ArrayList

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor DarkGreen
    }
    catch {
        $script:Failed++
        [void]$script:Failures.Add([pscustomobject]@{ Test = $Name; Error = $_.Exception.Message })
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        {0}" -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}

function Assert-True {
    param($Condition, [string]$Message = 'expected true')
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message = '')
    if ($Expected -ne $Actual) { throw ("expected [{0}] got [{1}] {2}" -f $Expected, $Actual, $Message) }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Message = '')
    if ($Text -notmatch $Pattern) { throw ("pattern /{0}/ not found in [{1}] {2}" -f $Pattern, $Text, $Message) }
}

function Remove-ZetaAnsi {
    param([string]$Text)
    $escaped = $Text -replace ([char]27 + '\[[0-9;]*[A-Za-z]'), ''
    # bash readline marks zero-width sequences with \[ \]; they are not visible text.
    return ($escaped -replace '\\\[|\\\]', '')
}

# --- environment ------------------------------------------------------------------
$root = Split-Path -Parent $PSScriptRoot
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("zeta-verify-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null

$env:ZETA_ROOT = Join-Path $temp 'data'
$env:ZETA_COLOR = 'truecolor'
$env:ZETA_GLYPHS = 'unicode'
$env:ZETA_WIDTH = '100'
$env:ZETA_NO_ASYNC = '1'
$env:LOCALAPPDATA = Join-Path $temp 'localappdata'
$env:ZETA_BASH_THEME_FILE = Join-Path $temp 'theme.bash'

Write-Host '== Zeta verification ==' -ForegroundColor Cyan
Write-Host ("  PowerShell {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) -ForegroundColor DarkGray

Import-Module (Join-Path $root 'src/Zeta.psd1') -Force
$module = Get-Module Zeta

# --- 1. module --------------------------------------------------------------------
Test-Case 'module imports and reports its version' {
    Assert-True ($null -ne $module) 'module not loaded'
    $version = & $module { $script:ZetaVersion }
    $manifest = Import-PowerShellDataFile (Join-Path $root 'src/Zeta.psd1')
    Assert-Equal ([string]$manifest.ModuleVersion) $version 'manifest and module version disagree'
}

Test-Case 'defaults are complete and mergeable' {
    $config = & $module { Get-ZetaConfig -Refresh }
    Assert-Equal 'zeta' $config.theme
    Assert-True ($config.plugins -contains 'core') 'core plugin missing from defaults'
    Assert-True ($config.cache.git -gt 0) 'git cache ttl missing'
}

# --- 2. themes --------------------------------------------------------------------
Test-Case 'every shipped theme parses with a valid palette' {
    $themes = @(Get-ZetaThemeList)
    Assert-True ($themes.Count -ge 6) ("expected >= 6 themes, found {0}" -f $themes.Count)
    foreach ($theme in $themes) {
        $loaded = & $module { param($n) Import-ZetaTheme -Name $n } $theme.Name
        Assert-True ($loaded.palette.ContainsKey('bg')) ("{0}: no bg" -f $theme.Name)
        Assert-Match '^#[0-9a-fA-F]{6}$' $loaded.palette.bg ("{0}: bg not hex" -f $theme.Name)
        Assert-True (@($loaded.prompt.left).Count -ge 2) ("{0}: empty layout" -f $theme.Name)
    }
}

Test-Case 'unknown theme falls back instead of throwing' {
    $theme = & $module { Import-ZetaTheme -Name 'does-not-exist' }
    Assert-Equal 'fallback' $theme.name
}

# --- 3. colour pipeline -----------------------------------------------------------
Test-Case 'truecolor emits 24-bit SGR' {
    $ansi = & $module { ConvertTo-ZetaAnsi -Hex '#ff0000' -Mode 'truecolor' }
    Assert-Equal ([char]27 + '[38;2;255;0;0m') $ansi
    $bg = & $module { ConvertTo-ZetaAnsi -Hex '#00ff00' -Background -Mode 'truecolor' }
    Assert-Equal ([char]27 + '[48;2;0;255;0m') $bg
}

Test-Case '256 and 16 colour modes quantise' {
    $c256 = & $module { ConvertTo-ZetaAnsi -Hex '#7aa2f7' -Mode '256' }
    Assert-Match '\[38;5;\d+m' $c256
    $c16 = & $module { ConvertTo-ZetaAnsi -Hex '#7aa2f7' -Mode '16' }
    Assert-Match '\[(3|9|4|10)\d+m' $c16
}

Test-Case 'colour mode none emits nothing' {
    $none = & $module { ConvertTo-ZetaAnsi -Hex '#ffffff' -Mode 'none' }
    Assert-Equal '' $none
}

Test-Case 'glyph tiers degrade nerd -> unicode -> ascii' {
    $nerd = & $module { $env:ZETA_GLYPHS = 'nerd'; Get-ZetaGlyph -Name 'separator' }
    $uni = & $module { $env:ZETA_GLYPHS = 'unicode'; Get-ZetaGlyph -Name 'separator' }
    $ascii = & $module { $env:ZETA_GLYPHS = 'ascii'; Get-ZetaGlyph -Name 'separator' }
    Assert-Equal ([string][char]0xE0B0) $nerd
    Assert-Equal ([string][char]0x203A) $uni
    Assert-Equal '>' $ascii
    $env:ZETA_GLYPHS = 'unicode'
}

# --- 4. rendering ------------------------------------------------------------------
Test-Case 'prompt renders two lines, no escape leakage' {
    $rendered = & $module { Write-ZetaPrompt -Capture }
    $lines = $rendered -split "`n"
    Assert-Equal 2 $lines.Count ("expected 2 lines, got {0}" -f $lines.Count)
    $plain = Remove-ZetaAnsi $rendered
    Assert-True ($plain -notmatch 'e\[') 'literal "e[" leaked into output (5.1 escape bug)'
    Assert-Match '\u276F|\>' $plain 'prompt arrow missing'
}

Test-Case 'every theme renders without throwing' {
    foreach ($theme in @(Get-ZetaThemeList)) {
        $output = & $module { param($n) $script:ZetaConfigCache = $null; Set-ZetaTheme -Name $n | Out-Null; Write-ZetaPrompt -Capture } $theme.Name
        Assert-True ($output.Length -gt 0) ("{0}: empty render" -f $theme.Name)
    }
    & $module { Set-ZetaTheme -Name 'zeta' | Out-Null }
}

Test-Case 'NO_COLOR produces plain text' {
    $previous = $env:ZETA_COLOR
    $env:ZETA_COLOR = 'none'
    try {
        $plain = & $module { Write-ZetaPrompt -Capture }
        Assert-True ($plain.IndexOf([char]27) -lt 0) 'escape emitted with colour disabled'
    }
    finally { $env:ZETA_COLOR = $previous }
}

Test-Case 'layout respects a narrow width' {
    $previous = $env:ZETA_WIDTH
    $env:ZETA_WIDTH = '40'
    try {
        $narrow = Remove-ZetaAnsi (& $module { Write-ZetaPrompt -Capture })
        foreach ($line in ($narrow -split "`n")) {
            Assert-True ($line.Length -le 40) ("line is {0} chars (>40): {1}" -f $line.Length, $line)
        }
    }
    finally { $env:ZETA_WIDTH = $previous }
}

Test-Case 'failed commands surface in the prompt' {
    $ok = & $module { param($s) Write-ZetaPrompt -Capture -Success $s } $false
    $plainFailed = Remove-ZetaAnsi $ok
    $okNow = & $module { Write-ZetaPrompt -Capture -Success $true }
    $plainOk = Remove-ZetaAnsi $okNow
    Assert-True ($plainFailed.Length -gt 0) 'failed render empty'
    Assert-True ($plainFailed -ne $plainOk) 'exit status did not change the prompt'
}

Test-Case 'durations format sensibly' {
    $formatted = & $module { Format-ZetaDuration -Milliseconds 1500 }
    Assert-Equal '1.50s' $formatted
    $fast = & $module { Format-ZetaDuration -Milliseconds 250 }
    Assert-Equal '250ms' $fast
}

# --- 5. git sensor: both implementations -------------------------------------------
$repo = Join-Path $temp 'demo-repo'
New-Item -ItemType Directory -Path $repo -Force | Out-Null
Push-Location $repo
try {
    & git init -q 2>$null
    'first' | Set-Content -LiteralPath (Join-Path $repo 'a.txt') -Encoding UTF8
    & git -c 'user.email=test@zeta.local' -c 'user.name=Zeta Test' add . 2>$null
    & git -c 'user.email=test@zeta.local' -c 'user.name=Zeta Test' commit -qm 'init' 2>$null
    'second' | Add-Content -LiteralPath (Join-Path $repo 'a.txt') -Encoding UTF8
    'new' | Set-Content -LiteralPath (Join-Path $repo 'b.txt') -Encoding UTF8
}
finally { Pop-Location }

$expectedBranch = (& git -C $repo rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)

Test-Case 'git sensor (rust) reports branch and dirty counts' {
    $core = & $module { Get-ZetaCorePath }
    if (-not $core) { throw 'zeta-core not built - run build.ps1 first (this test asserts the native path)' }
    $state = & $module { param($p) Get-ZetaSensorGit -Arguments @{ Path = $p } } $repo
    Assert-Equal $expectedBranch $state.Branch
    Assert-True ($state.Modified -ge 1) ('modified count: {0}' -f $state.Modified)
    Assert-True ($state.Untracked -ge 1) ('untracked count: {0}' -f $state.Untracked)
    Assert-True (-not $state.Clean) 'repo should be dirty'
}

Test-Case 'git sensor (powershell fallback) agrees with the native one' {
    $native = & $module { param($p) Get-ZetaSensorGit -Arguments @{ Path = $p } } $repo
    $env:ZETA_NO_CORE = '1'
    try {
        $fallback = & $module { param($p) Get-ZetaSensorGit -Arguments @{ Path = $p } } $repo
    }
    finally { Remove-Item Env:\ZETA_NO_CORE -ErrorAction SilentlyContinue }

    Assert-Equal $native.Branch $fallback.Branch 'branch mismatch'
    Assert-Equal $native.Modified $fallback.Modified 'modified mismatch'
    Assert-Equal $native.Untracked $fallback.Untracked 'untracked mismatch'
}

Test-Case 'git sensor is empty outside a repository' {
    $outside = Join-Path $temp 'not-a-repo'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    $state = & $module { param($p) Get-ZetaSensorGit -Arguments @{ Path = $p } } $outside
    Assert-True (-not $state.Repo) 'detected a repo where there is none'
}

# --- 6. frecency -------------------------------------------------------------------
Test-Case 'frecency index ranks by recency and frequency' {
    [void](& $module { Initialize-ZetaPlugins })
    $deep = Join-Path $temp 'projects/zeta-core'
    New-Item -ItemType Directory -Path $deep -Force | Out-Null

    $core = & $module { Get-ZetaCorePath }
    if ($core) { & $core z add --path $deep | Out-Null }
    & $module { param($p) Add-ZetaZVisit -Path $p } $deep

    $ranked = & $module { Get-ZetaZRanked -Term 'zeta-core' -Limit 5 }
    Assert-True (@($ranked).Count -ge 1) 'no frecency results'
    Assert-Match 'zeta-core' (@($ranked)[0].Path)
}

Test-Case 'frecency ignores directories that no longer exist' {
    $ghost = Join-Path $temp 'ghost-dir'
    New-Item -ItemType Directory -Path $ghost -Force | Out-Null
    & $module { param($p) Add-ZetaZVisit -Path $p } $ghost
    Remove-Item -LiteralPath $ghost -Recurse -Force
    $ranked = @(& $module { Get-ZetaZRanked -Term 'ghost-dir' -Limit 5 })
    Assert-Equal 0 $ranked.Count 'deleted directory still ranked'
}

# --- 7. plugins --------------------------------------------------------------------
Test-Case 'plugin inventory is discoverable' {
    $plugins = @(Get-ZetaPlugin)
    Assert-True ($plugins.Count -ge 8) ("expected >= 8 plugins, found {0}" -f $plugins.Count)
    Assert-True (@($plugins | Where-Object { $_.Name -eq 'z' }).Count -eq 1) 'z plugin missing'
}

Test-Case 'enabling a plugin defines its commands' {
    $loaded = Enable-ZetaPlugin -Name 'clip' -Confirm:$false
    Assert-True $loaded 'clip plugin failed to load'
    Assert-True ($null -ne (Get-Command -Name 'copypath' -ErrorAction SilentlyContinue)) 'copypath not defined'
}

Test-Case 'plugin helpers land in module scope, not a discarded child scope' {
    & $module { Initialize-ZetaPlugins } | Out-Null
    $found = & $module { [bool](Get-Command -Name 'Get-ZetaZRanked' -ErrorAction SilentlyContinue) }
    Assert-True $found 'z helpers missing from module scope'
}

Test-Case 'completion defaults to classic Tab cycling' {
    $state = Get-ZetaCompletion
    Assert-Equal 'tab' $state.Mode
    Assert-True ($state.PSObject.Properties['PredictiveSupported']) 'no capability flag'
}

Test-Case 'menu mode binds Tab to the dropdown and Shift+Tab to cycling' {
    $result = Set-ZetaCompletion -Mode 'menu' -Confirm:$false
    Assert-Equal 'menu' $result.Mode
    $live = Get-ZetaCompletion
    Assert-Equal 'MenuComplete' $live.Tab ('Tab is {0}' -f $live.Tab)
    Assert-Equal 'Complete' $live.ShiftTab ('Shift+Tab is {0}' -f $live.ShiftTab)
}

Test-Case 'switching back restores classic Tab completion' {
    [void](Set-ZetaCompletion -Mode 'tab' -Confirm:$false)
    $live = Get-ZetaCompletion
    Assert-Equal 'Complete' $live.Tab
    Assert-Equal 'MenuComplete' $live.ShiftTab
}

Test-Case 'the choice persists to config.json' {
    [void](Set-ZetaCompletion -Mode 'menu' -Confirm:$false)
    $saved = Get-Content -LiteralPath (Join-Path $env:ZETA_ROOT 'config.json') -Raw | ConvertFrom-Json
    Assert-Equal 'menu' $saved.features.completion
    [void](Set-ZetaCompletion -Mode 'tab' -Confirm:$false)
}

Test-Case 'predictive mode refuses to lie about unsupported PSReadLine' {
    if (-not (& $module { Test-ZetaPredictiveSupport })) {
        $threw = $false
        try { Set-ZetaCompletion -Mode 'predictive' -Confirm:$false | Out-Null } catch { $threw = $true }
        Assert-True $threw 'expected a terminating error on PSReadLine 2.0'
        $live = Get-ZetaCompletion
        Assert-Equal 'tab' $live.Mode 'mode must not change when the request fails'
    }
}

Test-Case 'predictive mode is accepted where PSReadLine supports it' {
    if (& $module { Test-ZetaPredictiveSupport }) {
        $result = Set-ZetaCompletion -Mode 'predictive' -Confirm:$false -WarningAction SilentlyContinue
        Assert-Equal 'predictive' $result.Mode
        Assert-Equal 'MenuComplete' $result.Tab 'predictive must still give a dropdown on Tab'
        $state = Get-ZetaCompletion
        Assert-True ($state.PSObject.Properties['PredictionSource']) 'PredictionSource missing from state'
        [void](Set-ZetaCompletion -Mode 'tab' -Confirm:$false)
    }
}

Test-Case 'syntax highlighting accepts palette colours on this PSReadLine' {
    $theme = & $module { param($n) Import-ZetaTheme -Name $n } 'zeta'
    $applied = & $module { param($t) Set-ZetaSyntaxColors -Theme $t } $theme
    Assert-True $applied 'PSReadLine rejected the palette (hex must be used, not a 5.1-literal ANSI string)'
    $rejectedEmpty = & $module { Set-ZetaSyntaxColors -Theme $null }
    Assert-True (-not $rejectedEmpty) 'null theme should not report success'
}

Test-Case 'shell inventory reports what is installed' {
    $shells = @(Get-ZetaShell)
    Assert-True ($shells.Count -ge 3) 'expected pwsh / powershell / bash entries'
    $bashEntry = @($shells | Where-Object { $_.Name -eq 'bash' })[0]
    Assert-True ($null -ne $bashEntry) 'no bash entry'
    if (Test-Path 'C:\Program Files\Git\bin\bash.exe') {
        Assert-True $bashEntry.Available 'Git Bash exists but was not discovered'
        Assert-Match 'Git\\bin\\bash\.exe$' $bashEntry.Path
    }
}

Test-Case 'generated bash rcfile is real bash syntax' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $rc = & $module { param($t) New-ZetaBashRcFile -TokenPosix $t } '/c/temp/zeta-token.txt'
    try {
        Assert-True (Test-Path -LiteralPath $rc) 'rcfile not written'
        & $bash -n $rc
        Assert-Equal 0 $LASTEXITCODE 'bash -n rejected the generated rcfile'
    }
    finally { Remove-Item -LiteralPath (Split-Path -Parent $rc) -Recurse -Force -ErrorAction SilentlyContinue }
}

Test-Case 'bash handoff records the directory it ended in, and it converts back' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $cwdFile = Join-Path $env:TEMP ('zeta-cwd-' + [guid]::NewGuid().ToString('N') + '.txt')
    $posixCwd = & $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $cwdFile
    $rc = & $module { param($t) New-ZetaBashRcFile -TokenPosix $t } $posixCwd
    try {
        $target = 'C:\Windows'
        $posixTarget = & $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $target
        $previousEap = $ErrorActionPreference
        try {
            # 5.1 turns a native command's stderr into a terminating error when EAP=Stop.
            $ErrorActionPreference = 'Continue'
            & $bash --rcfile $rc -i -c "cd '$posixTarget' && exit 0" 2>&1 | Out-Null
        }
        finally { $ErrorActionPreference = $previousEap }
        Assert-True (Test-Path -LiteralPath $cwdFile) 'bash did not write the cwd file on exit'
        $recorded = (Get-Content -LiteralPath $cwdFile -Raw).Trim()
        $back = & $module { param($p) ConvertFrom-ZetaPosixPath -Path $p } $recorded
        Assert-Equal $target $back 'posix -> windows conversion lost the directory'
    }
    finally {
        Remove-Item -LiteralPath $cwdFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Split-Path -Parent $rc) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'windows terminal tab arguments target the same directory' {
    $arguments = & $module { Get-ZetaShellTabArguments -Name 'bash' -Path 'C:\Windows' }
    Assert-Equal 'new-tab' $arguments[2]
    Assert-Equal '-d' $arguments[3]
    Assert-Equal 'C:\Windows' $arguments[4]
    Assert-True ($arguments -contains 'Zeta Bash') 'tab title missing'
}

Test-Case 'missing Git Bash produces an actionable error' {
    $previous = $env:ZETA_BASH_PATH
    $env:ZETA_BASH_PATH = 'C:\definitely\not\bash.exe'
    try {
        $threw = $false
        $message = ''
        try { Enter-ZetaShell -Name 'bash' } catch { $threw = $true; $message = $_.Exception.Message }
        Assert-True $threw 'expected a terminating error'
        Assert-Match 'winget install' $message 'error does not tell the user how to fix it'
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:\ZETA_BASH_PATH -ErrorAction SilentlyContinue }
        else { $env:ZETA_BASH_PATH = $previous }
    }
}

Test-Case 'bash half of the theme is generated and valid' {
    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'tokyo-night' }
    Assert-True (Test-Path -LiteralPath $themeFile) 'theme.bash not written'
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    & $bash -n (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile)
    Assert-Equal 0 $LASTEXITCODE 'bash rejected the generated theme file'
    $content = Get-Content -LiteralPath $themeFile -Raw
    Assert-Match "ZETA_THEME='tokyo-night'" $content
    Assert-Match 'ZETA_SEG_dir_BG=' $content
}

Test-Case 'bash and PowerShell render the same prompt text' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }

    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'zeta' }
    $runtime = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Shell/zeta.bash'
    $corePath = & $module { Get-ZetaCorePath }

    $script = @'
export ZETA_THEME_FILE='__THEME__'
export ZETA_CORE='__CORE__'
export ZETA_WIDTH=100
export COLUMNS=100
. '__RUNTIME__'
__zeta_build_prompt
printf '%s' "$PS1"
'@
    $script = $script.Replace('__THEME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile))
    $script = $script.Replace('__RUNTIME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $runtime))
    $script = $script.Replace('__CORE__', $(if ($corePath) { & $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $corePath } else { '' }))

    $probe = Join-Path $env:TEMP ('zeta-parity-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($probe, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $bashOut = (& $bash (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null) -join "`n"
        $previousWidth = $env:ZETA_WIDTH
        $previousColor = $env:ZETA_COLOR
        $env:ZETA_WIDTH = '100'
        $env:ZETA_COLOR = 'truecolor'
        try {
            $psOut = & $module { $script:ZetaConfigCache = $null; Set-ZetaTheme -Name 'zeta' -Confirm:$false | Out-Null; Write-ZetaPrompt -Capture }
        }
        finally {
            $env:ZETA_WIDTH = $previousWidth
            $env:ZETA_COLOR = $previousColor
        }

        Assert-Equal (Remove-ZetaAnsi $psOut) (Remove-ZetaAnsi $bashOut) 'bash and PowerShell prompts diverged'
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

Test-Case 'zeta exists inside bash and lists themes' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $runtime = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Shell/zeta.bash'
    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'zeta' }
    $themesDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Themes'

    $script = @'
export ZETA_THEME_FILE='__THEME__'
export ZETA_THEMES_DIR='__THEMES__'
export ZETA_WIDTH=80
. '__RUNTIME__'
type -t zeta
type -t __zeta_precmd
zeta theme list
'@
    $script = $script.Replace('__THEME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile))
    $script = $script.Replace('__THEMES__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themesDir))
    $script = $script.Replace('__RUNTIME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $runtime))

    $probe = Join-Path $env:TEMP ('zeta-bashcmd-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($probe, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $lines = @(& $bash (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null)
        Assert-Equal 'function' $lines[0] 'zeta is not a bash function'
        Assert-Equal 'function' $lines[1] 'prompt hook missing'
        $listed = @($lines | Where-Object { $_ -match '^  [a-z]' })
        Assert-True ($listed.Count -ge 6) ('themes listed in bash: {0}' -f $listed.Count)
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

Test-Case 'theme change republishes the bash view' {
    [void](Set-ZetaTheme -Name 'nord' -Confirm:$false)
    try {
        $themeFile = $env:ZETA_BASH_THEME_FILE
        Assert-True $themeFile 'test did not redirect the bash theme path'
        $content = Get-Content -LiteralPath $themeFile -Raw
        Assert-Match "ZETA_THEME='nord'" $content 'bash view still shows the old theme'
    }
    finally { [void](Set-ZetaTheme -Name 'zeta' -Confirm:$false) }
}

Test-Case 'generated rcfile boots the bash runtime with the theme' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }

    $rc = & $module {
        $themeFile = Export-ZetaBashTheme -ThemeName 'gruvbox-dark'
        $runtime = Join-Path $script:ModuleRoot 'Shell/zeta.bash'
        $envt = @{
            ZETA_VERSION    = $script:ZetaVersion
            ZETA_THEME_FILE = (ConvertTo-ZetaPosixPath -Path $themeFile)
            ZETA_RUNTIME    = (ConvertTo-ZetaPosixPath -Path $runtime)
            ZETA_THEMES_DIR = (ConvertTo-ZetaPosixPath -Path (Join-Path $script:ModuleRoot 'Themes'))
        }
        New-ZetaBashRcFile -TokenPosix '/c/temp/zeta-rc-token.txt' -Environment $envt -RuntimePosix $envt['ZETA_RUNTIME']
    }

    $probe = Join-Path $env:TEMP ('zeta-rc-' + [Guid]::NewGuid().ToString('N') + '.sh')
    $probeContent = @'
printf '%s|%s' "$ZETA_THEME" "$(type -t zeta)"
'@
    [System.IO.File]::WriteAllText($probe, $probeContent.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $previousEap = $ErrorActionPreference
        try {
            # 5.1 turns bash's job-control chatter into a terminating error when EAP=Stop.
            $ErrorActionPreference = 'Continue'
            $line = (& $bash --rcfile (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $rc) -i (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null) -join ''
        }
        finally { $ErrorActionPreference = $previousEap }
        Assert-Match '^gruvbox-dark\|function' $line
    }
    finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        # Put the bash view back on the active theme, otherwise the next prompt would disagree.
        & $module { Export-ZetaBashTheme | Out-Null }
    }
}

Test-Case 'bash profile hook is idempotent and keeps user lines' {
    $temp = Join-Path $env:TEMP ('bashrc-' + [Guid]::NewGuid().ToString('N') + '.sh')
    Set-Content -LiteralPath $temp -Value "# user line`nalias ll='ls -l'" -Encoding ASCII
    try {
        & $module { param($p) Install-ZetaBashProfile -Path $p | Out-Null } $temp
        $first = Get-Content -LiteralPath $temp -Raw
        & $module { param($p) Install-ZetaBashProfile -Path $p | Out-Null } $temp
        $second = Get-Content -LiteralPath $temp -Raw

        Assert-Equal $first $second 're-install rewrote the file'
        Assert-Match "alias ll='ls -l'" $second 'user lines were lost'
        Assert-Equal 1 ([regex]::Matches($second, [regex]::Escape('# >>> zeta initialize >>>')).Count) 'duplicate blocks'

        $bash = & $module { Get-ZetaBashPath }
        if ($bash) {
            & $bash -n (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $temp)
            Assert-Equal 0 $LASTEXITCODE 'bash -n rejected the hooked .bashrc'
        }
    }
    finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}

Test-Case 'split view opens the other shell in the same directory' {
    $arguments = & $module { Get-ZetaShellSplitArguments -Name 'bash' -Path 'C:\Windows' }
    Assert-Equal 'split-pane' $arguments[2]
    Assert-Equal '-V' $arguments[3]
    Assert-Equal '-d' $arguments[4]
    Assert-Equal 'C:\Windows' $arguments[5]
    Assert-True ($arguments -contains 'Zeta Bash') 'pane title missing'

    $horizontal = & $module { Get-ZetaShellSplitArguments -Name 'pwsh' -Path 'C:\Windows' -Horizontal }
    Assert-Equal '-H' $horizontal[3]
}

Test-Case 'shell handoff diagnostic is green on this machine' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $checks = @(Test-ZetaShellHandoff)
    Assert-True ($checks.Count -ge 5) 'too few links checked'
    $failed = @($checks | Where-Object { $_.Status -eq 'fail' })
    Assert-Equal 0 $failed.Count (($failed | ForEach-Object { "$($_.Check): $($_.Detail)" }) -join '; ')
}

Test-Case 'studio serves, saves and republishes the theme' {
    $studio = $null
    try {
        $studio = Start-ZetaThemeStudio -NoBrowser
        Assert-True ($null -ne $studio) 'studio did not start'

        $state = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/state?token={1}" -f $studio.Port, $studio.Token) -TimeoutSec 5
        Assert-True (@($state.themes).Count -ge 6) 'theme list missing'

        $payload = @{ name = 'studio-test'; palette = @{ accent = '#ff2e97'; bg = '#101018' } } | ConvertTo-Json -Depth 5
        $saved = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/save?token={1}" -f $studio.Port, $studio.Token) -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 5
        Assert-True $saved.ok 'save rejected'
        Assert-True (Test-Path -LiteralPath $saved.path) 'theme file not written'

        $bashTheme = Get-Content -LiteralPath $env:ZETA_BASH_THEME_FILE -Raw
        Assert-Match "ZETA_THEME='studio-test'" $bashTheme 'bash view was not recompiled'

        $activateBody = @{ name = 'studio-test' } | ConvertTo-Json
        $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/activate?token={1}" -f $studio.Port, $studio.Token) -Method Post -ContentType 'application/json' -Body $activateBody -TimeoutSec 5
        Assert-Equal 'studio-test' (& $module { (Get-ZetaConfig -Refresh).theme }) 'activate did not persist'
    }
    finally {
        Stop-ZetaThemeStudio
        [void](Set-ZetaTheme -Name 'zeta' -Confirm:$false)
        Remove-Item -LiteralPath (Join-Path (Join-Path $env:ZETA_ROOT 'themes') 'studio-test.json') -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'bash accepts pwsh as a way back to PowerShell' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'zeta' }
    $runtime = (Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Shell/zeta.bash')).Path

    $script = @'
export ZETA_THEME_FILE='__THEME__'
export ZETA_WIDTH=100
. '__RUNTIME__'
zeta shell pwsh
echo "STILL_IN_BASH"
'@
    $script = $script.Replace('__THEME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile))
    $script = $script.Replace('__RUNTIME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $runtime))

    $probe = Join-Path $env:TEMP ('zeta-pwsh-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($probe, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $out = (& $bash (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null) -join "`n"
        }
        finally { $ErrorActionPreference = $previousEap }
        Assert-True ($out -notmatch 'STILL_IN_BASH') 'zeta shell pwsh fell through instead of leaving bash'
        Assert-Match 'leaving bash' $out
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

Test-Case 'bash prompt inspector reports a sane PS1' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'zeta' }
    $runtime = (Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Shell/zeta.bash')).Path

    $script = @'
export ZETA_THEME_FILE='__THEME__'
export ZETA_WIDTH=100
export COLUMNS=100
. '__RUNTIME__'
__zeta_build_prompt
zeta shell inspect
'@
    $script = $script.Replace('__THEME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile))
    $script = $script.Replace('__RUNTIME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $runtime))

    $probe = Join-Path $env:TEMP ('zeta-inspect-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($probe, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $out = (& $bash (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null) -join "`n"
        }
        finally { $ErrorActionPreference = $previousEap }

        Assert-Match 'lines     : 1' $out 'PS1 should contain exactly one newline'
        # Balanced markers are what stop readline from mangling the redraw.
        $markers = [regex]::Match($out, 'markers   : (\d+) open / (\d+) close')
        Assert-True $markers.Success 'inspector did not report markers'
        Assert-Equal $markers.Groups[1].Value $markers.Groups[2].Value 'unbalanced \[ \] markers'
    }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

Test-Case 'bash z jumps using the shared frecency index' {
    $bash = & $module { Get-ZetaBashPath }
    if (-not $bash) { return }
    $core = & $module { Get-ZetaCorePath }
    if (-not $core) { return }

    $leaf = 'zeta-z-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $target = Join-Path $env:TEMP $leaf
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    & $core z add --path $target | Out-Null

    $runtime = (Resolve-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Shell/zeta.bash')).Path
    $themeFile = & $module { Export-ZetaBashTheme -ThemeName 'zeta' }
    $script = @'
export ZETA_CORE='__CORE__'
export ZETA_THEME_FILE='__THEME__'
export ZETA_WIDTH=80
. '__RUNTIME__'
cd /c
z __LEAF__
pwd
'@
    $script = $script.Replace('__CORE__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $core))
    $script = $script.Replace('__THEME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $themeFile))
    $script = $script.Replace('__RUNTIME__', (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $runtime))
    $script = $script.Replace('__LEAF__', $leaf)

    $probe = Join-Path $env:TEMP ('zeta-z-' + [Guid]::NewGuid().ToString('N') + '.sh')
    [System.IO.File]::WriteAllText($probe, $script.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    try {
        $previousEap = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $out = (& $bash (& $module { param($p) ConvertTo-ZetaPosixPath -Path $p } $probe) 2>$null) -join "`n"
        }
        finally { $ErrorActionPreference = $previousEap }
        Assert-Match $leaf $out 'bash z did not land in the recorded directory'
    }
    finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'split refuses to pretend outside Windows Terminal' {
    $arguments = Open-ZetaShellSplit -Name 'bash' -WhatIf
    Assert-Equal 'split-pane' $arguments[2]

    if (-not $env:WT_SESSION) {
        $threw = $false
        $message = ''
        try { Open-ZetaShellSplit -Name 'bash' -Confirm:$false | Out-Null }
        catch { $threw = $true; $message = $_.Exception.Message }
        Assert-True $threw 'split silently did nothing outside Windows Terminal'
        Assert-Match 'Windows Terminal' $message 'error does not say what to do'
    }
}

Test-Case 'studio supports save-as, info and delete' {
    $studio = $null
    try {
        $studio = Start-ZetaThemeStudio -NoBrowser -Theme 'nord'
        Assert-Match 'theme=nord' $studio.Url 'theme edit did not preselect the theme'

        $payload = @{ name = 'studio-as'; palette = @{ accent = '#00ff00' } } | ConvertTo-Json -Depth 5
        $saved = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/save?token={1}" -f $studio.Port, $studio.Token) -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 5
        Assert-True $saved.ok 'save-as rejected'

        $info = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/info?name=studio-as&token={1}" -f $studio.Port, $studio.Token) -TimeoutSec 5
        Assert-Equal 'user' $info.source
        $builtin = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/info?name=zeta&token={1}" -f $studio.Port, $studio.Token) -TimeoutSec 5
        Assert-Equal 'builtin' $builtin.source

        $blocked = $false
        try {
            $body = @{ name = 'zeta' } | ConvertTo-Json
            $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/delete?token={1}" -f $studio.Port, $studio.Token) -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
        }
        catch { $blocked = $true }
        Assert-True $blocked 'a built-in theme was deletable'

        $body = @{ name = 'studio-as' } | ConvertTo-Json
        $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/delete?token={1}" -f $studio.Port, $studio.Token) -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5
        Assert-True (-not (Test-Path -LiteralPath $saved.path)) 'user theme file survived delete'
    }
    finally { Stop-ZetaThemeStudio }
}

# --- 8. terminal fragment ----------------------------------------------------------
Test-Case 'windows terminal fragment is valid JSON with a scheme' {
    $path = & $module { Write-ZetaTerminalFragment -ThemeName 'tokyo-night' }
    Assert-True (Test-Path -LiteralPath $path) 'fragment not written'
    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Assert-Equal 'Zeta tokyo-night' $json.schemes[0].name
    Assert-Match '^#[0-9a-fA-F]{6}$' $json.schemes[0].background
    Assert-Equal 'Zeta - tokyo-night' $json.profiles[0].name
}

# --- 9. diagnostics ----------------------------------------------------------------
Test-Case 'doctor returns structured checks' {
    $report = Invoke-ZetaDoctor -Json
    Assert-True (@($report.checks).Count -ge 8) 'too few checks'
    Assert-True ($null -ne $report.version) 'no version in report'
}

Test-Case 'benchmark returns stable timings' {
    $result = Measure-ZetaPrompt -Count 5
    Assert-True ($result.AvgMs -ge 0) 'negative average'
    Assert-Equal 5 $result.Samples
}

# --- summary -----------------------------------------------------------------------
Write-Host ''
$color = 'Green'
if ($script:Failed -gt 0) { $color = 'Red' }
Write-Host ("{0} passed, {1} failed, {2} total" -f $script:Passed, $script:Failed, ($script:Passed + $script:Failed)) -ForegroundColor $color

if ($script:Failed -gt 0) {
    Write-Host ''
    foreach ($failure in $script:Failures) {
        Write-Host ("  {0}" -f $failure.Test) -ForegroundColor Red
        Write-Host ("    {0}" -f $failure.Error) -ForegroundColor DarkRed
    }
}

# Cleanup: only the temp directory this script created.
try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { }

if ($script:Failed -gt 0) { exit 1 }
exit 0


