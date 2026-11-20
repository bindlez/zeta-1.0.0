function Install-ZetaTerminalProfile {
    <#
    .SYNOPSIS
        Install a Windows Terminal profile fragment themed to match Zeta.

    .DESCRIPTION
        Writes a fragment (never edits settings.json) containing a colour scheme and a
        profile named "Zeta - <theme>". Windows Terminal picks it up on the next launch.

    .EXAMPLE
        Install-ZetaTerminalProfile

    .EXAMPLE
        Install-ZetaTerminalProfile -ThemeName nord -FontFace 'CaskaydiaCove Nerd Font'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ThemeName,
        [string]$FontFace
    )

    if (-not $env:LOCALAPPDATA) { throw 'Windows Terminal integration requires Windows.' }
    if (-not $PSCmdlet.ShouldProcess('Windows Terminal fragment')) { return }

    $path = Write-ZetaTerminalFragment -ThemeName $ThemeName -FontFace $FontFace
    Write-Host ("Windows Terminal fragment written: {0}" -f $path) -ForegroundColor Green
    Write-Host 'Open a new tab - the profile appears as "Zeta - <theme>".' -ForegroundColor DarkGray
    return $path
}
