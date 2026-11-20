function zeta {
    <#
    .SYNOPSIS
        Zeta command surface: theme / plugin / doctor / bench / update.

    .EXAMPLE
        zeta theme list
        zeta theme set tokyo-night
        zeta plugin list
        zeta doctor
        zeta bench -Count 50
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Command = 'help',
        [Parameter(Position = 1)][string]$Argument,
        [Parameter(Position = 2)][string]$Argument2,
        [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
    )

    switch ($Command.ToLowerInvariant()) {
        'theme' {
            switch ($Argument) {
                'list' { Get-ZetaThemeList | Format-Table -AutoSize; return }
                'set'  {
                    if (-not $Argument2) { throw 'usage: zeta theme set <name>' }
                    Set-ZetaTheme -Name $Argument2 -Persist
                    Write-Host ("Theme: {0}" -f $Argument2) -ForegroundColor Green
                    return
                }
                'show' {
                    $name = $Argument2
                    if (-not $name) { Get-ZetaTheme } else { Get-ZetaTheme -Name $name }
                    return
                }
                'edit' { return (Start-ZetaThemeStudio -Theme $Argument2) }
                default {
                    Write-Host 'usage: zeta theme list | set <name> | show [name]' -ForegroundColor Yellow
                    return
                }
            }
        }
        'plugin' {
            switch ($Argument) {
                'list' { Get-ZetaPlugin | Format-Table -AutoSize -Wrap; return }
                'add'  {
                    if (-not $Argument2) { throw 'usage: zeta plugin add <name>' }
                    [void](Enable-ZetaPlugin -Name $Argument2)
                    Write-Host ("Plugin enabled: {0}" -f $Argument2) -ForegroundColor Green
                    return
                }
                'remove' {
                    if (-not $Argument2) { throw 'usage: zeta plugin remove <name>' }
                    [void](Disable-ZetaPlugin -Name $Argument2)
                    Write-Host ("Plugin disabled: {0}" -f $Argument2) -ForegroundColor Green
                    return
                }
                default {
                    Write-Host 'usage: zeta plugin list | add <name> | remove <name>' -ForegroundColor Yellow
                    return
                }
            }
        }
        'doctor' { return (Invoke-ZetaDoctor) }
        'ui' { return (Start-ZetaThemeStudio) }
        'studio' { return (Start-ZetaThemeStudio) }
        'shell' {
            switch ($Argument) {
                { $_ -in @('bash', 'pwsh', 'powershell') } { return (Enter-ZetaShell -Name $Argument) }
                'ps' { return (Enter-ZetaShell -Name 'powershell') }
                'tab' {
                    $tabShell = 'bash'
                    if ($Argument2) { $tabShell = $Argument2 }
                    return (Open-ZetaShellTab -Name $tabShell)
                }
                'split' {
                    $splitShell = 'bash'
                    if ($Argument2) { $splitShell = $Argument2 }
                    return (Open-ZetaShellSplit -Name $splitShell)
                }
                'diagnose' { return (Test-ZetaShellHandoff) }
                default { return (Get-ZetaShell) }
            }
        }
        'completion' {
            switch ($Argument) {
                { $_ -in @('tab', 'menu', 'predictive') } {
                    return (Set-ZetaCompletion -Mode $Argument)
                }
                default { return (Get-ZetaCompletion) }
            }
        }
        'bench'  { return (Measure-ZetaPrompt -Count 20) }
        'update' { return (Update-Zeta) }
        'version' {
            $core = Get-ZetaCorePath
            $coreVersion = 'not built'
            if ($core) { try { $coreVersion = (& $core version 2>$null | Select-Object -First 1) } catch { } }
            return [pscustomobject]@{
                Zeta      = $script:ZetaVersion
                PowerShell = $PSVersionTable.PSVersion.ToString()
                Sensor    = $coreVersion
                Module    = $script:ModuleRoot
                Config    = (Get-ZetaConfigPath)
            }
        }
        'reload' {
            $moduleName = 'Zeta'
            Remove-Module -Name $moduleName -Force -ErrorAction SilentlyContinue
            Import-Module -Name $script:ModuleRoot -Force
            Initialize-Zeta
            Write-Host 'Zeta reloaded.' -ForegroundColor Green
            return
        }
        default {
            Write-Host @'
Zeta - an oh-my-zsh class framework for PowerShell

  zeta theme list            list themes
  zeta theme set <name>      switch theme (persisted)
  zeta theme show [name]     inspect a theme
  zeta theme edit [name]     open the colour studio on that theme
  zeta plugin list           list plugins and their state
  zeta plugin add <name>     enable a plugin (persisted)
  zeta plugin remove <name>  disable a plugin
  zeta doctor                diagnose setup + performance
  zeta ui                    local colour studio for themes (saves to both shells)
  zeta completion [tab|menu|predictive]
                             switch Tab completion style (Shift+Tab gives the other one)
  zeta shell [bash|pwsh|powershell]
                             enter another shell here; bash returns in the directory it ended in
  zeta shell tab [bash|pwsh]  open a peer Windows Terminal tab at this directory
  zeta shell split [bash]     split the window: both shells side by side, same directory
  zeta shell diagnose         check every link in the bash handoff and name the broken one
  zeta shell list             which shells were found
  zeta bench                 benchmark the prompt
  zeta update                update from git checkout
  zeta reload                reload the module in place
  zeta version               versions and paths

  Segment ids: context dir git langs duration clock status psversion jobs
               admin kube aws docker venv battery history hostname time date cwd
'@ -ForegroundColor DarkGray
            return
        }
    }
}
