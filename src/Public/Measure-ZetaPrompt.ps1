function Measure-ZetaPrompt {
    <#
    .SYNOPSIS
        Benchmark prompt rendering. Reports the numbers Zeta is designed against.

    .DESCRIPTION
        Warm runs measure the steady state (async cache hit). -Synchronous forces the
        blocking path so you can see what the background worker is actually buying you.

    .EXAMPLE
        Measure-ZetaPrompt -Count 50

    .EXAMPLE
        Measure-ZetaPrompt -Synchronous -Count 10
    #>
    [CmdletBinding()]
    param(
        [int]$Count = 20,
        [switch]$Synchronous
    )

    if ($Count -lt 1) { throw 'Count must be >= 1' }

    $previous = $env:ZETA_NO_ASYNC
    if ($Synchronous) { $env:ZETA_NO_ASYNC = '1' }
    try {
        $samples = New-Object System.Collections.Generic.List[double]
        for ($i = 0; $i -lt $Count; $i++) {
            if ($Synchronous) { Clear-ZetaCache }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            [void](Write-ZetaPrompt -Capture)
            $sw.Stop()
            $samples.Add($sw.Elapsed.TotalMilliseconds)
        }
    }
    finally {
        if ($Synchronous) {
            if ($null -eq $previous) { Remove-Item Env:\ZETA_NO_ASYNC -ErrorAction SilentlyContinue }
            else { $env:ZETA_NO_ASYNC = $previous }
        }
    }

    $sorted = @($samples | Sort-Object)
    $index = [Math]::Min($sorted.Count - 1, [int][Math]::Ceiling($sorted.Count * 0.95) - 1)
    if ($index -lt 0) { $index = 0 }
    $medianIndex = [Math]::Min($sorted.Count - 1, [int][Math]::Floor($sorted.Count / 2))

    [pscustomobject]@{
        Mode    = $(if ($Synchronous) { 'synchronous' } else { 'async (warm)' })
        Samples = $sorted.Count
        MinMs   = [Math]::Round($sorted[0], 2)
        P50Ms   = [Math]::Round($sorted[$medianIndex], 2)
        AvgMs   = [Math]::Round((($sorted | Measure-Object -Average).Average), 2)
        P95Ms   = [Math]::Round($sorted[$index], 2)
        MaxMs   = [Math]::Round($sorted[$sorted.Count - 1], 2)
    }
}
