# z: frecency jump. Append-only visit log; the Rust sidecar and this fallback share the format:
#   <unix-seconds>\t<absolute-path>
# Score = sum over visits of 0.5 ^ (age_days / 30) - true frecency, no rewrites, no corruption.

$script:ZetaZHalfLifeDays = 30
$script:ZetaZLastRecorded = ''

function script:Get-ZetaZDatabasePath {
    $root = Get-ZetaDataRoot
    $dbDir = Join-Path $root 'db'
    if (-not (Test-Path -LiteralPath $dbDir)) { New-Item -ItemType Directory -Force -Path $dbDir | Out-Null }
    return (Join-Path $dbDir 'frecency.tsv')
}

function script:Add-ZetaZVisit {
    param([Parameter(Mandatory)][string]$Path)

    # Never record the same directory twice in a row.
    if ($Path -eq $script:ZetaZLastRecorded) { return }
    $script:ZetaZLastRecorded = $Path

    $core = Get-ZetaCorePath
    if ($core) {
        try { & $core z add --path $Path 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { return } } catch { }
    }

    try {
        $line = "{0}`t{1}" -f ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()), $Path
        Add-Content -LiteralPath (Get-ZetaZDatabasePath) -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

function script:Get-ZetaZRanked {
    param([string]$Term, [int]$Limit = 10)

    $core = Get-ZetaCorePath
    if ($core) {
        try {
            $args = @('z', 'query', '--limit', $Limit)
            if ($Term) { $args += @('--term', $Term) }
            $output = & $core @args 2>$null
            if ($LASTEXITCODE -eq 0 -and $output) {
                $results = @()
                foreach ($line in @($output)) {
                    $parts = @([string]$line -split "`t")
                    if ($parts.Count -ge 2) { $results += [pscustomobject]@{ Score = [double]$parts[0]; Path = $parts[1] } }
                }
                if ($results.Count -gt 0) { return $results }
            }
        }
        catch { }
    }

    $db = Get-ZetaZDatabasePath
    if (-not (Test-Path -LiteralPath $db)) { return @() }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $scores = @{}
    $entries = @{}
    try { $lines = Get-Content -LiteralPath $db -ErrorAction Stop } catch { return @() }
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $stamp = 0.0
        if (-not [double]::TryParse($parts[0], [ref]$stamp)) { continue }
        $path = $parts[1]
        if ($Term -and $path.IndexOf($Term, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $ageDays = ($now - $stamp) / 86400.0
        $weight = [Math]::Pow(0.5, ($ageDays / $script:ZetaZHalfLifeDays))
        if (-not $scores.ContainsKey($path)) { $scores[$path] = 0.0; $entries[$path] = $stamp }
        $scores[$path] = $scores[$path] + $weight
        if ($stamp -gt $entries[$path]) { $entries[$path] = $stamp }
    }

    return @($scores.Keys | ForEach-Object {
            [pscustomobject]@{ Score = $scores[$_]; Path = $_ }
        } | Sort-Object -Property Score -Descending | Select-Object -First $Limit)
}

function script:Invoke-ZetaJump {
    param([string]$Term, [switch]$List)

    if ($Term -eq '-') {
        if ($global:ZetaPreviousDirectory -and (Test-Path -LiteralPath $global:ZetaPreviousDirectory)) {
            $target = $global:ZetaPreviousDirectory
            $global:ZetaPreviousDirectory = (Get-Location).Path
            Set-Location -LiteralPath $target
            return
        }
        throw 'z: no previous directory'
    }

    $matches = @(Get-ZetaZRanked -Term $Term -Limit 10)
    if ($matches.Count -eq 0) {
        Write-Host ("z: no match for '{0}'" -f $Term) -ForegroundColor Yellow
        return
    }

    if ($List) {
        $index = 1
        foreach ($match in $matches) {
            Write-Host ("{0,3}  {1,7:N2}  {2}" -f $index, $match.Score, $match.Path)
            $index++
        }
        return
    }

    $global:ZetaPreviousDirectory = (Get-Location).Path
    Set-Location -LiteralPath $matches[0].Path
}

function global:z {
    <#
    .SYNOPSIS
        Jump to a directory by frecency.

    .EXAMPLE
        z zeta
        z -l src
        z -
    #>
    param(
        [Parameter(Position = 0)][string]$Term,
        [switch]$List
    )

    $module = Get-Module -Name Zeta | Select-Object -First 1
    if (-not $module) { throw 'z: Zeta module is not loaded' }
    & $module { param($t, $l) Invoke-ZetaJump -Term $t -List:$l } $Term $List
}

# Record visits when the prompt notices a directory change (cheap: one append per cd).
$script:ZetaVisitHook = {
    param([string]$Path)
    Add-ZetaZVisit -Path $Path
}
