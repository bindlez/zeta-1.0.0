# git: aliases that stay readable. Functions (not aliases) where arguments are baked in.

function global:gs { git status -sb @args }
function global:gd { git diff @args }
function global:gds { git diff --staged @args }
function global:ga { git add @args }
function global:gaa { git add --all }
function global:gc { git commit @args }
function global:gcm {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    git commit -m $Message
}
function global:gco { git checkout @args }
function global:gcb {
    param([Parameter(Mandatory, Position = 0)][string]$Name)
    git checkout -b $Name
}
function global:gb { git branch @args }
function global:gp { git push @args }
function global:gpl { git pull @args }
function global:gf { git fetch --all --prune }
function global:glog { git log --oneline --graph --decorate -20 @args }
function global:gundo { git reset --soft HEAD~1 }
function global:gclean { git clean -fd }
function global:gstash { git stash @args }

function global:groot {
    <#
    .SYNOPSIS
        cd to the repository root.
    #>
    $root = git rev-parse --show-toplevel 2>$null
    if (-not $root) { throw 'groot: not inside a git repository' }
    Set-Location -LiteralPath $root
}
