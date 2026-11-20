# docker: shortcuts for the 90% of docker invocations.

function global:dps { docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' }
function global:dpa { docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' }
function global:di { docker images }
function global:dstop { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Name) docker stop @Name }
function global:drm { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Name) docker rm @Name }
function global:dlog { param([Parameter(Mandatory, Position = 0)][string]$Name) docker logs -f --tail 200 $Name }
function global:dsh {
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    docker exec -it $Name sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'
}
function global:dclean {
    docker system prune -af --volumes
}
