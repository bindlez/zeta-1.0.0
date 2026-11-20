# Prompt writer. Keep this file allocation-light: it runs before every command.

$script:ZetaCommandStart = $null
$script:ZetaLastDurationMs = 0
$script:ZetaLastExitCode = 0
$script:ZetaLastRenderMs = 0
$script:ZetaHooksInstalled = $false
$script:ZetaTitleCache = ''
$script:ZetaPromptRendered = $false
$script:ZetaVisitHook = $null
$script:ZetaLastVisitPath = ''
$script:ZetaLeftCache = $null

function Get-ZetaPromptState {
    param([int]$ExitCode = 0, [double]$DurationMs = 0)

    $config = Get-ZetaConfig
    $path = (Get-Location).Path

    $gitKey = "git|$path"
    $git = Get-ZetaCached -Key $gitKey -Sensor 'git' -Arguments @{ Path = $path } -Ttl $config.cache.git -Fallback $null

    $langsKey = "langs|$path"
    $langs = Get-ZetaCached -Key $langsKey -Sensor 'langs' -Arguments @{ Path = $path } -Ttl $config.cache.langs -Fallback $null

    $kube = $null
    if ([bool]$env:KUBECONFIG -or (Test-Path -LiteralPath (Join-Path $HOME '.kube/config') -ErrorAction SilentlyContinue)) {
        $kube = Get-ZetaCached -Key 'kube' -Sensor 'kube' -Ttl $config.cache.kube -Fallback $null
    }

    $battery = $null
    if (-not $env:ZETA_NO_BATTERY) {
        $battery = Get-ZetaCached -Key 'battery' -Sensor 'battery' -Ttl 60000 -Fallback $null
    }

    return @{
        Path       = $path
        ExitCode   = $ExitCode
        DurationMs = $DurationMs
        Git        = $git
        Langs      = $langs
        Kube       = $kube
        Battery    = $battery
        HistoryId  = 0
        Config     = $config
    }
}

function Get-ZetaPromptCells {
    param(
        [object[]]$Entries,
        [hashtable]$Theme,
        [hashtable]$State
    )

    $cells = @()
    if (-not $Entries) { return $cells }
    foreach ($entry in $Entries) {
        if (-not $entry) { continue }
        $id = [string]$entry.segment
        if (-not $id) { continue }
        $cell = Get-ZetaSegmentCell -Id $id -Entry (ConvertTo-ZetaHashtable $entry) -Theme $Theme -State $State
        if ($cell -and $cell.Text) { $cells += $cell }
    }
    return $cells
}

function Format-ZetaTransientLine {
    <#
    .SYNOPSIS
        Compact replacement for the previous prompt line (experimental).
    #>
    param([hashtable]$Theme, [hashtable]$State)

    $mode = Get-ZetaAnsiMode
    $arrow = Get-ZetaGlyph 'prompt'
    $dir = Get-ZetaDisplayPath -Path $State.Path -MaxSegments 2 -Shorten
    $accent = Get-ZetaToneColor -Theme $Theme -Tone 'accent'
    if ($mode -eq 'none') { return "$arrow $dir" }
    return ('{0}{1}{2} {3}{0}' -f ($script:ZetaEsc + '[0m'), (ConvertTo-ZetaAnsi -Hex $accent -Mode $mode), $arrow, $dir)
}

function Get-ZetaPromptSignature {
    <#
    .SYNOPSIS
        Fingerprint of everything the LEFT line depends on. If it matches, the rendered
        string is reused verbatim - this is what keeps warm renders in the low milliseconds.
    #>
    param(
        [hashtable]$State,
        [hashtable]$Theme,
        [int]$Width,
        [string]$Mode,
        [int]$RightReserve
    )

    $git = ''
    if ($State.Git -and $State.Git.Repo) {
        $git = '{0},{1},{2},{3},{4},{5},{6},{7}' -f $State.Git.Branch, $State.Git.Ahead, $State.Git.Behind, $State.Git.Staged, $State.Git.Modified, $State.Git.Untracked, $State.Git.Conflict, $State.Git.Stash
    }
    $langs = ''
    if ($State.Langs) { $langs = (@($State.Langs | ForEach-Object { "$($_.Name):$($_.Version)" }) -join ',') }

    return ('{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}|{12}|{13}' -f `
            $Theme.name, $Mode, $Width, $RightReserve, $State.Path, $State.ExitCode, $git, $langs,
        $State.Kube, $env:VIRTUAL_ENV, $env:AWS_PROFILE, $env:DOCKER_CONTEXT, (Test-ZetaElevated), (Get-ZetaGlyphTier))
}

function Write-ZetaPrompt {
    param([switch]$Force, [switch]$Capture, [bool]$Success = $true)

    $config = Get-ZetaConfig
    $theme = Import-ZetaTheme -Name $config.theme
    $mode = Get-ZetaAnsiMode
    $width = Get-ZetaPromptWidth
    $renderStart = [DateTime]::UtcNow

    # Exit code must be captured by the caller (Set-ZetaPromptFunction) as its very first
    # statement: any successful command in between resets $? to True.
    $exitCode = 0
    if (-not $Success) {
        $exitCode = 1
        $native = 0
        # The variable does not exist until the first native command runs (StrictMode-safe read).
        if (Test-Path Variable:\global:LASTEXITCODE) { $native = [int]$global:LASTEXITCODE }
        if ($native -ne 0) { $exitCode = $native }
    }

    $durationMs = 0
    if ($config.prompt.duration -and $script:ZetaCommandStart) {
        $durationMs = ([DateTime]::UtcNow - $script:ZetaCommandStart).TotalMilliseconds
        $script:ZetaLastDurationMs = $durationMs
        $script:ZetaCommandStart = $null
    }
    $script:ZetaLastExitCode = $exitCode

    [void](Receive-ZetaWorker)
    $state = Get-ZetaPromptState -ExitCode $exitCode -DurationMs $durationMs

    # Directory tracking for the z plugin: one append per actual cd, never per prompt.
    if ($script:ZetaVisitHook -and $script:ZetaLastVisitPath -ne $state.Path) {
        $script:ZetaLastVisitPath = $state.Path
        try { & $script:ZetaVisitHook $state.Path } catch { }
    }

    $separator = Get-ZetaGlyph 'pipe'
    if ($theme.glyphs -and $theme.glyphs.ContainsKey('separator') -and $theme.glyphs.separator) { $separator = [string]$theme.glyphs.separator }

    # The right side is cheap and changes every render (duration / clock). Build it first so the
    # left side can be laid out against the space it actually leaves.
    $rightCells = @()
    if ($config.prompt.rightAlign) {
        $rightCells = @(Get-ZetaPromptCells -Entries $theme.prompt.right -Theme $theme -State $state)
    }
    $rightText = ''
    $rightLength = 0
    if ($rightCells.Count -gt 0) {
        $rightText = Format-ZetaCells -Cells $rightCells -Theme $theme -Mode $mode -Separator $separator
        foreach ($cell in $rightCells) { $rightLength += (Get-ZetaVisibleLength $cell.Text) + 1 }
    }

    # The left side is expensive (segment dispatch, palette lookups, width maths) and only
    # changes when its inputs change - so memoise the rendered string on a signature.
    $signature = Get-ZetaPromptSignature -State $state -Theme $theme -Width $width -Mode $mode -RightReserve $rightLength
    $cached = $script:ZetaLeftCache
    if ($cached -and $cached.Signature -eq $signature) {
        $leftText = $cached.Text
        $leftLength = $cached.Length
    }
    else {
        $leftCells = @(Get-ZetaPromptCells -Entries $theme.prompt.left -Theme $theme -State $state)
        $leftCells = @(Fit-ZetaCells -Cells $leftCells -Width $width -RightReserve $rightLength)
        $leftText = Format-ZetaCells -Cells $leftCells -Theme $theme -Mode $mode -Separator $separator

        $leftLength = (Get-ZetaVisibleLength $leftText) + 2   # corner + dash
        $script:ZetaLeftCache = @{ Signature = $signature; Text = $leftText; Length = $leftLength }
    }

    $padding = ''
    if ($rightLength -gt 0 -and $width -gt ($leftLength + $rightLength)) {
        $padding = ' ' * ($width - $leftLength - $rightLength)
    }

    $corner = Get-ZetaGlyph 'corner'
    $cornerEnd = Get-ZetaGlyph 'cornerEnd'
    $dash = Get-ZetaGlyph 'dash'
    $arrow = Get-ZetaGlyph 'prompt'
    $muted = Get-ZetaToneColor -Theme $theme -Tone 'muted'
    $accent = Get-ZetaToneColor -Theme $theme -Tone 'accent'

    $esc = $script:ZetaEsc
    if ($mode -eq 'none') {
        $line1 = "$corner$dash $leftText$padding$rightText"
        $line2 = "$cornerEnd$dash$arrow "
    }
    else {
        $line1 = (ConvertTo-ZetaAnsi -Hex $muted -Mode $mode) + $corner + $dash + "$esc[0m" + $leftText + $padding + $rightText
        $line2 = (ConvertTo-ZetaAnsi -Hex $muted -Mode $mode) + $cornerEnd + $dash + "$esc[0m" + (ConvertTo-ZetaAnsi -Hex $accent -Mode $mode) + $arrow + "$esc[0m" + ' '
    }

    try { if ($Capture) { return ($line1 + "`n" + $line2) } else { [Console]::Out.Write($line1 + "`n" + $line2) } } catch { }
    $script:ZetaPromptRendered = $true

    if (-not $Capture -and $config.prompt.title) { Update-ZetaTerminalTitle -Theme $theme }

    $script:ZetaLastRenderMs = [Math]::Round((([DateTime]::UtcNow) - $renderStart).TotalMilliseconds, 2)
    return $null}

function Update-ZetaTerminalTitle {
    param([hashtable]$Theme)

    try {
        $path = Get-ZetaDisplayPath -Path (Get-Location).Path -MaxSegments 2
        $title = "$path  |  $($Theme.name)"
        if ($title -eq $script:ZetaTitleCache) { return }
        $Host.UI.RawUI.WindowTitle = $title
        $script:ZetaTitleCache = $title
    }
    catch { }
}

function Test-ZetaPredictiveSupport {
    <#
    .SYNOPSIS
        True when PSReadLine exposes PredictionSource (2.2+). PSReadLine 2.0 (ships with 5.1) does not.
    #>
    try {
        if (-not (Get-Module -Name PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
        $options = Get-PSReadLineOption -ErrorAction Stop
        return [bool]($options.PSObject.Properties['PredictionSource'])
    }
    catch { return $false }
}

function Set-ZetaCompletionKeys {
    <#
    .SYNOPSIS
        Bind Tab to the configured completion style; the other style always lives on Shift+Tab.
    .DESCRIPTION
        tab        -> Tab cycles inline completions, Shift+Tab opens the selection menu
        menu       -> Tab opens the dropdown menu, Shift+Tab cycles inline
        predictive -> same as menu, plus PSReadLine ListView predictions (requires 2.2+)
    #>
    param([string]$Mode = 'tab')

    try { if (-not (Get-Module -Name PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop } } catch { return $false }

    $primary = 'Complete'
    $alternate = 'MenuComplete'
    if ($Mode -eq 'menu' -or $Mode -eq 'predictive') {
        $primary = 'MenuComplete'
        $alternate = 'Complete'
    }

    $bound = $true
    try { Set-PSReadLineKeyHandler -Key Tab -Function $primary -ErrorAction Stop }
    catch { $bound = $false }
    try { Set-PSReadLineKeyHandler -Key 'Shift+Tab' -Function $alternate -ErrorAction Stop } catch { }
    return $bound
}

function Set-ZetaPredictiveMode {
    <#
    .SYNOPSIS
        Toggle PSReadLine predictions. Returns Success + the real reason on failure.
    .DESCRIPTION
        PSReadLine refuses to enable predictions when the console output is redirected or lacks
        VT processing, so a bare boolean loses the one detail the user needs to fix it.
    #>
    param([bool]$Enabled)

    if (-not $Enabled) {
        try { Set-PSReadLineOption -PredictionSource None -ErrorAction Stop } catch { }
        return @{ Success = $false; Message = 'disabled' }
    }
    try {
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
        return @{ Success = $true; Message = 'enabled' }
    }
    catch {
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

function Set-ZetaSyntaxColors {
    <#
    .SYNOPSIS
        Theme PSReadLine's syntax highlighting from the active palette.
    .DESCRIPTION
        Values are passed as #rrggbb. PSReadLine accepts ConsoleColor, ANSI, or hex on both
        2.0 (ships with 5.1) and 2.2+ (PS7) - hex is the only form that needs no version gate.
        An ANSI string built with `e silently fails on 5.1, which is why this uses hex.
    #>
    param([hashtable]$Theme)

    if (-not $Theme) { return $false }
    try {
        if (-not (Get-Module -Name PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
        $colors = @{
            Command   = (Get-ZetaToneColor -Theme $Theme -Tone 'accent')
            Parameter = (Get-ZetaToneColor -Theme $Theme -Tone 'info')
            String    = (Get-ZetaToneColor -Theme $Theme -Tone 'ok')
            Operator  = (Get-ZetaToneColor -Theme $Theme -Tone 'muted')
            Variable  = (Get-ZetaToneColor -Theme $Theme -Tone 'warn')
            Comment   = (Get-ZetaToneColor -Theme $Theme -Tone 'muted')
            Keyword   = (Get-ZetaToneColor -Theme $Theme -Tone 'err')
            Number    = (Get-ZetaToneColor -Theme $Theme -Tone 'info')
            Type      = (Get-ZetaToneColor -Theme $Theme -Tone 'info')
            Member    = (Get-ZetaToneColor -Theme $Theme -Tone 'text')
            Error     = (Get-ZetaToneColor -Theme $Theme -Tone 'err')
            Selection = (Get-ZetaToneColor -Theme $Theme -Tone 'surface2')
        }
        Set-PSReadLineOption -Colors $colors -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Enable-ZetaPromptHooks {
    <#
    .SYNOPSIS
        PSReadLine integration: timing hook + history UX + theming of the line editor.
        Every call is capability-gated so a PSReadLine upgrade cannot break the prompt.
    #>
    if ($script:ZetaHooksInstalled) { return }
    if (-not (Get-Module -Name PSReadLine)) {
        try { Import-Module PSReadLine -ErrorAction Stop } catch { return }
    }
    $config = Get-ZetaConfig

    try {
        # Timing: fires when the line is accepted, before execution - no Enter rebinding.
        Set-PSReadLineOption -AddToHistoryHandler {
            param([string]$line)
            $global:ZetaCommandStart = [DateTime]::UtcNow
            return $true
        }
    }
    catch { }

    try {
        Set-PSReadLineOption -HistorySearchCursorMovesToEnd
        Set-PSReadLineOption -BellStyle None -ErrorAction Stop
    }
    catch { }

    if ($config.features.historySearch) {
        try {
            Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
            Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
        }
        catch { }
        try { Set-PSReadLineKeyHandler -Key 'Ctrl+d' -Function DeleteCharOrExit } catch { }
    }

    # Completion style is independent of history search: Tab is always bound, Shift+Tab is the
    # alternate style, so switching modes never leaves you without completion.
    [void](Set-ZetaCompletionKeys -Mode ([string]$config.features.completion))

    if ($config.features.predictions) {
        try {
            if (Test-ZetaPredictiveSupport) {
                Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction Stop
                Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction Stop
            }
        }
        catch { }
    }

    if ($config.features.syntaxHighlighting) {
        [void](Set-ZetaSyntaxColors -Theme (Import-ZetaTheme -Name $config.theme))
    }

    $script:ZetaHooksInstalled = $true
}

function Remove-ZetaPromptHooks {
    try { Set-PSReadLineOption -AddToHistoryHandler $null } catch { }
    $script:ZetaHooksInstalled = $false
}

function Set-ZetaPromptFunction {
    <#
    .SYNOPSIS
        Install the global prompt. Replaces any previous Zeta prompt, never user code.
    #>
    $scriptBlock = {
        # First statement on purpose: $? still holds the executed command's status here.
        # Anything that runs first would reset it to True.
        $zetaSuccess = $?
        try {
            Write-ZetaPrompt -Success $zetaSuccess
        }
        catch {
            # A broken prompt must never trap the user in a shell with no prompt.
            [Console]::Out.Write("zeta> ")
        }
        return ''
    }
    Set-Item -Path Function:\global:prompt -Value $scriptBlock -Force
}

function Get-ZetaPromptRenderInfo {
    return @{
        RenderMs   = $script:ZetaLastRenderMs
        DurationMs = $script:ZetaLastDurationMs
        ExitCode   = $script:ZetaLastExitCode
        BootMs     = $script:ZetaBootMs
        Async      = [bool]$script:ZetaWorkerReady
        Cache      = $script:ZetaCache.Count
        Failures   = $script:ZetaWorkerFailures
    }
}
