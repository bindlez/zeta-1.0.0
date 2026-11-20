<#
.SYNOPSIS
    Build Zeta: compile the Rust sensor, stage it into the module, optionally package.

.EXAMPLE
    .\build.ps1

.EXAMPLE
    .\build.ps1 -SkipRust -Package
#>
[CmdletBinding()]
param(
    [switch]$SkipRust,
    [switch]$Package,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'dist' }
$started = Get-Date

Write-Host '== Zeta build ==' -ForegroundColor Cyan

if (-not $SkipRust) {
    $crate = Join-Path $root 'crates/zeta-core'
    if (-not (Test-Path -LiteralPath $crate)) { throw "missing crate: $crate" }

    if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Warning 'cargo not found - skipping the Rust sensor. Zeta will use the PowerShell fallback.'
    }
    else {
        Push-Location $crate
        try {
            Write-Host '  cargo test' -ForegroundColor DarkGray
            & cargo test --quiet
            if ($LASTEXITCODE -ne 0) { throw 'cargo test failed' }

            Write-Host '  cargo build --release' -ForegroundColor DarkGray
            & cargo build --release --quiet
            if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }

            $exeName = 'zeta-core'
            if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $exeName = 'zeta-core.exe' }
            $built = Join-Path $crate "target/release/$exeName"
            if (-not (Test-Path -LiteralPath $built)) { throw "build produced no binary at $built" }

            $binDir = Join-Path $root 'src/bin'
            if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Path $binDir | Out-Null }
            Copy-Item -LiteralPath $built -Destination (Join-Path $binDir $exeName) -Force

            $size = [Math]::Round((Get-Item -LiteralPath $built).Length / 1KB, 1)
            Write-Host ("  staged {0} ({1} KB)" -f $exeName, $size) -ForegroundColor Green
        }
        finally { Pop-Location }
    }
}

# Parse check: catches syntax that only fails on 5.1 at runtime.
$parseErrors = @()
Get-ChildItem -Path (Join-Path $root 'src') -Recurse -File | Where-Object { $_.Extension -eq '.ps1' -or $_.Extension -eq '.psd1' } | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in $errors) {
        $parseErrors += [pscustomobject]@{ File = $_.Name; Line = $parseError.Extent.StartLineNumber; Message = $parseError.Message }
    }
}
if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-Table -AutoSize -Wrap | Out-String | Write-Host
    throw "parse errors: $($parseErrors.Count)"
}
Write-Host '  parse check: clean' -ForegroundColor Green

if ($Package) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory | Out-Null }
    $version = '1.0.0'
    $zip = Join-Path $OutputDirectory "zeta-$version.zip"
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

    # Compress-Archive flattens when handed several paths, so stage the exact tree first.
    $stage = Join-Path $OutputDirectory 'stage'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    foreach ($item in @('src', 'docs', 'tests')) {
        $source = Join-Path $root $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $stage -Recurse -Force }
    }
    foreach ($item in @('install.ps1', 'build.ps1', 'README.md')) {
        $source = Join-Path $root $item
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $stage -Force }
    }
    $crateStage = Join-Path $stage 'crates/zeta-core'
    New-Item -ItemType Directory -Path $crateStage -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'crates/zeta-core/Cargo.toml') -Destination $crateStage -Force
    Copy-Item -LiteralPath (Join-Path $root 'crates/zeta-core/src') -Destination $crateStage -Recurse -Force

    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Remove-Item -LiteralPath $stage -Recurse -Force
    Write-Host ("  packaged {0} ({1:N0} KB)" -f $zip, ((Get-Item -LiteralPath $zip).Length / 1KB)) -ForegroundColor Green
}

$elapsed = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
Write-Host ("== done in {0}s ==" -f $elapsed) -ForegroundColor Cyan
