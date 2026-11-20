# clip: clipboard helpers. Set-Clipboard exists on 5.1 and 7.

function global:copypath {
    <#
    .SYNOPSIS
        Copy the current directory (or a given path) to the clipboard.
    #>
    param([string]$Path)

    if (-not $Path) { $Path = (Get-Location).Path }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Set-Clipboard -Value $resolved
    Write-Host ("copied: {0}" -f $resolved) -ForegroundColor Green
}

function global:copyfile {
    <#
    .SYNOPSIS
        Copy file contents (not the path) to the clipboard.
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "copyfile: '$Path' not found" }
    Set-Clipboard -Value (Get-Content -LiteralPath $Path -Raw)
    Write-Host ("copied contents of {0}" -f (Split-Path -Leaf $Path)) -ForegroundColor Green
}

function global:pastefile {
    <#
    .SYNOPSIS
        Write the clipboard to a file.
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    Set-Content -LiteralPath $Path -Value (Get-Clipboard -Raw) -Encoding UTF8
    Write-Host ("wrote {0}" -f $Path) -ForegroundColor Green
}
