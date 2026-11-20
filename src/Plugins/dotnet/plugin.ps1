# dotnet: the five commands you actually type.

function global:dn { dotnet @args }
function global:dnb { dotnet build @args }
function global:dnt { dotnet test @args }
function global:dnr { dotnet run @args }
function global:dnw { dotnet watch run @args }
function global:dnnew {
    param([Parameter(Mandatory, Position = 0)][string]$Template, [Parameter(Position = 1)][string]$Name)
    if ($Name) { dotnet new $Template -o $Name } else { dotnet new $Template }
}
function global:dnclean {
    Get-ChildItem -Recurse -Directory -Filter 'bin' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Recurse -Directory -Filter 'obj' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'bin/ and obj/ removed' -ForegroundColor Green
}
