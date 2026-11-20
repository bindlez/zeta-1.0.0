# python: virtualenv ergonomics without remembering the activation path.

function global:venv {
    <#
    .SYNOPSIS
        Create (if needed) and activate a virtual environment.

    .EXAMPLE
        venv
        venv .venv312
    #>
    param([string]$Name = '.venv')

    if (-not (Test-Path -LiteralPath $Name)) {
        Write-Host "creating $Name ..." -ForegroundColor DarkGray
        $python = 'python'
        if (-not (Get-Command $python -ErrorAction SilentlyContinue)) { $python = 'py' }
        & $python -m venv $Name
        if ($LASTEXITCODE -ne 0) { throw 'venv: creation failed' }
    }

    $activate = Join-Path $Name 'Scripts/Activate.ps1'
    if (-not (Test-Path -LiteralPath $activate)) { $activate = Join-Path $Name 'bin/Activate.ps1' }
    if (-not (Test-Path -LiteralPath $activate)) { throw "venv: no activation script in $Name" }
    . $activate
    Write-Host ("activated {0}" -f $Name) -ForegroundColor Green
}

function global:pyclean {
    <#
    .SYNOPSIS
        Remove __pycache__ and .pyc files recursively.
    #>
    $removed = 0
    Get-ChildItem -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed++
    }
    Get-ChildItem -Recurse -File -Include '*.pyc', '*.pyo' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-Host ("removed {0} __pycache__ directories" -f $removed) -ForegroundColor Green
}
