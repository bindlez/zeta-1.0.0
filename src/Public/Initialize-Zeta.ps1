function Initialize-Zeta {
    <#
    .SYNOPSIS
        Wire Zeta into the current session. Idempotent; safe to call from $PROFILE.

    .DESCRIPTION
        Enables ANSI in classic conhost, loads config, starts the background sensor worker,
        loads plugins, applies PSReadLine settings, installs the prompt and (optionally)
        the Windows Terminal fragment.

    .PARAMETER NoPlugins
        Skip plugin loading (useful for benchmarking the core).

    .PARAMETER NoHooks
        Do not touch PSReadLine or the terminal title.
    #>
    [CmdletBinding()]
    param(
        [switch]$NoPlugins,
        [switch]$NoHooks
    )

    $config = Get-ZetaConfig -Refresh
    [void](Enable-ZetaVirtualTerminal)

    # Refresh cached capability decisions now that VT/normalisation is in place.
    [void](Get-ZetaAnsiMode -Refresh)
    [void](Get-ZetaGlyphTier -Refresh)

    if (-not $NoPlugins) { [void](Initialize-ZetaPlugins) }

    if ($config.async) {
        $workerReady = Initialize-ZetaWorker
        if (-not $workerReady) { Write-Verbose 'Zeta: running without the background worker (segments are synchronous).' }
        else {
            Initialize-ZetaPrime
        }
    }

    if (-not $NoHooks) { Enable-ZetaPromptHooks }

    Set-ZetaPromptFunction

    # Keep the bash half in sync from the very first session.
    try { [void](Export-ZetaBashTheme) } catch { }

    if ($config.terminal.fragment -and $env:WT_SESSION -and $env:ZETA_NO_FRAGMENT -ne '1') {
        try { [void](Write-ZetaTerminalFragment) } catch { }
    }

    return [pscustomobject]@{
        Version   = $script:ZetaVersion
        Theme     = $config.theme
        Async     = [bool]$script:ZetaWorkerReady
        Plugins   = @(Get-ZetaLoadedPluginNames)
        ColorMode = (Get-ZetaAnsiMode)
        Glyphs    = (Get-ZetaGlyphTier)
    }
}
