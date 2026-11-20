# Windows Terminal integration: a fragment that themes the terminal, not just the prompt.

function Get-ZetaTerminalScheme {
    param([Parameter(Mandatory)][hashtable]$Theme)

    $palette = $Theme.palette
    $scheme = @{
        name                = "Zeta $($Theme.name)"
        background          = (Get-ZetaPaletteValue -Theme $Theme -Key 'bg' -Default '#111318')
        foreground          = (Get-ZetaPaletteValue -Theme $Theme -Key 'text' -Default '#e6e9ef')
        cursorColor         = (Get-ZetaPaletteValue -Theme $Theme -Key 'accent' -Default '#7aa2f7')
        selectionBackground = (Get-ZetaPaletteValue -Theme $Theme -Key 'surface2' -Default '#232833')
        black               = (Get-ZetaPaletteValue -Theme $Theme -Key 'bg' -Default '#111318')
        red                 = (Get-ZetaPaletteValue -Theme $Theme -Key 'err' -Default '#f7768e')
        green               = (Get-ZetaPaletteValue -Theme $Theme -Key 'ok' -Default '#9ece6a')
        yellow              = (Get-ZetaPaletteValue -Theme $Theme -Key 'warn' -Default '#e0af68')
        blue                = (Get-ZetaPaletteValue -Theme $Theme -Key 'accent' -Default '#7aa2f7')
        purple              = (Get-ZetaPaletteValue -Theme $Theme -Key 'magenta' -Default '#bb9af7')
        cyan                = (Get-ZetaPaletteValue -Theme $Theme -Key 'cyan' -Default '#7dcfff')
        white               = (Get-ZetaPaletteValue -Theme $Theme -Key 'text' -Default '#e6e9ef')
        brightBlack         = (Get-ZetaPaletteValue -Theme $Theme -Key 'muted' -Default '#6b7280')
        brightRed           = (Get-ZetaPaletteValue -Theme $Theme -Key 'err' -Default '#f7768e')
        brightGreen         = (Get-ZetaPaletteValue -Theme $Theme -Key 'ok' -Default '#9ece6a')
        brightYellow        = (Get-ZetaPaletteValue -Theme $Theme -Key 'warn' -Default '#e0af68')
        brightBlue          = (Get-ZetaPaletteValue -Theme $Theme -Key 'accent' -Default '#7aa2f7')
        brightPurple        = (Get-ZetaPaletteValue -Theme $Theme -Key 'magenta' -Default '#bb9af7')
        brightCyan          = (Get-ZetaPaletteValue -Theme $Theme -Key 'cyan' -Default '#7dcfff')
        brightWhite         = '#ffffff'
    }
    return $scheme
}

function Get-ZetaShellCommandLine {
    if ($script:ZetaIsPS7) { return 'pwsh.exe -NoLogo' }
    return 'powershell.exe -NoLogo'
}

function Write-ZetaTerminalFragment {
    <#
    .SYNOPSIS
        Write a Windows Terminal fragment for the current theme. Non-destructive by design.
    #>
    param(
        [string]$ThemeName,
        [string]$FontFace,
        [int]$Opacity = 0
    )

    $config = Get-ZetaConfig
    if (-not $ThemeName) { $ThemeName = $config.theme }
    if (-not $FontFace) { $FontFace = $config.terminal.fontFace }
    if (-not $Opacity) { $Opacity = [int]$config.terminal.opacity }

    $theme = Import-ZetaTheme -Name $ThemeName
    $scheme = Get-ZetaTerminalScheme -Theme $theme

    $fragmentRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Zeta'
    Ensure-ZetaDirectory -Path $fragmentRoot

    $profile = @{
        name              = "Zeta - $ThemeName"
        commandline       = (Get-ZetaShellCommandLine)
        startingDirectory = '%USERPROFILE%'
        colorScheme       = $scheme.name
        opacity           = $Opacity
        padding           = '12, 10, 12, 10'
        historySize       = 20000
        snapOnInput       = $false
        antialiasingMode  = 'grayscale'
    }
    if ($FontFace) {
        $profile.font = @{ face = $FontFace; size = 11 }
    }

    $fragment = @{
        '$help'   = 'https://aka.ms/terminal-documentation'
        profiles  = @($profile)
        schemes   = @($scheme)
    }

    $path = Join-Path $fragmentRoot 'zeta.json'
    $json = $fragment | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
    return $path
}
