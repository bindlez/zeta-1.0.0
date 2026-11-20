function Get-ZetaCompletion {
    <#
    .SYNOPSIS
        Show the completion style and the Tab / Shift+Tab bindings that are actually in effect.

    .DESCRIPTION
        Modes:
          tab        Tab cycles completions inline (default, classic PowerShell behaviour)
          menu       Tab opens the selection dropdown; arrow keys pick, Enter accepts
          predictive menu + PSReadLine ListView predictions (needs PSReadLine 2.2+, i.e. PS7)

        Whichever mode is active, the other one stays on Shift+Tab.

    .EXAMPLE
        Get-ZetaCompletion
    #>
    [CmdletBinding()]
    param()

    $config = Get-ZetaConfig
    $mode = [string]$config.features.completion
    if (-not $mode) { $mode = 'tab' }

    $tab = ''
    $shiftTab = ''
    try {
        $handlers = @(Get-PSReadLineKeyHandler -ErrorAction Stop)
        $tabHandler = @($handlers | Where-Object { $_.Key -eq 'Tab' } | Select-Object -First 1)
        $shiftHandler = @($handlers | Where-Object { $_.Key -eq 'Shift+Tab' } | Select-Object -First 1)
        if ($tabHandler.Count -gt 0) { $tab = [string]$tabHandler[0].Function }
        if ($shiftHandler.Count -gt 0) { $shiftTab = [string]$shiftHandler[0].Function }
    }
    catch { }

    $psrl = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
    $psrlVersion = ''
    if ($psrl) { $psrlVersion = $psrl.Version.ToString() }

    $predictionSource = ''
    try { $predictionSource = [string](Get-PSReadLineOption).PredictionSource } catch { }

    return [pscustomobject]@{
        Mode                = $mode
        Tab                 = $tab
        ShiftTab            = $shiftTab
        PredictionSource    = $predictionSource
        PredictiveSupported = (Test-ZetaPredictiveSupport)
        PSReadLine          = $psrlVersion
    }
}

function Set-ZetaCompletion {
    <#
    .SYNOPSIS
        Switch completion style: inline Tab cycling, a selection dropdown, or predictive.

    .DESCRIPTION
        Applies immediately and persists to config.json, so the choice survives a restart.
        Tab always completes; Shift+Tab gives you the other style without changing the mode.

    .PARAMETER Mode
        tab        Tab cycles completions inline (default)
        menu       Tab opens the dropdown menu, arrow keys select, Enter accepts
        predictive menu plus inline history predictions (requires PSReadLine 2.2+)

    .EXAMPLE
        Set-ZetaCompletion menu

    .EXAMPLE
        Set-ZetaCompletion tab      # back to classic Tab behaviour
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('tab', 'menu', 'predictive')]
        [string]$Mode
    )

    if ($Mode -eq 'predictive' -and -not (Test-ZetaPredictiveSupport)) {
        $version = 'unknown'
        $psrl = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
        if ($psrl) { $version = $psrl.Version.ToString() }
        throw ("Zeta: 'predictive' needs PSReadLine 2.2+ (installed: {0}). Use -Mode menu for the dropdown." -f $version)
    }

    if (-not $PSCmdlet.ShouldProcess("completion -> $Mode")) { return }

    $config = Get-ZetaConfig -Refresh
    if (-not ($config.features -is [hashtable])) { $config.features = @{} }
    $config.features.completion = $Mode
    Save-ZetaConfig -Config $config

    [void](Set-ZetaCompletionKeys -Mode $Mode)
    if ($Mode -eq 'predictive') {
        $predictive = Set-ZetaPredictiveMode -Enabled $true
        if (-not $predictive.Success) {
            Write-Warning ("Zeta: predictions unavailable here - {0} Tab still opens the dropdown." -f $predictive.Message)
        }
    }

    return (Get-ZetaCompletion)
}
