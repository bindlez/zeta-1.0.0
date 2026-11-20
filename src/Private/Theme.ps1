# Theme model + colour pipeline.
# A theme is JSON: palette (hex) + prompt layout (segment references) + optional terminal scheme.

$script:ZetaThemeCache = @{}
$script:ZetaWarnedThemes = @{}
$script:ZetaXtermPalette = $null
$script:ZetaThemeTick = 0

$script:ZetaBuiltinTheme = @{
    name    = 'fallback'
    palette = @{
        bg = '#111318'; surface = '#1b1f27'; surface2 = '#232833'
        text = '#e6e9ef'; muted = '#6b7280'
        accent = '#7aa2f7'; ok = '#9ece6a'; warn = '#e0af68'; err = '#f7768e'; info = '#7dcfff'
    }
    prompt  = @{
        left  = @(
            @{ segment = 'context'; style = 'plain'; fg = 'muted' }
            @{ segment = 'dir'; style = 'pill'; bg = 'accent'; fg = 'bg' }
            @{ segment = 'git'; style = 'plain'; fg = 'ok' }
        )
        right = @(
            @{ segment = 'duration'; style = 'plain'; fg = 'muted' }
            @{ segment = 'clock'; style = 'plain'; fg = 'muted' }
        )
    }
    glyphs  = @{}
    terminal = @{ name = 'Zeta Fallback' }
}

function Get-ZetaThemeDirectories {
    $dirs = @()
    $builtin = Join-Path $script:ModuleRoot 'Themes'
    if (Test-Path -LiteralPath $builtin) { $dirs += $builtin }
    $user = Get-ZetaUserThemePath
    if (Test-Path -LiteralPath $user) { $dirs += $user }
    return $dirs
}

function Get-ZetaThemeDefinition {
    <#
    .SYNOPSIS
        All discoverable themes, user themes win over built-ins with the same name.
    #>
    $seen = @{}
    $themes = @()
    $builtinRoot = Join-Path $script:ModuleRoot 'Themes'
    foreach ($dir in (Get-ZetaThemeDirectories)) {
        foreach ($file in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            if ($seen.ContainsKey($file.BaseName)) { continue }
            $seen[$file.BaseName] = $true
            # Path-prefix, not a wildcard: '*\Themes\*' also matches a user folder called
            # "themes" (Windows compares case-insensitively) and mislabels user themes.
            $source = 'user'
            if ($file.FullName.StartsWith($builtinRoot, [StringComparison]::OrdinalIgnoreCase)) { $source = 'builtin' }
            $themes += [pscustomobject]@{
                Name   = $file.BaseName
                Path   = $file.FullName
                Source = $source
            }
        }
    }
    return ($themes | Sort-Object Name)
}

function Import-ZetaTheme {
    <#
    .SYNOPSIS
        Load and normalise a theme by name (cached). Never throws: falls back to a built-in.
    #>
    param([Parameter(Mandatory)][string]$Name)

    if ($script:ZetaThemeCache.ContainsKey($Name)) {
        $cached = $script:ZetaThemeCache[$Name]
        # Themes are edited on disk (Studio, hand-edited JSON). Re-stat every few calls so a
        # save lands in the running shell without a reload, at ~zero cost per prompt.
        $script:ZetaThemeTick++
        if (($script:ZetaThemeTick % 3) -eq 0 -and $cached.File -and (Test-Path -LiteralPath $cached.File)) {
            $stamp = (Get-Item -LiteralPath $cached.File).LastWriteTimeUtc.Ticks
            if ($stamp -ne $cached.Stamp) { [void]$script:ZetaThemeCache.Remove($Name) }
            else { return $cached.Theme }
        }
        else { return $cached.Theme }
    }

    $theme = $null
    $file = $null
    foreach ($dir in (Get-ZetaThemeDirectories)) {
        $candidate = Join-Path $dir "$Name.json"
        if (Test-Path -LiteralPath $candidate) { $file = $candidate; break }
    }

    if ($file) {
        try {
            $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
            $parsed = ConvertTo-ZetaHashtable (ConvertFrom-Json -InputObject $raw)
            if ($parsed -is [hashtable]) { $theme = $parsed }
        }
        catch {
            Write-Warning ("Zeta: theme '{0}' failed to parse: {1}" -f $Name, $_.Exception.Message)
        }
    }

    if (-not $theme) {
        if (-not $script:ZetaWarnedThemes.ContainsKey($Name)) {
            Write-Warning ("Zeta: theme '{0}' not found, using fallback." -f $Name)
            $script:ZetaWarnedThemes[$Name] = $true
        }
        $theme = $script:ZetaBuiltinTheme
        $theme.name = 'fallback'
    }

    if (-not $theme.palette) { $theme.palette = $script:ZetaBuiltinTheme.palette }
    if (-not $theme.prompt) { $theme.prompt = $script:ZetaBuiltinTheme.prompt }
    if (-not $theme.prompt.left) { $theme.prompt.left = @() }
    if (-not $theme.prompt.right) { $theme.prompt.right = @() }
    if (-not $theme.glyphs) { $theme.glyphs = @{} }
    if (-not $theme.name) { $theme.name = $Name }

    $stampValue = 0
    if ($file) {
        try { $stampValue = (Get-Item -LiteralPath $file).LastWriteTimeUtc.Ticks } catch { }
    }
    $script:ZetaThemeCache[$Name] = @{ Theme = $theme; File = $file; Stamp = $stampValue }
    return $theme
}

function Resolve-ZetaColor {
    <#
    .SYNOPSIS
        Resolve a palette key or literal #hex to #rrggbb.
    #>
    param(
        [AllowNull()][string]$Value,
        [hashtable]$Theme
    )

    if (-not $Value) { return $null }
    if ($Value.StartsWith('#')) { return $Value.ToLowerInvariant() }
    if ($Theme -and $Theme.palette -and $Theme.palette.ContainsKey($Value)) { return $Theme.palette[$Value] }
    return $null
}

function Get-ZetaXtermPalette {
    # 0-15 basic, 16-231 6x6x6 cube, 232-255 greyscale - the standard xterm-256 table.
    if ($null -ne $script:ZetaXtermPalette) { return $script:ZetaXtermPalette }
    $table = New-Object 'System.Collections.Generic.List[object]'
    $base = @(
        @(0, 0, 0), @(128, 0, 0), @(0, 128, 0), @(128, 128, 0),
        @(0, 0, 128), @(128, 0, 128), @(0, 128, 128), @(192, 192, 192),
        @(128, 128, 128), @(255, 0, 0), @(0, 255, 0), @(255, 255, 0),
        @(0, 0, 255), @(255, 0, 255), @(0, 255, 255), @(255, 255, 255)
    )
    foreach ($c in $base) { $table.Add($c) }
    $steps = @(0, 95, 135, 175, 215, 255)
    foreach ($r in $steps) { foreach ($g in $steps) { foreach ($b in $steps) { $table.Add(@($r, $g, $b)) } } }
    for ($i = 0; $i -lt 24; $i++) { $v = 8 + ($i * 10); $table.Add(@($v, $v, $v)) }
    $script:ZetaXtermPalette = $table.ToArray()
    return $script:ZetaXtermPalette
}

function ConvertFrom-ZetaHex {
    param([Parameter(Mandatory)][string]$Hex)

    $clean = $Hex.TrimStart('#')
    if ($clean.Length -eq 3) {
        $clean = '{0}{0}{1}{1}{2}{2}' -f $clean[0], $clean[1], $clean[2]
    }
    if ($clean.Length -ne 6) { return $null }
    try {
        return @(
            [Convert]::ToInt32($clean.Substring(0, 2), 16)
            [Convert]::ToInt32($clean.Substring(2, 2), 16)
            [Convert]::ToInt32($clean.Substring(4, 2), 16)
        )
    }
    catch { return $null }
}

function Get-ZetaNearestPaletteIndex {
    param([int]$R, [int]$G, [int]$B, [object[]]$Palette, [int]$Start = 0)

    $best = $Start
    $bestDistance = [double]::MaxValue
    for ($i = $Start; $i -lt $Palette.Count; $i++) {
        $entry = $Palette[$i]
        $dr = $R - $entry[0]; $dg = $G - $entry[1]; $db = $B - $entry[2]
        # perceptual weighting; green dominates luminance
        $distance = (2 * $dr * $dr) + (4 * $dg * $dg) + (3 * $db * $db)
        if ($distance -lt $bestDistance) { $bestDistance = $distance; $best = $i }
    }
    return $best
}

function ConvertTo-ZetaAnsi {
    <#
    .SYNOPSIS
        #rrggbb -> ANSI SGR, quantised to the active colour mode.
    #>
    param(
        [string]$Hex,
        [switch]$Background,
        [string]$Mode = 'truecolor'
    )

    if (-not $Hex) { return '' }
    if ($Mode -eq 'none') { return '' }
    $rgb = ConvertFrom-ZetaHex $Hex
    if (-not $rgb) { return '' }

    $prefix = 38
    if ($Background) { $prefix = 48 }

    if ($Mode -eq 'truecolor') {
        return ("$([char]27)[{0};2;{1};{2};{3}m" -f $prefix, $rgb[0], $rgb[1], $rgb[2])
    }
    if ($Mode -eq '256') {
        $index = Get-ZetaNearestPaletteIndex -R $rgb[0] -G $rgb[1] -B $rgb[2] -Palette (Get-ZetaXtermPalette)
        return ("$([char]27)[{0};5;{1}m" -f $prefix, $index)
    }
    # 16 colours: 30-37 / 90-97 foreground, 40-47 / 100-107 background.
    $ansi16 = @(
        @(0, 0, 0), @(128, 0, 0), @(0, 128, 0), @(128, 128, 0),
        @(0, 0, 128), @(128, 0, 128), @(0, 128, 128), @(192, 192, 192),
        @(128, 128, 128), @(255, 0, 0), @(0, 255, 0), @(255, 255, 0),
        @(0, 0, 255), @(255, 0, 255), @(0, 255, 255), @(255, 255, 255)
    )
    $index = Get-ZetaNearestPaletteIndex -R $rgb[0] -G $rgb[1] -B $rgb[2] -Palette $ansi16
    if ($index -lt 8) {
        if ($Background) { $code = 40 + $index } else { $code = 30 + $index }
    }
    else {
        if ($Background) { $code = 100 + ($index - 8) } else { $code = 90 + ($index - 8) }
    }
    return ("$([char]27)[{0}m" -f $code)
}

function Get-ZetaPaletteValue {
    <#
    .SYNOPSIS
        StrictMode-safe palette read (a hashtable missing a key throws on dot access).
    #>
    param(
        [hashtable]$Theme,
        [Parameter(Mandatory)][string]$Key,
        [string]$Default = '#ffffff'
    )

    if ($Theme -and $Theme.palette -and $Theme.palette.ContainsKey($Key)) {
        $value = $Theme.palette[$Key]
        if ($value) { return [string]$value }
    }
    return $Default
}

function Get-ZetaToneColor {
    param([hashtable]$Theme, [string]$Tone)

    if (-not $Tone) { $Tone = 'text' }
    $color = Resolve-ZetaColor -Value $Tone -Theme $Theme
    if ($color) { return $color }
    return (Resolve-ZetaColor -Value 'text' -Theme $Theme)
}
