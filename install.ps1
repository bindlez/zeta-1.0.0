<#
.SYNOPSIS
    Install Zeta for the current user. One command, no admin, idempotent.

.DESCRIPTION
    Copies the module into the current user's module path, builds the Rust sensor when cargo
    is available, and adds a marker-delimited block to your PowerShell profile. Re-running it
    upgrades in place: the profile block is replaced, never duplicated.

.PARAMETER Theme
    Theme to activate after install (zeta, tokyo-night, catppuccin-mocha, nord, gruvbox-dark, synthwave).

.PARAMETER SkipBuild
    Do not compile the Rust sensor (uses the pure PowerShell fallback).

.PARAMETER NoProfile
    Install the module only; do not touch $PROFILE.

.PARAMETER Quiet
    Minimal output.

.EXAMPLE
    .\install.ps1

.EXAMPLE
    .\install.ps1 -Theme tokyo-night
#>
[CmdletBinding()]
param(
    [string]$Theme,
    [switch]$SkipBuild,
    [switch]$NoProfile,
    [switch]$NoBashProfile,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$version = '1.0.0'
$moduleName = 'Zeta'

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) { Write-Host ("  {0}" -f $Message) -ForegroundColor DarkGray }
}

if (-not $Quiet) { Write-Host '== Zeta installer ==' -ForegroundColor Cyan }

$source = Join-Path $root 'src'
if (-not (Test-Path -LiteralPath (Join-Path $source 'Zeta.psd1'))) {
    throw "install.ps1 must run from the repository root (missing src/Zeta.psd1)"
}

# --- 1. Rust sensor ----------------------------------------------------------------
if (-not $SkipBuild) {
    $crate = Join-Path $root 'crates/zeta-core'
    $exeName = 'zeta-core'
    # Platform, not edition: PS7 is 'Core' on Windows too and still needs the .exe suffix.
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) { $exeName = 'zeta-core.exe' }
    $staged = Join-Path $source "bin/$exeName"

    if ((Test-Path -LiteralPath $staged) -and -not (Get-Command cargo -ErrorAction SilentlyContinue)) {
        Write-Step 'using the prebuilt sensor'
    }
    elseif (Get-Command cargo -ErrorAction SilentlyContinue) {
        Write-Step 'building sensor (cargo)'
        Push-Location $crate
        try {
            & cargo build --release --quiet
            if ($LASTEXITCODE -ne 0) { throw 'cargo build failed' }
            $built = Join-Path $crate "target/release/$exeName"
            $binDir = Join-Path $source 'bin'
            if (-not (Test-Path -LiteralPath $binDir)) { New-Item -ItemType Directory -Path $binDir | Out-Null }
            Copy-Item -LiteralPath $built -Destination (Join-Path $binDir $exeName) -Force
        }
        finally { Pop-Location }
    }
    else {
        Write-Warning 'cargo not found - installing without the Rust sensor (PowerShell fallback).'
    }
}

# --- 2. Copy the module ------------------------------------------------------------
$documents = [Environment]::GetFolderPath('MyDocuments')
$editions = @()
$currentEdition = 'WindowsPowerShell'
if ($PSVersionTable.PSEdition -eq 'Core') { $currentEdition = 'PowerShell' }
$editions += $currentEdition
# Install for PS7 as well when it is present, so both hosts see the same framework.
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    if ($editions -notcontains 'PowerShell') { $editions += 'PowerShell' }
}

$installed = @()
$profileModuleRoot = $null
foreach ($edition in $editions) {
    $moduleRoot = Join-Path $documents "$edition\Modules\$moduleName"
    $destination = Join-Path $moduleRoot $version
    if (-not (Test-Path -LiteralPath $destination)) { New-Item -ItemType Directory -Path $destination -Force | Out-Null }

    Write-Step ("installing -> {0}" -f $destination)
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force
    $installed += $destination

    # The profile must point at *this* host's module root, not the last edition installed.
    if ($edition -eq $currentEdition) { $profileModuleRoot = $moduleRoot }
}
if ($installed.Count -eq 0) { throw 'no module path available' }

# --- 3. Theme ----------------------------------------------------------------------
if ($Theme) {
    $dataRoot = Join-Path $env:LOCALAPPDATA 'Zeta'
    if (-not (Test-Path -LiteralPath $dataRoot)) { New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null }
    $configPath = Join-Path $dataRoot 'config.json'
    $config = @{}
    if (Test-Path -LiteralPath $configPath) {
        try {
            $parsed = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            foreach ($property in $parsed.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
        catch { $config = @{} }
    }
    $config['theme'] = $Theme
    $config | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configPath -Encoding UTF8
    Write-Step ("theme -> {0}" -f $Theme)
}

# --- 4. Profile --------------------------------------------------------------------
if (-not $NoBashProfile) {
    try {
        # Import the *installed* copy: the bash hook must point at the deployed module, not at
        # the checkout, or it breaks the moment the repo moves.
        Import-Module (Join-Path $installed[0] 'Zeta.psd1') -Force -ErrorAction Stop
        $bashRc = Install-ZetaBashProfile
        Write-Step ("bash profile -> {0}" -f $bashRc)
    }
    catch { Write-Warning ("bash profile not installed: {0}" -f $_.Exception.Message) }
}

if (-not $NoProfile) {
    $profilePath = $PROFILE.CurrentUserAllHosts
    if (-not $profilePath) { $profilePath = Join-Path $documents 'PowerShell\profile.ps1' }
    $profileDir = Split-Path -Parent $profilePath
    if ($profileDir -and -not (Test-Path -LiteralPath $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }

    # The user module path is not always on PSModulePath - notably on machines where Documents
    # is OneDrive-redirected, Windows PowerShell 5.1 does not include it at all. Add it in the
    # profile block rather than assuming Import-Module Zeta will resolve.
    $modulesRoot = Split-Path -Parent $profileModuleRoot
    $block = @(
        '# >>> zeta initialize >>>'
        ('$zetaModuleRoot = ''{0}''' -f $modulesRoot)
        'if ((Test-Path -LiteralPath $zetaModuleRoot) -and ($env:PSModulePath -notlike "*$zetaModuleRoot*")) { $env:PSModulePath = $zetaModuleRoot + ";" + $env:PSModulePath }'
        'Import-Module Zeta -ErrorAction SilentlyContinue'
        'if (Get-Command Initialize-Zeta -ErrorAction SilentlyContinue) { Initialize-Zeta | Out-Null }'
        'Remove-Variable zetaModuleRoot -ErrorAction SilentlyContinue'
        '# <<< zeta initialize <<<'
    ) -join "`r`n"

    $existing = ''
    if (Test-Path -LiteralPath $profilePath) { $existing = Get-Content -LiteralPath $profilePath -Raw }
    $pattern = '(?ms)^# >>> zeta initialize >>>.*?^# <<< zeta initialize <<<\s*'
    $cleaned = [regex]::Replace($existing, $pattern, '')
    $updated = ($cleaned.TrimEnd() + "`r`n`r`n" + $block + "`r`n").TrimStart()
    Set-Content -LiteralPath $profilePath -Value $updated -Encoding UTF8
    Write-Step ("profile -> {0}" -f $profilePath)
}

# --- 5. Verify ---------------------------------------------------------------------
$target = $installed[0]
try {
    Import-Module (Join-Path $target 'Zeta.psd1') -Force -ErrorAction Stop
    Initialize-Zeta -NoHooks -ErrorAction Stop | Out-Null
    # First 1: the source module is also loaded here for Install-ZetaBashProfile, and &
    # on a module array is exactly the kind of thing that fails at the worst moment.
    $rendered = & (Get-Module Zeta | Select-Object -First 1) { Write-ZetaPrompt -Capture }
    if (-not $rendered) { throw 'prompt rendered empty' }
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  prompt preview:' -ForegroundColor DarkGray
        $lines = $rendered -split "`n"
        foreach ($line in $lines) { Write-Host ('    ' + $line) }
    }
    Write-Host ("Zeta {0} installed." -f $version) -ForegroundColor Green
}
catch {
    Write-Warning ("installed, but the self-check failed: {0}" -f $_.Exception.Message)
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  Restart your shell, or load it now:' -ForegroundColor DarkGray
    Write-Host '    . $PROFILE' -ForegroundColor Yellow
    Write-Host '  Then try:  zeta doctor   |   zeta theme list   |   zeta bench' -ForegroundColor DarkGray
}
