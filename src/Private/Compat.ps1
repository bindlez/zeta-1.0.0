# Capability detection. Nothing here may assume PowerShell 7 - this module runs on 5.1.
# Rule: detect capabilities, never branch on a single version number.

$script:ZetaIsWindows = $true
if ($PSVersionTable.PSEdition -eq 'Core') {
    if (Test-Path Variable:\IsWindows) { $script:ZetaIsWindows = [bool]$IsWindows }
    else { $script:ZetaIsWindows = $false }
}

$script:ZetaIsPS7 = ($PSVersionTable.PSVersion.Major -ge 6)
$script:ZetaAnsiModeCache = $null
$script:ZetaGlyphTierCache = $null
$script:ZetaNerdFontCache = $null
$script:ZetaElevatedCache = $null
$script:ZetaVtEnabled = $false

# ESC must be built from [char]27: `e is PowerShell 6+ only and silently degrades to "e" on 5.1.
$script:ZetaEsc = [string][char]27

function Test-ZetaCommand {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command -Name $Name -CommandType Application, Cmdlet, Function -ErrorAction SilentlyContinue)
}

function Get-ZetaAnsiMode {
    <#
    .SYNOPSIS
        Resolve the colour depth to emit: truecolor | 256 | 16 | none.
    #>
    param([switch]$Refresh)

    # Cache keyed on the inputs: changing $env:ZETA_COLOR mid-session must take effect.
    $cacheKey = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $env:ZETA_COLOR, $env:NO_COLOR, $env:WT_SESSION, $env:COLORTERM, $env:TERM, $script:ZetaVtEnabled)
    if ($script:ZetaAnsiModeCache -and $script:ZetaAnsiModeKey -eq $cacheKey -and -not $Refresh) { return $script:ZetaAnsiModeCache }

    $mode = 'auto'
    if ($env:ZETA_COLOR) { $mode = $env:ZETA_COLOR.ToLowerInvariant() }

    if ($mode -eq 'auto') {
        if ($env:NO_COLOR -and -not $env:ZETA_FORCE_COLOR) { $mode = 'none' }
        elseif ($env:TERM -eq 'dumb') { $mode = '16' }
        elseif ($env:COLORTERM -match 'truecolor|24bit') { $mode = 'truecolor' }
        elseif ($env:WT_SESSION -or $env:TERM_PROGRAM) { $mode = 'truecolor' }
        elseif ($script:ZetaVtEnabled) { $mode = 'truecolor' }
        elseif ($script:ZetaIsPS7) { $mode = '256' }
        else { $mode = '16' }
    }

    switch ($mode) {
        'truecolor' { $mode = 'truecolor' }
        '24bit'     { $mode = 'truecolor' }
        '256'       { $mode = '256' }
        '16'        { $mode = '16' }
        'none'      { $mode = 'none' }
        'off'       { $mode = 'none' }
        default     { $mode = '256' }
    }

    $script:ZetaAnsiModeCache = $mode
    $script:ZetaAnsiModeKey = $cacheKey
    return $mode
}

function Test-ZetaNerdFont {
    <#
    .SYNOPSIS
        True when a Nerd Font (or a powerline-patched font) is installed.
    #>
    param([switch]$Refresh)

    if ($null -ne $script:ZetaNerdFontCache -and -not $Refresh) { return $script:ZetaNerdFontCache }
    if ($env:ZETA_NERD_FONT -eq '1') { $script:ZetaNerdFontCache = $true; return $true }
    if ($env:ZETA_NERD_FONT -eq '0') { $script:ZetaNerdFontCache = $false; return $false }

    $found = $false
    if ($script:ZetaIsWindows) {
        $dirs = @()
        if ($env:WINDIR) { $dirs += (Join-Path $env:WINDIR 'Fonts') }
        if ($env:LOCALAPPDATA) { $dirs += (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') }
        foreach ($dir in $dirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $hit = Get-ChildItem -LiteralPath $dir -Filter '*.ttf' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'NFP|NF-|Nerd|Powerline|PL\.ttf' } | Select-Object -First 1
            if ($hit) { $found = $true; break }
        }
    }

    $script:ZetaNerdFontCache = $found
    return $found
}

function Get-ZetaGlyph {
    <#
    .SYNOPSIS
        Glyph table. nerd > unicode > ascii; every entry is a string so astral code points work.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $tier = Get-ZetaGlyphTier
    $esc = [string][char]27

    $sets = @{
        nerd    = @{
            corner = [string][char]0x256D; cornerEnd = [string][char]0x2570; prompt = [string][char]0x276F; dash = [string][char]0x2500
            separator = [string][char]0xE0B0; thin = [string][char]0xE0B1; pipe = [string][char]0x2502
            branch = [string][char]0xE0A0; plus = [string][char]0x271A; modified = [string][char]0x270E
            untracked = '?'; conflict = '!'; ahead = [string][char]0x2191; behind = [string][char]0x2193
            clock = [string][char]0x25F4; timer = [string][char]0x25F4; bolt = [string][char]0x26A1
            folder = [string][char]0xF07B; home = [string][char]0xF015; lock = [string][char]0xF023
            node = [string][char]0xE718; python = [string][char]0xE73C; rust = [string][char]0xE7A8
            dotnet = [string][char]0xE77F; go = [string][char]0xE626; docker = [string][char]0xF308
            kube = [string][char]0x2388; cloud = [string][char]0x2601; battery = [string][char]0xF240
            arrow = [string][char]0x279C; star = [string][char]0x2B50
        }
        unicode = @{
            corner = [string][char]0x256D; cornerEnd = [string][char]0x2570; prompt = [string][char]0x276F; dash = [string][char]0x2500
            separator = [string][char]0x203A; thin = [string][char]0x203A; pipe = [string][char]0x2502
            branch = [string][char]0x25C6; plus = '+'; modified = '~'
            untracked = '?'; conflict = '!'; ahead = [string][char]0x2191; behind = [string][char]0x2193
            clock = [string][char]0x25F4; timer = [string][char]0x25F4; bolt = [string][char]0x25CF
            folder = [string][char]0x25B8; home = [string][char]0x2302; lock = [string][char]0x25A0
            node = 'N'; python = 'P'; rust = 'R'
            dotnet = '.N'; go = 'G'; docker = 'D'
            kube = 'K'; cloud = 'C'; battery = '%'
            arrow = [string][char]0x2192; star = [string][char]0x2022
        }
        ascii   = @{
            corner = '+'; cornerEnd = '+'; prompt = '>'; dash = '-'
            separator = '>'; thin = '-'; pipe = '|'
            branch = 'git'; plus = '+'; modified = '~'
            untracked = '?'; conflict = '!'; ahead = '^'; behind = 'v'
            clock = '@'; timer = 't'; bolt = '!'
            folder = '>'; home = '~'; lock = '#'
            node = 'N'; python = 'P'; rust = 'R'
            dotnet = 'N'; go = 'G'; docker = 'D'
            kube = 'K'; cloud = 'C'; battery = 'B'
            arrow = '->'; star = '*'
        }
    }

    if (-not $sets.ContainsKey($tier)) { $tier = 'ascii' }
    $set = $sets[$tier]
    if ($set.ContainsKey($Name)) { return [string]$set[$Name] }
    return ''
}

function Get-ZetaGlyphTier {
    <#
    .SYNOPSIS
        nerd > unicode > ascii. Every theme and segment must look right in all three.
    #>
    param([switch]$Refresh)

    $cacheKey = ('{0}|{1}' -f $env:ZETA_GLYPHS, $env:ZETA_NERD_FONT)
    if ($script:ZetaGlyphTierCache -and $script:ZetaGlyphTierKey -eq $cacheKey -and -not $Refresh) { return $script:ZetaGlyphTierCache }

    $forced = $env:ZETA_GLYPHS
    if ($forced) {
        switch ($forced.ToLowerInvariant()) {
            'nerd'    { $tier = 'nerd' }
            'unicode' { $tier = 'unicode' }
            'ascii'   { $tier = 'ascii' }
            default   { $tier = 'unicode' }
        }
    }
    elseif (Test-ZetaNerdFont) { $tier = 'nerd' }
    else { $tier = 'unicode' }

    # A non-UTF8 console mangles box drawing characters; fall back hard.
    if ($tier -ne 'ascii') {
        try {
            $enc = [Console]::OutputEncoding
            if ($enc -and $enc.CodePage -ne 65001 -and $enc.WebName -notmatch 'utf') {
                if ($script:ZetaIsWindows) { $tier = 'ascii' }
            }
        }
        catch { }
    }

    $script:ZetaGlyphTierCache = $tier
    $script:ZetaGlyphTierKey = $cacheKey
    return $tier
}

function Format-ZetaDuration {
    param([double]$Milliseconds)

    if ($Milliseconds -lt 1000) { return ('{0}ms' -f [int]$Milliseconds) }
    if ($Milliseconds -lt 60000) { return ('{0:N2}s' -f ($Milliseconds / 1000)) }
    $m = [Math]::Floor($Milliseconds / 60000)
    $s = [Math]::Floor(($Milliseconds % 60000) / 1000)
    return ('{0}m{1:D2}s' -f $m, $s)
}

function Get-ZetaDisplayPath {
    <#
    .SYNOPSIS
        Shorten a path for the prompt: ~ for home, and per-directory truncation.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxSegments = 3,
        [switch]$Shorten
    )

    $homePath = $HOME
    if (-not $homePath) { $homePath = $env:USERPROFILE }
    if (-not $homePath) { $homePath = $env:HOME }

    $display = $Path
    if ($homePath -and $Path.StartsWith($homePath, [StringComparison]::OrdinalIgnoreCase)) {
        $display = '~' + $Path.Substring($homePath.Length)
    }
    $display = $display -replace '\\', '/'
    if ($display.Length -gt 1 -and $display.EndsWith('/')) { $display = $display.TrimEnd('/') }

    $parts = @($display -split '/' | Where-Object { $_ -ne '' })
    $prefix = ''
    if ($display.StartsWith('/')) { $prefix = '/' }

    if ($Shorten -and $parts.Count -gt $MaxSegments) {
        $kept = @()
        if ($parts.Count -gt 0 -and $parts[0] -eq '~') { $kept += '~'; $parts = @($parts | Select-Object -Skip 1) }
        $tail = @($parts | Select-Object -Last ($MaxSegments - $kept.Count))
        $kept += $tail
        return ($prefix + ($kept -join '/'))
    }
    return $display
}

function Test-ZetaElevated {
    param([switch]$Refresh)

    if ($null -ne $script:ZetaElevatedCache -and -not $Refresh) { return $script:ZetaElevatedCache }
    $result = $false
    if ($script:ZetaIsWindows) {
        try {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($id)
            $result = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        }
        catch { $result = $false }
    }
    else {
        try { $result = ((& id -u) -eq '0') } catch { $result = $false }
    }
    $script:ZetaElevatedCache = $result
    return $result
}

function ConvertTo-ZetaHashtable {
    <#
    .SYNOPSIS
        Recursively normalise PSCustomObject (ConvertFrom-Json, 5.1) into hashtables.
    #>
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $out = @{}
            foreach ($key in $InputObject.Keys) { $out[[string]$key] = ConvertTo-ZetaHashtable $InputObject[$key] }
            return $out
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
            $list = @()
            foreach ($item in $InputObject) { $list += , (ConvertTo-ZetaHashtable $item) }
            return , $list
        }
        if ($InputObject -is [pscustomobject]) {
            $out = @{}
            foreach ($prop in $InputObject.PSObject.Properties) { $out[$prop.Name] = ConvertTo-ZetaHashtable $prop.Value }
            return $out
        }
        return $InputObject
    }
}

function Enable-ZetaVirtualTerminal {
    <#
    .SYNOPSIS
        Turn on ANSI processing in classic conhost (Windows PowerShell 5.1). Best effort.
    #>
    if (-not $script:ZetaIsWindows) { $script:ZetaVtEnabled = $true; return $true }
    if ($script:ZetaIsPS7) { $script:ZetaVtEnabled = $true; return $true }
    if ($env:WT_SESSION) { $script:ZetaVtEnabled = $true; return $true }

    try {
        if (-not ('Zeta.ConsoleMode' -as [type])) {
            Add-Type -Namespace Zeta -Name ConsoleMode -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $handle = [Zeta.ConsoleMode]::GetStdHandle(-11)
        $mode = 0
        if (-not [Zeta.ConsoleMode]::GetConsoleMode($handle, [ref]$mode)) { return $false }
        $enableVt = 0x0004
        if (($mode -band $enableVt) -eq $enableVt) { $script:ZetaVtEnabled = $true; return $true }
        $script:ZetaVtEnabled = [Zeta.ConsoleMode]::SetConsoleMode($handle, ($mode -bor $enableVt))
        return $script:ZetaVtEnabled
    }
    catch { return $false }
}
