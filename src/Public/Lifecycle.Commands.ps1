function Update-Zeta {
    <#
    .SYNOPSIS
        Update Zeta from its git checkout and redeploy the module.

    .DESCRIPTION
        Refuses to run when the working tree is dirty. Never downloads and executes remote
        scripts: it runs the local install.ps1 from the checkout it already trusts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $repoRoot = Split-Path -Parent $script:ModuleRoot
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
        Write-Warning ("Zeta: '{0}' is not a git checkout. Reinstall from a release archive instead." -f $script:ModuleRoot)
        return
    }
    if (-not $PSCmdlet.ShouldProcess('Zeta module', 'git pull + install')) { return }

    $dirty = & git -C $repoRoot status --porcelain 2>$null
    if ($dirty) { throw 'Zeta: local changes detected, refusing to update. Commit or stash them first.' }

    $before = (& git -C $repoRoot rev-parse --short HEAD 2>$null)
    & git -C $repoRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'Zeta: git pull failed.' }
    $after = (& git -C $repoRoot rev-parse --short HEAD 2>$null)

    if ($before -eq $after) {
        Write-Host 'Zeta is already up to date.' -ForegroundColor Green
        return
    }

    $installer = Join-Path $repoRoot 'install.ps1'
    if (Test-Path -LiteralPath $installer) {
        & $installer -Quiet
    }
    Write-Host ("Zeta updated {0} -> {1}. Restart the shell." -f $before, $after) -ForegroundColor Green
}

function Uninstall-Zeta {
    <#
    .SYNOPSIS
        Remove Zeta's profile block; optionally delete the installed module.

    .EXAMPLE
        Uninstall-Zeta

    .EXAMPLE
        Uninstall-Zeta -RemoveModule
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param([switch]$RemoveModule)

    $profilePath = $PROFILE.CurrentUserAllHosts
    if ($profilePath -and (Test-Path -LiteralPath $profilePath)) {
        if ($PSCmdlet.ShouldProcess($profilePath, 'remove Zeta block')) {
            $content = Get-Content -LiteralPath $profilePath -Raw
            $pattern = '(?ms)^# >>> zeta initialize >>>.*?^# <<< zeta initialize <<<\s*'
            $updated = [regex]::Replace($content, $pattern, '')
            Set-Content -LiteralPath $profilePath -Value $updated.TrimEnd() -Encoding UTF8
        }
    }

    if ($RemoveModule) {
        if ($PSCmdlet.ShouldProcess($script:ModuleRoot, 'delete Zeta module')) {
            Remove-Item -LiteralPath $script:ModuleRoot -Recurse -Force
        }
    }

    # Bash side: remove only our marker block from ~/.bashrc.
    $bashRc = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.bashrc'
    if (Test-Path -LiteralPath $bashRc) {
        if ($PSCmdlet.ShouldProcess($bashRc, 'remove Zeta block')) {
            $content = Get-Content -LiteralPath $bashRc -Raw
            $pattern = '(?ms)^# >>> zeta initialize >>>.*?^# <<< zeta initialize <<<\s*'
            Set-Content -LiteralPath $bashRc -Value ([regex]::Replace($content, $pattern, '').TrimEnd()) -Encoding ASCII
        }
    }

    try { Remove-Item Function:\global:prompt -ErrorAction SilentlyContinue } catch { }
    Remove-ZetaPromptHooks
    Write-Host 'Zeta removed from this session. Restart the shell to fully unload it.' -ForegroundColor Green
}
