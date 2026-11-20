function Invoke-ZetaDoctor {
    <#
    .SYNOPSIS
        Diagnose the shell setup: capability matrix, performance and common misconfigurations.

    .EXAMPLE
        Invoke-ZetaDoctor

    .EXAMPLE
        Invoke-ZetaDoctor -Json | Out-File zeta-doctor.json
    #>
    [CmdletBinding()]
    param([switch]$Json)

    $checks = New-Object System.Collections.ArrayList
    $add = {
        param($Check, $Status, $Detail, $Fix)
        [void]$checks.Add([pscustomobject]@{
                Check  = $Check
                Status = $Status
                Detail = $Detail
                Fix    = $Fix
            })
    }

    # --- host -----------------------------------------------------------------
    & $add 'PowerShell' 'ok' ("{0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition) ''
    if (-not $script:ZetaIsPS7) {
        & $add 'Modern features' 'warn' 'Windows PowerShell 5.1: no predictive intellisense' 'Install PowerShell 7: winget install --id Microsoft.PowerShell'
    }

    # --- colour / glyphs ------------------------------------------------------
    $mode = Get-ZetaAnsiMode
    if ($mode -eq 'none') { & $add 'Colour' 'warn' 'disabled (NO_COLOR or ZETA_COLOR=none)' 'Remove NO_COLOR to re-enable' }
    else { & $add 'Colour' 'ok' $mode '' }

    $tier = Get-ZetaGlyphTier
    if ($tier -eq 'ascii') {
        & $add 'Glyphs' 'warn' 'ascii fallback (console is not UTF-8)' 'chcp 65001, or use Windows Terminal'
    }
    elseif ($tier -eq 'unicode') {
        & $add 'Glyphs' 'ok' 'unicode (no Nerd Font detected)' 'Optional: install CaskaydiaCove Nerd Font for powerline separators'
    }
    else { & $add 'Glyphs' 'ok' 'nerd font detected' '' }

    # --- PSReadLine -----------------------------------------------------------
    $psrl = Get-Module -ListAvailable PSReadLine | Sort-Object Version -Descending | Select-Object -First 1
    if ($psrl) {
        $hasPredictions = $false
        try { $hasPredictions = [bool]((Get-PSReadLineOption).PSObject.Properties['PredictionSource']) } catch { }
        & $add 'PSReadLine' 'ok' ("{0} (predictions: {1})" -f $psrl.Version, $hasPredictions) ''
        if (-not $hasPredictions) {
            & $add 'Autosuggestions' 'warn' 'not supported by this PSReadLine' 'Update-Module PSReadLine'
        }
    }
    else { & $add 'PSReadLine' 'warn' 'not installed' 'Install-Module PSReadLine' }

    # --- prompt worker --------------------------------------------------------
    if ($script:ZetaWorkerReady) { & $add 'Background worker' 'ok' 'running (prompt never blocks)' '' }
    else { & $add 'Background worker' 'warn' 'unavailable - segments run synchronously' 'Check $env:ZETA_NO_ASYNC, restart the session' }

    # --- Rust sensor ----------------------------------------------------------
    $core = Get-ZetaCorePath
    if ($core) {
        $version = ''
        try { $version = (& $core version 2>$null | Select-Object -First 1) } catch { }
        & $add 'Sensor binary' 'ok' ("{0} {1}" -f (Split-Path -Leaf $core), $version) ''
    }
    else {
        & $add 'Sensor binary' 'warn' 'zeta-core not built - using pure PowerShell fallback' 'cargo build --release in crates/zeta-core (or run install.ps1 with cargo on PATH)'
    }

    if (Test-ZetaCommand -Name 'git') { & $add 'git' 'ok' ((& git --version 2>$null) -join '') '' }
    else { & $add 'git' 'warn' 'not found - git segment falls back to reading .git/HEAD' 'winget install --id Git.Git' }

    # --- completion -----------------------------------------------------------
    try {
        $completion = Get-ZetaCompletion
        $detail = '{0} (Tab={1}, Shift+Tab={2})' -f $completion.Mode, $(if ($completion.Tab) { $completion.Tab } else { 'unbound' }), $(if ($completion.ShiftTab) { $completion.ShiftTab } else { 'unbound' })
        & $add 'Completion' 'ok' $detail 'zeta completion menu | tab'
        if ($completion.Mode -eq 'predictive' -and $completion.PredictiveSupported -and $completion.PredictionSource -eq 'None') {
            & $add 'Predictions' 'warn' 'predictive mode selected, but PSReadLine has predictions off (redirected console?)' 'Run in Windows Terminal, then: zeta completion predictive'
        }
    }
    catch { & $add 'Completion' 'warn' 'could not read PSReadLine bindings' 'Restart the shell' }

    # --- config / theme -------------------------------------------------------
    $configPath = Get-ZetaConfigPath
    if (Test-Path -LiteralPath $configPath) {
        try {
            [void](ConvertFrom-Json -InputObject (Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop))
            & $add 'config.json' 'ok' $configPath ''
        }
        catch { & $add 'config.json' 'fail' 'invalid JSON' $configPath }
    }
    else { & $add 'config.json' 'ok' 'defaults (no user config yet)' '' }

    $config = Get-ZetaConfig
    $themeFile = Get-ZetaThemeDefinition | Where-Object { $_.Name -eq $config.theme } | Select-Object -First 1
    if ($themeFile) { & $add 'Theme' 'ok' ("{0} ({1})" -f $config.theme, $themeFile.Source) '' }
    else { & $add 'Theme' 'fail' ("'{0}' not found" -f $config.theme) 'Set-ZetaTheme zeta' }

    # --- profile --------------------------------------------------------------
    $profilePath = $PROFILE.CurrentUserAllHosts
    if ($profilePath -and (Test-Path -LiteralPath $profilePath)) {
        $content = Get-Content -LiteralPath $profilePath -Raw -ErrorAction SilentlyContinue
        if ($content -match '# >>> zeta') { & $add 'Profile' 'ok' $profilePath '' }
        else { & $add 'Profile' 'warn' 'Zeta not loaded from profile' 'Run install.ps1, or add: Import-Module Zeta; Initialize-Zeta' }
    }
    else { & $add 'Profile' 'warn' 'no profile file' 'Run install.ps1' }

    # --- terminal -------------------------------------------------------------
    if ($env:WT_SESSION) { & $add 'Terminal' 'ok' 'Windows Terminal' '' }
    elseif ($env:TERM_PROGRAM) { & $add 'Terminal' 'ok' $env:TERM_PROGRAM '' }
    else { & $add 'Terminal' 'warn' 'classic console host' 'Windows Terminal gives truecolor + the themed profile' }

    $fragmentRoot = $null
    if ($env:LOCALAPPDATA) { $fragmentRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\Zeta\zeta.json' }
    if ($fragmentRoot -and (Test-Path -LiteralPath $fragmentRoot)) { & $add 'WT fragment' 'ok' $fragmentRoot '' }
    else { & $add 'WT fragment' 'warn' 'not installed' 'Install-ZetaTerminalProfile' }

    # --- performance ----------------------------------------------------------
    # One throwaway render first: the very first call pays JIT and would poison the average.
    try { [void](Write-ZetaPrompt -Capture) } catch { }
    $samples = @()
    for ($i = 0; $i -lt 5; $i++) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        [void](Write-ZetaPrompt -Capture)
        $sw.Stop()
        $samples += $sw.Elapsed.TotalMilliseconds
    }
    $avg = ($samples | Measure-Object -Average).Average
    $status = 'ok'
    if ($avg -gt 60) { $status = 'fail' } elseif ($avg -gt 30) { $status = 'warn' }
    & $add 'Prompt render' $status ("{0:N1} ms (warm)" -f $avg) ''

    # --- output ---------------------------------------------------------------
    if ($Json) {
        return [pscustomobject]@{
            generatedAt = (Get-Date).ToString('o')
            version     = $script:ZetaVersion
            checks      = @($checks)
        }
    }

    $checks | Format-Table -AutoSize -Wrap Check, Status, Detail | Out-String -Width 160 | Write-Host
    $fails = @($checks | Where-Object { $_.Status -eq 'fail' }).Count
    $warns = @($checks | Where-Object { $_.Status -eq 'warn' }).Count
    $color = 'Green'
    if ($fails -gt 0) { $color = 'Red' } elseif ($warns -gt 0) { $color = 'Yellow' }
    Write-Host ("{0} checks, {1} warnings, {2} failures" -f $checks.Count, $warns, $fails) -ForegroundColor $color

    $fixes = @($checks | Where-Object { $_.Status -ne 'ok' -and $_.Fix })
    if ($fixes.Count -gt 0) {
        Write-Host "`nSuggested fixes:" -ForegroundColor Cyan
        foreach ($item in $fixes) { Write-Host ("  {0}: {1}" -f $item.Check, $item.Fix) -ForegroundColor DarkGray }
    }
}
