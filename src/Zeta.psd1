@{
    RootModule        = 'Zeta.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3c1e0f2-4a7d-4c2f-9a11-5e6d8c0f7a21'
    Author            = 'Zeta'
    CompanyName       = 'Zeta'
    Copyright         = '(c) Zeta contributors. MIT licensed.'
    Description       = 'Zeta - an oh-my-zsh class framework for PowerShell: themeable prompt, plugin system, frecency jump, Windows Terminal theming. Augments PowerShell, never replaces it.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-Zeta'
        'Set-ZetaTheme'
        'Get-ZetaTheme'
        'Get-ZetaThemeList'
        'Enable-ZetaPlugin'
        'Disable-ZetaPlugin'
        'Get-ZetaPlugin'
        'Invoke-ZetaDoctor'
        'Get-ZetaCompletion'
        'Set-ZetaCompletion'
        'Get-ZetaShell'
        'Enter-ZetaShell'
        'Open-ZetaShellTab'
        'Export-ZetaBashTheme'
        'Install-ZetaBashProfile'
        'Open-ZetaShellSplit'
        'Test-ZetaShellHandoff'
        'Start-ZetaThemeStudio'
        'Stop-ZetaThemeStudio'
        'Measure-ZetaPrompt'
        'Install-ZetaTerminalProfile'
        'Update-Zeta'
        'Uninstall-Zeta'
        'zeta'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('prompt', 'theme', 'terminal', 'oh-my-zsh', 'productivity', 'windows-terminal')
            ProjectUri = 'https://github.com/zeta-shell/zeta'
            LicenseUri = 'https://opensource.org/licenses/MIT'
            ReleaseNotes = 'v0.1.0 - initial vertical slice: theme engine, async prompt, plugins, Rust sensor, WT fragment.'
        }
    }
}
