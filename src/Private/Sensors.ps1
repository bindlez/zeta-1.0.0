# Sensors: the only place that touches the filesystem / child processes.
# Contract: pure functions, explicit inputs, hashtable output. They run in the main runspace
# AND in the background worker, so they must never read or write module-global mutable state.

function Get-ZetaCorePath {
    # Escape hatch: ZETA_NO_CORE=1 forces the pure-PowerShell path (used by the test suite
    # to prove both implementations agree).
    if ($env:ZETA_NO_CORE -eq '1') { return $null }
    $exe = 'zeta-core'
    if ($script:ZetaIsWindows) { $exe = 'zeta-core.exe' }
    $candidate = Join-Path (Join-Path $script:ModuleRoot 'bin') $exe
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return $null
}

function Get-ZetaRepositoryRoot {
    param([string]$Path)

    if (-not $Path) { $Path = (Get-Location).Path }
    $current = $Path
    for ($i = 0; $i -lt 40; $i++) {
        if (-not $current) { break }
        $dotGit = Join-Path $current '.git'
        if (Test-Path -LiteralPath $dotGit) { return $current }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return $null
}

function Read-ZetaGitDir {
    param([string]$RepositoryRoot)

    $dotGit = Join-Path $RepositoryRoot '.git'
    if (Test-Path -LiteralPath $dotGit -PathType Container) { return $dotGit }
    if (Test-Path -LiteralPath $dotGit -PathType Leaf) {
        # worktree / submodule: ".git" is a file containing "gitdir: <path>"
        try {
            $line = Get-Content -LiteralPath $dotGit -TotalCount 1 -ErrorAction Stop
            if ($line -match '^gitdir:\s*(.+)$') {
                $target = $Matches[1].Trim()
                if (-not [System.IO.Path]::IsPathRooted($target)) {
                    $target = Join-Path $RepositoryRoot $target
                }
                return $target
            }
        }
        catch { }
    }
    return $null
}

function Get-ZetaStashCount {
    param([string]$GitDir)
    if (-not $GitDir) { return 0 }
    $log = Join-Path $GitDir 'logs/refs/stash'
    if (-not (Test-Path -LiteralPath $log)) { return 0 }
    try { return @(Get-Content -LiteralPath $log -ErrorAction Stop).Count } catch { return 0 }
}

function New-ZetaGitResult {
    return @{
        Repo      = $false
        Branch    = ''
        Ahead     = 0
        Behind    = 0
        Staged    = 0
        Modified  = 0
        Untracked = 0
        Conflict  = 0
        Stash     = 0
        Detached  = $false
        Clean     = $true
    }
}

function Get-ZetaSensorGit {
    <#
    .SYNOPSIS
        Repository state for the prompt. Rust sensor first, `git status` second, plain-file third.
    #>
    param([hashtable]$Arguments = @{})

    $path = $Arguments.Path
    if (-not $path) { $path = (Get-Location).Path }

    $result = New-ZetaGitResult
    $root = Get-ZetaRepositoryRoot -Path $path
    if (-not $root) { return $result }
    $result.Repo = $true

    $gitDir = Read-ZetaGitDir -RepositoryRoot $root
    $result.Stash = Get-ZetaStashCount -GitDir $gitDir

    $core = Get-ZetaCorePath
    if ($core) {
        try {
            $raw = & $core git --path $path 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) {
                $parts = @([string]$raw -split "`t")
                if ($parts.Count -ge 10 -and $parts[0] -eq 'OK') {
                    $result.Branch    = $parts[1]
                    $result.Ahead     = [int]$parts[2]
                    $result.Behind    = [int]$parts[3]
                    $result.Staged    = [int]$parts[4]
                    $result.Modified  = [int]$parts[5]
                    $result.Untracked = [int]$parts[6]
                    $result.Conflict  = [int]$parts[7]
                    if ([int]$parts[9] -eq 1) { $result.Detached = $true }
                    $result.Clean = (($result.Staged + $result.Modified + $result.Untracked + $result.Conflict) -eq 0)
                    return $result
                }
            }
        }
        catch { }
    }

    # Fallback: parse porcelain v2 ourselves.
    if (-not (Test-ZetaCommand -Name 'git')) {
        $result.Branch = Get-ZetaBranchFromHead -GitDir $gitDir
        return $result
    }

    try {
        $lines = & git -C $path status --porcelain=v2 --branch --untracked-files=normal --ignore-submodules=dirty 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $lines) {
            $result.Branch = Get-ZetaBranchFromHead -GitDir $gitDir
            return $result
        }
        foreach ($line in $lines) {
            if ($line.StartsWith('# branch.head ')) {
                $result.Branch = $line.Substring(14).Trim()
                if ($result.Branch -eq '(detached)') { $result.Detached = $true; $result.Branch = 'HEAD' }
                continue
            }
            if ($line.StartsWith('# branch.ab ')) {
                $ab = $line.Substring(12).Trim() -split '\s+'
                foreach ($token in $ab) {
                    if ($token -match '^\+(\d+)$') { $result.Ahead = [int]$Matches[1] }
                    if ($token -match '^-(\d+)$') { $result.Behind = [int]$Matches[1] }
                }
                continue
            }
            if ($line.Length -lt 2) { continue }
            if ($line.StartsWith('? ')) { $result.Untracked++; continue }
            if ($line.StartsWith('u ')) { $result.Conflict++; continue }
            if ($line.StartsWith('1 ') -or $line.StartsWith('2 ')) {
                $xy = $line.Substring(2, 2)
                if ($xy[0] -ne '.') { $result.Staged++ }
                if ($xy[1] -ne '.') { $result.Modified++ }
            }
        }
        $result.Clean = (($result.Staged + $result.Modified + $result.Untracked + $result.Conflict) -eq 0)
    }
    catch { }
    return $result
}

function Get-ZetaBranchFromHead {
    param([string]$GitDir)
    if (-not $GitDir) { return '' }
    $head = Join-Path $GitDir 'HEAD'
    if (-not (Test-Path -LiteralPath $head)) { return '' }
    try {
        $line = (Get-Content -LiteralPath $head -TotalCount 1 -ErrorAction Stop).Trim()
        if ($line -match '^ref:\s*refs/heads/(.+)$') { return $Matches[1] }
        if ($line.Length -ge 7) { return $line.Substring(0, 7) }
    }
    catch { }
    return ''
}

function Get-ZetaSensorLangs {
    <#
    .SYNOPSIS
        Detect the project's languages from marker files. No process spawns by design.
    #>
    param([hashtable]$Arguments = @{})

    $path = $Arguments.Path
    if (-not $path) { $path = (Get-Location).Path }

    $found = @()
    $probe = $path
    for ($depth = 0; $depth -lt 4; $depth++) {
        if (-not $probe -or -not (Test-Path -LiteralPath $probe)) { break }

        if (-not ($found | Where-Object { $_.Name -eq 'node' })) {
            $pkg = Join-Path $probe 'package.json'
            if (Test-Path -LiteralPath $pkg) {
                $version = ''
                $nvmrc = Join-Path $probe '.nvmrc'
                if (Test-Path -LiteralPath $nvmrc) {
                    try { $version = (Get-Content -LiteralPath $nvmrc -TotalCount 1 -ErrorAction Stop).Trim().TrimStart('v') } catch { }
                }
                $found += @{ Name = 'node'; Version = $version }
            }
        }

        if (-not ($found | Where-Object { $_.Name -eq 'python' })) {
            $py = Join-Path $probe 'pyproject.toml'
            $venv = $env:VIRTUAL_ENV
            if ((Test-Path -LiteralPath $py) -or (Test-Path -LiteralPath (Join-Path $probe 'requirements.txt')) -or $venv) {
                $version = ''
                $pv = Join-Path $probe '.python-version'
                if (Test-Path -LiteralPath $pv) {
                    try { $version = (Get-Content -LiteralPath $pv -TotalCount 1 -ErrorAction Stop).Trim() } catch { }
                }
                if (-not $version -and $venv) { $version = Split-Path -Leaf $venv }
                $found += @{ Name = 'python'; Version = $version }
            }
        }

        if (-not ($found | Where-Object { $_.Name -eq 'rust' })) {
            $cargo = Join-Path $probe 'Cargo.toml'
            if (Test-Path -LiteralPath $cargo) {
                $version = ''
                $toolchain = Join-Path $probe 'rust-toolchain.toml'
                if (Test-Path -LiteralPath $toolchain) {
                    try {
                        $match = Select-String -LiteralPath $toolchain -Pattern 'channel\s*=\s*"([^"]+)"' -ErrorAction Stop | Select-Object -First 1
                        if ($match) { $version = $match.Matches[0].Groups[1].Value }
                    }
                    catch { }
                }
                $found += @{ Name = 'rust'; Version = $version }
            }
        }

        if (-not ($found | Where-Object { $_.Name -eq 'dotnet' })) {
            $proj = Get-ChildItem -LiteralPath $probe -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.csproj', '.fsproj', '.sln') } | Select-Object -First 1
            if ($proj) {
                $version = ''
                $globalJson = Join-Path $probe 'global.json'
                if (Test-Path -LiteralPath $globalJson) {
                    try {
                        $json = ConvertTo-ZetaHashtable (ConvertFrom-Json -InputObject (Get-Content -LiteralPath $globalJson -Raw -ErrorAction Stop))
                        if ($json.sdk -and $json.sdk.version) { $version = [string]$json.sdk.version }
                    }
                    catch { }
                }
                $found += @{ Name = 'dotnet'; Version = $version }
            }
        }

        if (-not ($found | Where-Object { $_.Name -eq 'go' })) {
            $gomod = Join-Path $probe 'go.mod'
            if (Test-Path -LiteralPath $gomod) {
                $version = ''
                try {
                    $match = Select-String -LiteralPath $gomod -Pattern '^go\s+([0-9.]+)' -ErrorAction Stop | Select-Object -First 1
                    if ($match) { $version = $match.Matches[0].Groups[1].Value }
                }
                catch { }
                $found += @{ Name = 'go'; Version = $version }
            }
        }

        $parent = Split-Path -Parent $probe
        if (-not $parent -or $parent -eq $probe) { break }
        $probe = $parent
    }

    return , @($found | Select-Object -First 3)
}

function Get-ZetaSensorKube {
    param([hashtable]$Arguments = @{})

    $config = $env:KUBECONFIG
    if ($config) { $config = ($config -split ';|:')[0] }
    if (-not $config) { $config = Join-Path $HOME '.kube/config' }
    if (-not (Test-Path -LiteralPath $config)) { return $null }

    try {
        $match = Select-String -LiteralPath $config -Pattern '^current-context:\s*(.+)$' -ErrorAction Stop | Select-Object -First 1
        if ($match) { return $match.Matches[0].Groups[1].Value.Trim().Trim('"', "'") }
    }
    catch { }
    return $null
}

function Get-ZetaSensorBattery {
    if (-not $script:ZetaIsWindows) { return $null }
    try {
        $battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
        if ($battery -and $null -ne $battery.EstimatedChargeRemaining) {
            return @{ Percent = [int]$battery.EstimatedChargeRemaining; Charging = ($battery.BatteryStatus -eq 2) }
        }
    }
    catch { }
    return $null
}

function Get-ZetaSensorTitlePath {
    param([hashtable]$Arguments = @{})
    return (Get-ZetaDisplayPath -Path $Arguments.Path -MaxSegments 2)
}

function Invoke-ZetaSensor {
    <#
    .SYNOPSIS
        Name -> sensor. The single entry point used by both the main thread and the worker.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Arguments = @{}
    )

    switch ($Name) {
        'git'     { return (Get-ZetaSensorGit -Arguments $Arguments) }
        'langs'   { return (Get-ZetaSensorLangs -Arguments $Arguments) }
        'kube'    { return (Get-ZetaSensorKube -Arguments $Arguments) }
        'battery' { return (Get-ZetaSensorBattery) }
        default   { return $null }
    }
}
