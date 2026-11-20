# Zeta root module.
# Load order matters: Compat -> Config -> Theme -> Render -> Cache -> Sensors -> Segments -> Prompt -> Plugins -> Terminal
Set-StrictMode -Version 2.0

$script:ModuleRoot  = $PSScriptRoot
$script:ZetaVersion = '1.0.0'
$script:ZetaBoot    = [DateTime]::UtcNow

$privateOrder = @('Compat', 'Config', 'Theme', 'Render', 'Cache', 'Sensors', 'Segments', 'Bash', 'Studio', 'Prompt', 'Plugins', 'Terminal')
foreach ($name in $privateOrder) {
    $path = Join-Path (Join-Path $PSScriptRoot 'Private') "$name.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}

$publicDir = Join-Path $PSScriptRoot 'Public'
if (Test-Path -LiteralPath $publicDir) {
    foreach ($file in (Get-ChildItem -LiteralPath $publicDir -Filter '*.ps1' -File | Sort-Object Name)) {
        . $file.FullName
    }
}

$script:ZetaBootMs = [Math]::Round((([DateTime]::UtcNow) - $script:ZetaBoot).TotalMilliseconds, 2)

Export-ModuleMember -Function @(
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
