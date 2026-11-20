# Configuration model. Precedence: built-in defaults < user json < environment overrides.

$script:ZetaDefaults = @{
    theme   = 'zeta'
    glyphs  = 'auto'          # auto | nerd | unicode | ascii
    color   = 'auto'          # auto | truecolor | 256 | 16 | none
    async   = $true
    prompt  = @{
        duration   = $true
        exitCode   = $true
        rightAlign = $true
        transient  = $false
        width      = 0        # 0 = auto-detect
        title      = $true    # set the terminal tab title
        spacer     = $true
    }
    cache   = @{
        git   = 2000
        langs = 60000
        kube  = 15000
    }
    plugins = @('core', 'git', 'z', 'history')
    features = @{
        predictions       = $true
        syntaxHighlighting = $true
        aliases           = $true
        historySearch     = $true
        completion        = 'tab'   # tab | menu | predictive
        autoUpdateCheck   = $false
    }
    terminal = @{
        fragment  = $true
        opacity   = 92
        fontFace  = ''
        fontSize  = 0
    }
}

$script:ZetaConfigCache = $null
$script:ZetaConfigStamp = $null
$script:ZetaConfigTick = 0

function Get-ZetaDataRoot {
    <#
    .SYNOPSIS
        Per-user state root: %LOCALAPPDATA%\Zeta on Windows, $XDG_DATA_HOME/zeta elsewhere.
    #>
    if ($env:ZETA_ROOT) { return $env:ZETA_ROOT }
    if ($script:ZetaIsWindows) {
        $base = $env:LOCALAPPDATA
        if (-not $base) { $base = Join-Path $HOME 'AppData\Local' }
        return (Join-Path $base 'Zeta')
    }
    $base = $env:XDG_DATA_HOME
    if (-not $base) { $base = Join-Path $HOME '.local/share' }
    return (Join-Path $base 'zeta')
}

function Get-ZetaConfigPath {
    return (Join-Path (Get-ZetaDataRoot) 'config.json')
}

function Get-ZetaUserThemePath {
    return (Join-Path (Get-ZetaDataRoot) 'themes')
}

function Get-ZetaUserPluginPath {
    return (Join-Path (Get-ZetaDataRoot) 'plugins')
}

function Ensure-ZetaDirectory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Merge-ZetaHashtable {
    <#
    .SYNOPSIS
        Deep-merge Overlay onto Base (Base is not mutated).
    #>
    param(
        [hashtable]$Base = @{},
        [hashtable]$Overlay = @{}
    )

    $result = @{}
    foreach ($key in $Base.Keys) {
        $baseValue = $Base[$key]
        # Deep-copy: a shallow copy would let a caller mutate the defaults by editing the
        # config it was handed (that bug silently rewrote $script:ZetaDefaults).
        if ($baseValue -is [hashtable]) { $result[$key] = Merge-ZetaHashtable -Base $baseValue -Overlay @{} }
        elseif ($baseValue -is [System.Collections.IEnumerable] -and -not ($baseValue -is [string])) { $result[$key] = @($baseValue) }
        else { $result[$key] = $baseValue }
    }
    foreach ($key in $Overlay.Keys) {
        $value = $Overlay[$key]
        if ($value -is [hashtable] -and $result[$key] -is [hashtable]) {
            $result[$key] = Merge-ZetaHashtable -Base $result[$key] -Overlay $value
        }
        else {
            $result[$key] = $value
        }
    }
    return $result
}

function Get-ZetaConfig {
    <#
    .SYNOPSIS
        Effective configuration (defaults merged with the user's config.json).
    #>
    param([switch]$Refresh)

    if ($script:ZetaConfigCache -and -not $Refresh) {
        # Another process (Studio, `zeta` in bash) may have rewritten config.json.
        $script:ZetaConfigTick++
        if (($script:ZetaConfigTick % 3) -ne 0) { return $script:ZetaConfigCache }
        $probePath = Get-ZetaConfigPath
        if (Test-Path -LiteralPath $probePath) {
            $stamp = (Get-Item -LiteralPath $probePath).LastWriteTimeUtc.Ticks
            if ($stamp -eq $script:ZetaConfigStamp) { return $script:ZetaConfigCache }
        }
        elseif ($null -eq $script:ZetaConfigStamp) { return $script:ZetaConfigCache }
    }

    $config = Merge-ZetaHashtable -Base $script:ZetaDefaults -Overlay @{}
    $path = Get-ZetaConfigPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ($raw -and $raw.Trim()) {
                $user = ConvertTo-ZetaHashtable (ConvertFrom-Json -InputObject $raw)
                if ($user -is [hashtable]) { $config = Merge-ZetaHashtable -Base $config -Overlay $user }
            }
        }
        catch {
            Write-Warning ("Zeta: config.json is not valid JSON ({0}). Using defaults." -f $_.Exception.Message)
        }
    }

    # Environment overrides - cheap, explicit, testable.
    if ($env:ZETA_THEME) { $config.theme = $env:ZETA_THEME }
    if ($env:ZETA_GLYPHS) { $config.glyphs = $env:ZETA_GLYPHS }
    if ($env:ZETA_COLOR) { $config.color = $env:ZETA_COLOR }
    if ($env:ZETA_NO_ASYNC -eq '1') { $config.async = $false }
    if ($env:ZETA_NO_COLOR -eq '1') { $config.color = 'none' }

    if (Test-Path -LiteralPath $path) {
        try { $script:ZetaConfigStamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks } catch { $script:ZetaConfigStamp = $null }
    }
    else { $script:ZetaConfigStamp = $null }

    $script:ZetaConfigCache = $config
    return $config
}

function Get-ZetaConfigDelta {
    <#
    .SYNOPSIS
        Keys in Overlay that differ from Base, recursively.
    .DESCRIPTION
        Persisting the merged config would freeze today's defaults for anyone who ever toggled
        one setting: a later default change would never reach them. Write only the difference.
    #>
    param(
        [hashtable]$Base = @{},
        [hashtable]$Overlay = @{}
    )

    $delta = @{}
    foreach ($key in $Overlay.Keys) {
        $value = $Overlay[$key]
        $baseValue = $null
        if ($Base -and $Base.ContainsKey($key)) { $baseValue = $Base[$key] }

        if ($value -is [hashtable]) {
            if ($baseValue -is [hashtable]) {
                $child = Get-ZetaConfigDelta -Base $baseValue -Overlay $value
                if ($child.Keys.Count -gt 0) { $delta[$key] = $child }
            }
            else { $delta[$key] = $value }
            continue
        }

        if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
            $separator = [string][char]1
            $left = (@($value) | ForEach-Object { [string]$_ }) -join $separator
            $right = (@($baseValue) | ForEach-Object { [string]$_ }) -join $separator
            if ($left -ne $right) { $delta[$key] = $value }
            continue
        }

        if ($value -ne $baseValue) { $delta[$key] = $value }
    }
    return $delta
}

function Save-ZetaConfig {
    param([Parameter(Mandatory)][hashtable]$Config)

    $path = Get-ZetaConfigPath
    Ensure-ZetaDirectory -Path (Split-Path -Parent $path)

    $delta = Get-ZetaConfigDelta -Base $script:ZetaDefaults -Overlay $Config
    $json = $delta | ConvertTo-Json -Depth 10
    if (-not $json) { $json = '{}' }

    $tmp = "$path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $script:ZetaConfigCache = $null
}

function Set-ZetaConfigValue {
    <#
    .SYNOPSIS
        Set a dotted config key (e.g. prompt.duration) and persist.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()]$Value
    )

    $config = Get-ZetaConfig -Refresh
    $segments = $Key -split '\.'
    $cursor = $config
    for ($i = 0; $i -lt $segments.Count - 1; $i++) {
        $name = $segments[$i]
        if (-not ($cursor[$name] -is [hashtable])) { $cursor[$name] = @{} }
        $cursor = $cursor[$name]
    }
    $cursor[$segments[-1]] = $Value
    Save-ZetaConfig -Config $config
    return $Value
}
