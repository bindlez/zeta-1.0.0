function Set-ZetaTheme {
    <#
    .SYNOPSIS
        Switch the active theme and re-render the prompt.

    .EXAMPLE
        Set-ZetaTheme tokyo-night

    .EXAMPLE
        Set-ZetaTheme -Name catppuccin-mocha -Persist
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name,

        [switch]$Persist
    )

    $available = @(Get-ZetaThemeDefinition)
    if (-not ($available | Where-Object { $_.Name -eq $Name })) {
        $names = ($available | Select-Object -ExpandProperty Name) -join ', '
        throw ("Zeta: theme '{0}' not found. Available: {1}" -f $Name, $names)
    }

    if ($PSCmdlet.ShouldProcess("theme -> $Name")) {
        $config = Get-ZetaConfig -Refresh
        $config.theme = $Name

        if ($Persist) { Save-ZetaConfig -Config $config }
        else { $script:ZetaConfigCache = $config }

        # Re-apply PSReadLine colours for the new palette.
        $script:ZetaHooksInstalled = $false
        try { Enable-ZetaPromptHooks } catch { }

        # Recompile the bash view of the theme so the other shell picks it up live.
        try { [void](Export-ZetaBashTheme -ThemeName $Name) } catch { }
        return $Name
    }
}

function Get-ZetaTheme {
    <#
    .SYNOPSIS
        Show the active theme, or a specific one.

    .EXAMPLE
        Get-ZetaTheme
    #>
    [CmdletBinding()]
    param([string]$Name)

    $config = Get-ZetaConfig
    if (-not $Name) { $Name = $config.theme }
    $theme = Import-ZetaTheme -Name $Name
    $definition = Get-ZetaThemeDefinition | Where-Object { $_.Name -eq $Name } | Select-Object -First 1

    return [pscustomobject]@{
        Name     = $theme.name
        Active   = ($Name -eq $config.theme)
        Segments = (@($theme.prompt.left | ForEach-Object { $_.segment }) -join ', ')
        Right    = (@($theme.prompt.right | ForEach-Object { $_.segment }) -join ', ')
        Palette  = $theme.palette
        Path     = $(if ($definition) { $definition.Path } else { '' })
    }
}

function Get-ZetaThemeList {
    <#
    .SYNOPSIS
        List installed themes (built-in + user). User themes override built-ins by name.

    .EXAMPLE
        Get-ZetaThemeList
    #>
    [CmdletBinding()]
    param()

    foreach ($theme in (Get-ZetaThemeDefinition)) {
        [pscustomobject]@{
            Name   = $theme.Name
            Source = $theme.Source
            Path   = $theme.Path
        }
    }
}
