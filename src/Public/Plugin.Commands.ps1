function Get-ZetaPlugin {
    <#
    .SYNOPSIS
        List plugins, their state and what they require.

    .EXAMPLE
        Get-ZetaPlugin
    #>
    [CmdletBinding()]
    param([string]$Name = '*')

    foreach ($plugin in (Get-ZetaPluginDefinition -Name $Name)) {
        $state = 'disabled'
        if ($script:ZetaLoadedPlugins.ContainsKey($plugin.Name)) { $state = $script:ZetaLoadedPlugins[$plugin.Name] }
        [pscustomobject]@{
            Name        = $plugin.Name
            State       = $state
            Version     = $plugin.Version
            Description = $plugin.Description
            Requires    = (@($plugin.Requires) -join ', ')
            Path        = $plugin.Path
        }
    }
}

function Enable-ZetaPlugin {
    <#
    .SYNOPSIS
        Enable a plugin for this session and persist it in config.json.

    .EXAMPLE
        Enable-ZetaPlugin docker
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    $definition = Get-ZetaPluginDefinition -Name $Name | Select-Object -First 1
    if (-not $definition) { throw ("Zeta: plugin '{0}' not found." -f $Name) }

    if ($PSCmdlet.ShouldProcess("plugin $Name")) {
        $config = Get-ZetaConfig -Refresh
        $plugins = @($config.plugins)
        if ($plugins -notcontains $Name) { $plugins += $Name }
        $config.plugins = $plugins
        Save-ZetaConfig -Config $config
        return (Import-ZetaPlugin -Name $Name)
    }
}

function Disable-ZetaPlugin {
    <#
    .SYNOPSIS
        Disable a plugin for this session and persist the change.

    .EXAMPLE
        Disable-ZetaPlugin z
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Name
    )

    if ($PSCmdlet.ShouldProcess("plugin $Name")) {
        $config = Get-ZetaConfig -Refresh
        $config.plugins = @($config.plugins | Where-Object { $_ -ne $Name })
        Save-ZetaConfig -Config $config
        if ($script:ZetaLoadedPlugins.ContainsKey($Name)) { [void]$script:ZetaLoadedPlugins.Remove($Name) }
        return $true
    }
}
