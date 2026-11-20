# Plugin system. Local files only - never downloads code, never resolves from $PWD.

$script:ZetaLoadedPlugins = @{}

function Get-ZetaPluginRoots {
    $roots = @()
    $builtin = Join-Path $script:ModuleRoot 'Plugins'
    if (Test-Path -LiteralPath $builtin) { $roots += $builtin }
    $user = Get-ZetaUserPluginPath
    if (Test-Path -LiteralPath $user) { $roots += $user }
    return $roots
}

function Get-ZetaPluginDefinition {
    param([string]$Name = '*')

    $definitions = @()
    foreach ($root in (Get-ZetaPluginRoots)) {
        foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            if ($Name -ne '*' -and $dir.Name -ne $Name) { continue }
            $manifest = Join-Path $dir.FullName 'plugin.json'
            $script = Join-Path $dir.FullName 'plugin.ps1'
            if (-not (Test-Path -LiteralPath $script)) { continue }
            $meta = @{}
            if (Test-Path -LiteralPath $manifest) {
                try {
                    $meta = ConvertTo-ZetaHashtable (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop))
                }
                catch { $meta = @{} }
            }
            $definitions += [pscustomobject]@{
                Name        = $dir.Name
                Description = [string]$meta.description
                Version     = [string]$meta.version
                Requires    = @($meta.requires)
                Path        = $dir.FullName
                Script      = $script
                Loaded      = $script:ZetaLoadedPlugins.ContainsKey($dir.Name)
            }
        }
    }
    return $definitions
}

function Import-ZetaPlugin {
    param([Parameter(Mandatory)][string]$Name)

    if ($script:ZetaLoadedPlugins.ContainsKey($Name)) { return $true }

    $definition = Get-ZetaPluginDefinition -Name $Name | Select-Object -First 1
    if (-not $definition) {
        Write-Warning ("Zeta: plugin '{0}' not found." -f $Name)
        return $false
    }

    foreach ($requirement in $definition.Requires) {
        if (-not $requirement) { continue }
        if (-not (Test-ZetaCommand -Name $requirement)) {
            Write-Verbose ("Zeta: plugin '{0}' skipped, missing '{1}'." -f $Name, $requirement)
            $script:ZetaLoadedPlugins[$Name] = 'skipped'
            return $false
        }
    }

    try {
        # Dot-source at module scope, not inside this function: `. file` inside a function
        # defines into the function's local scope and the definitions vanish on return.
        $moduleInfo = $ExecutionContext.SessionState.Module
        & $moduleInfo {
            param($pluginPath)
            . $pluginPath
        } $definition.Script
        $script:ZetaLoadedPlugins[$Name] = 'loaded'
        return $true
    }
    catch {
        $script:ZetaLoadedPlugins[$Name] = 'failed'
        Write-Warning ("Zeta: plugin '{0}' failed to load: {1}" -f $Name, $_.Exception.Message)
        return $false
    }
}

function Initialize-ZetaPlugins {
    $config = Get-ZetaConfig
    $loaded = @()
    $skipped = @()
    foreach ($name in @($config.plugins)) {
        if (-not $name) { continue }
        if (Import-ZetaPlugin -Name $name) { $loaded += $name } else { $skipped += $name }
    }
    return [pscustomobject]@{ Loaded = $loaded; Skipped = $skipped }
}

function Get-ZetaLoadedPluginNames {
    return @($script:ZetaLoadedPlugins.Keys | Where-Object { $script:ZetaLoadedPlugins[$_] -eq 'loaded' })
}
