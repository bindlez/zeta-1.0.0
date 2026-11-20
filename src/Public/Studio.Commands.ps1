$script:ZetaStudioJob = $null
$script:ZetaStudioUrl = $null
$script:ZetaStudio = $null

function Start-ZetaThemeStudio {
    <#
    .SYNOPSIS
        Open a local colour editor for themes; saves apply to both shells.

    .DESCRIPTION
        Starts a loopback-only web server in a background job and opens it in the browser.
        Everything is token-gated, so another local process cannot talk to it.

    .PARAMETER Port
        Port to listen on. 0 (default) picks a free one.

    .PARAMETER NoBrowser
        Do not launch a browser (useful for tests and remote sessions).

    .EXAMPLE
        zeta ui

    .EXAMPLE
        Start-ZetaThemeStudio -Port 8099 -NoBrowser
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 0,
        [switch]$NoBrowser,
        [string]$Theme
    )

    if ($script:ZetaStudioJob -and $script:ZetaStudioJob.State -eq 'Running') {
        Write-Host ("Zeta Studio is already running: {0}" -f $script:ZetaStudioUrl) -ForegroundColor Yellow
        return $script:ZetaStudio
    }

    if ($Port -le 0) {
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $Port = [int]$probe.LocalEndpoint.Port
        $probe.Stop()
    }

    $token = [Guid]::NewGuid().ToString('N')
    $manifest = Join-Path $script:ModuleRoot 'Zeta.psd1'

    $job = Start-Job -ScriptBlock {
        param($manifestPath, $port, $token)
        $module = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
        & $module { param($p, $t, $m) Invoke-ZetaStudioServer -Port $p -Token $t -Manifest $m } $port $token $manifestPath
    } -ArgumentList $manifest, $Port, $token

    $url = "http://127.0.0.1:$Port/?token=$token"
    if ($Theme) { $url += '&theme=' + [uri]::EscapeDataString($Theme) }

    # Wait for the socket to answer instead of assuming Start-Job is instant.
    $ready = $false
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($job.State -eq 'Failed') { break }
        try {
            $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/state?token=$token" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            $ready = $true
            break
        }
        catch { }
    }

    if (-not $ready) {
        $reason = ($job.ChildJobs[0].JobStateInfo.Reason)
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw ("Zeta Studio failed to start on port {0}. {1}" -f $Port, $reason)
    }

    $script:ZetaStudioJob = $job
    $script:ZetaStudioUrl = $url
    $script:ZetaStudio = [pscustomobject]@{ Url = $url; Port = $Port; Token = $token; Job = $job }

    if (-not $NoBrowser) { Start-Process $url }
    return $script:ZetaStudio
}

function Stop-ZetaThemeStudio {
    <#
    .SYNOPSIS
        Stop the local colour editor.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:ZetaStudioJob) { return }

    # Ask the server to stop itself: killing a job blocked in AcceptTcpClient leaves it Failed.
    if ($script:ZetaStudio) {
        try {
            $null = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/api/quit?token={1}" -f $script:ZetaStudio.Port, $script:ZetaStudio.Token) -Method Post -TimeoutSec 2
            Start-Sleep -Milliseconds 300
        }
        catch { }
    }

    Stop-Job -Job $script:ZetaStudioJob -ErrorAction SilentlyContinue
    Remove-Job -Job $script:ZetaStudioJob -Force -ErrorAction SilentlyContinue
    $script:ZetaStudioJob = $null
    $script:ZetaStudio = $null
    $script:ZetaStudioUrl = $null
    Write-Host 'Zeta Studio stopped.' -ForegroundColor Green
}
