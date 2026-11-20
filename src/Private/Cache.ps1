# TTL cache + one background runspace.
# Design rule: the prompt never waits for IO. Stale values are served while a refresh runs.

$script:ZetaCache = @{}
$script:ZetaWorkerRunspace = $null
$script:ZetaWorkerPowerShell = $null
$script:ZetaWorkerHandle = $null
$script:ZetaWorkerKey = $null
$script:ZetaWorkerTtl = 2000
$script:ZetaWorkerQueue = $null
$script:ZetaWorkerPending = @{}
$script:ZetaWorkerReady = $false
$script:ZetaWorkerFailures = 0

function Get-ZetaCacheEntry {
    param([Parameter(Mandatory)][string]$Key)
    if ($script:ZetaCache.ContainsKey($Key)) { return $script:ZetaCache[$Key] }
    return $null
}

function Set-ZetaCacheValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        $Value,
        [int]$Ttl = 2000
    )
    $script:ZetaCache[$Key] = @{
        Value = $Value
        Stamp = [DateTime]::UtcNow
        Ttl   = $Ttl
    }
}

function Clear-ZetaCache {
    $script:ZetaCache = @{}
}

function Initialize-ZetaWorker {
    <#
    .SYNOPSIS
        Create the single worker runspace and warm the module inside it.
    #>
    if ($script:ZetaWorkerReady) { return $true }
    $config = Get-ZetaConfig
    if (-not $config.async) { return $false }
    if ($env:ZETA_NO_ASYNC -eq '1') { return $false }

    try {
        $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        $rs = [runspacefactory]::CreateRunspace($iss)
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()

        $manifest = Join-Path $script:ModuleRoot 'Zeta.psd1'
        $warm = [powershell]::Create()
        $warm.Runspace = $rs
        [void]$warm.AddScript('param($m) Import-Module -Name $m -Force -DisableNameChecking -ErrorAction Stop; $true').AddArgument($manifest)
        $result = $warm.Invoke()
        $warm.Dispose()

        if (-not $result -or -not $result[0]) { throw 'worker module import failed' }

        $script:ZetaWorkerRunspace = $rs
        $script:ZetaWorkerQueue = New-Object System.Collections.Queue
        $script:ZetaWorkerPending = @{}
        $script:ZetaWorkerReady = $true
        return $true
    }
    catch {
        $script:ZetaWorkerReady = $false
        $script:ZetaWorkerFailures++
        Write-Verbose ("Zeta: background worker unavailable ({0}); segments run synchronously." -f $_.Exception.Message)
        return $false
    }
}

function Submit-ZetaWorker {
    <#
    .SYNOPSIS
        Request a sensor refresh. Deduplicated: a key can be in flight or queued once, never twice.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Sensor,
        [hashtable]$Arguments = @{},
        [int]$Ttl = 2000
    )

    if (-not $script:ZetaWorkerReady) { return $false }
    if ($script:ZetaWorkerKey -eq $Key) { return $true }
    if ($script:ZetaWorkerPending.ContainsKey($Key)) { return $true }

    $payload = @{ Key = $Key; Sensor = $Sensor; Arguments = $Arguments; Ttl = $Ttl }

    if ($script:ZetaWorkerHandle -and -not $script:ZetaWorkerHandle.IsCompleted) {
        # One in-flight sensor at a time; queue the rest, but never the same key twice.
        if ($script:ZetaWorkerPending.Count -ge 64) { return $false }
        $script:ZetaWorkerPending[$Key] = $true
        $script:ZetaWorkerQueue.Enqueue($payload)
        return $true
    }
    return (Start-ZetaWorkerJob -Payload $payload)
}

function Start-ZetaWorkerJob {
    param([hashtable]$Payload)

    try {
        if (-not $script:ZetaWorkerPowerShell) {
            $script:ZetaWorkerPowerShell = [powershell]::Create()
            $script:ZetaWorkerPowerShell.Runspace = $script:ZetaWorkerRunspace
        }
        $ps = $script:ZetaWorkerPowerShell
        $ps.Commands.Clear()
        # Run inside the module's own scope: private functions are not exported.
        [void]$ps.AddScript('param($sn, $sa) $mod = Get-Module Zeta; if (-not $mod) { return $null }; & $mod { param($n, $a) Invoke-ZetaSensor -Name $n -Arguments $a } $sn $sa').AddArgument($Payload.Sensor).AddArgument($Payload.Arguments)
        $script:ZetaWorkerHandle = $ps.BeginInvoke()
        $script:ZetaWorkerKey = $Payload.Key
        $script:ZetaWorkerTtl = $Payload.Ttl
        return $true
    }
    catch {
        $script:ZetaWorkerHandle = $null
        $script:ZetaWorkerKey = $null
        $script:ZetaWorkerFailures++
        if ($script:ZetaWorkerPending.ContainsKey($Payload.Key)) { [void]$script:ZetaWorkerPending.Remove($Payload.Key) }
        return $false
    }
}

function Receive-ZetaWorker {
    <#
    .SYNOPSIS
        Drain at most one finished job, store its value, and start the next queued one.
    #>
    if (-not $script:ZetaWorkerReady) { return }
    if (-not $script:ZetaWorkerHandle -or -not $script:ZetaWorkerHandle.IsCompleted) { return }

    $key = $script:ZetaWorkerKey
    $ttl = $script:ZetaWorkerTtl
    try {
        $output = $script:ZetaWorkerPowerShell.EndInvoke($script:ZetaWorkerHandle)
        $hadError = ($script:ZetaWorkerPowerShell.Streams.Error.Count -gt 0)
        if ($hadError) {
            $script:ZetaWorkerPowerShell.Streams.Error.Clear()
            # Back off instead of hammering a sensor that keeps failing.
            if ($key) { Set-ZetaCacheValue -Key $key -Value $null -Ttl 10000 }
        }
        elseif ($key) {
            $value = $null
            if ($output -and $output.Count -gt 0) {
                $value = $output[0]
                if ($value -is [System.Management.Automation.PSObject]) { $value = $value.BaseObject }
            }
            # Even an empty result is cached: otherwise "no languages here" is re-probed forever.
            Set-ZetaCacheValue -Key $key -Value $value -Ttl $ttl
        }
    }
    catch {
        $script:ZetaWorkerFailures++
        if ($key) { Set-ZetaCacheValue -Key $key -Value $null -Ttl 10000 }
    }
    finally {
        $script:ZetaWorkerHandle = $null
        $script:ZetaWorkerKey = $null
    }

    if ($script:ZetaWorkerQueue -and $script:ZetaWorkerQueue.Count -gt 0) {
        $next = $script:ZetaWorkerQueue.Dequeue()
        if ($script:ZetaWorkerPending.ContainsKey($next.Key)) { [void]$script:ZetaWorkerPending.Remove($next.Key) }
        [void](Start-ZetaWorkerJob -Payload $next)
    }
}

function Get-ZetaCached {
    <#
    .SYNOPSIS
        Fresh -> use. Stale -> use + refresh in background. Missing -> refresh, return fallback.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Sensor,
        [hashtable]$Arguments = @{},
        [int]$Ttl = 2000,
        $Fallback = $null
    )

    $entry = Get-ZetaCacheEntry -Key $Key
    if ($entry) {
        $age = ([DateTime]::UtcNow - $entry.Stamp).TotalMilliseconds
        if ($age -lt $entry.Ttl) { return $entry.Value }
    }

    $config = Get-ZetaConfig
    $async_ok = $script:ZetaWorkerReady -and $config.async -and ($env:ZETA_NO_ASYNC -ne '1')

    if ($async_ok) {
        [void](Submit-ZetaWorker -Key $Key -Sensor $Sensor -Arguments $Arguments -Ttl $Ttl)
        if ($entry) { return $entry.Value }
        return $Fallback
    }

    # Synchronous path (async disabled or worker unavailable).
    try {
        $value = Invoke-ZetaSensor -Name $Sensor -Arguments $Arguments
        Set-ZetaCacheValue -Key $Key -Value $value -Ttl $Ttl
        return $value
    }
    catch {
        return $Fallback
    }
}

function Initialize-ZetaPrime {
    <#
    .SYNOPSIS
        One-time blocking warm-up of the sensors the first prompt needs.

    .DESCRIPTION
        Without this the first prompt would render with no git segment, and the user would not
        see it until their first command finished. ~40ms once, at shell start, is the right trade.
    #>
    param([switch]$IncludeBattery)

    $config = Get-ZetaConfig
    $path = (Get-Location).Path
    foreach ($sensor in @('git', 'langs')) {
        try {
            $value = Invoke-ZetaSensor -Name $sensor -Arguments @{ Path = $path }
            $ttl = $config.cache.git
            if ($sensor -eq 'langs') { $ttl = $config.cache.langs }
            Set-ZetaCacheValue -Key ("{0}|{1}" -f $sensor, $path) -Value $value -Ttl $ttl
        }
        catch { }
    }
    if ($IncludeBattery) {
        try {
            $battery = Invoke-ZetaSensor -Name 'battery' -Arguments @{}
            Set-ZetaCacheValue -Key 'battery' -Value $battery -Ttl 60000
        }
        catch { }
    }
}
