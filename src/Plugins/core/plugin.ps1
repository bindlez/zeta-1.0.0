# core: daily-driver helpers. All user-facing functions are defined in global scope.

function global:take {
    <#
    .SYNOPSIS
        Create a directory and enter it (mkdir + cd in one).
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    Set-Location -LiteralPath $Path
}

function global:up {
    <#
    .SYNOPSIS
        Go up N directories (default 1).
    #>
    param([int]$Count = 1)

    for ($i = 0; $i -lt $Count; $i++) { Set-Location .. }
}

function global:extract {
    <#
    .SYNOPSIS
        Extract any common archive with one command.
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "extract: '$Path' not found" }
    $item = Get-Item -LiteralPath $Path
    $destination = Join-Path $item.DirectoryName ([System.IO.Path]::GetFileNameWithoutExtension($item.Name))

    switch -Regex ($item.Extension.ToLowerInvariant()) {
        '^\.(zip|nupkg|vsix)$' {
            if (Get-Command Expand-Archive -ErrorAction SilentlyContinue) {
                Expand-Archive -LiteralPath $item.FullName -DestinationPath $destination -Force
            }
            else {
                Add-Type -AssemblyName System.IO.Compression.FileSystem
                [System.IO.Compression.ZipFile]::ExtractToDirectory($item.FullName, $destination)
            }
        }
        '^\.(tar|tgz|gz)$' { & tar -xf $item.FullName -C (New-Item -ItemType Directory -Force -Path $destination).FullName }
        '^\.(7z|rar)$' {
            if (-not (Get-Command 7z -ErrorAction SilentlyContinue)) { throw 'extract: install 7-Zip (7z on PATH)' }
            & 7z x $item.FullName "-o$destination" -y | Out-Null
        }
        default { throw ("extract: unsupported archive '{0}'" -f $item.Extension) }
    }
    Write-Host ("extracted -> {0}" -f $destination) -ForegroundColor Green
}

function global:mkcd {
    param([Parameter(Mandatory, Position = 0)][string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Set-Location -LiteralPath $Path
}

function global:which {
    <#
    .SYNOPSIS
        Resolve a command the way the shell will.
    #>
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object Name, CommandType, Source
}

Set-Alias -Name ll -Value Get-ChildItem -Scope Global -Force
Set-Alias -Name la -Value Get-ChildItem -Scope Global -Force
