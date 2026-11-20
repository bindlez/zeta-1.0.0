# Segment registry. A segment returns a model (text + tone), never a coloured string.
# Adding a segment = one switch branch here; no renderer changes.

function Get-ZetaSegmentCell {
    param(
        [Parameter(Mandatory)][string]$Id,
        [hashtable]$Entry = @{},
        [hashtable]$Theme,
        [hashtable]$State
    )

    $tone = 'text'
    $text = ''
    $icon = ''

    switch ($Id) {
        'context' {
            $user = $env:USERNAME
            if (-not $user) { $user = $env:USER }
            $hostName = [System.Environment]::MachineName
            $remote = [bool]($env:SSH_CONNECTION -or $env:SSH_CLIENT)
            if ($remote) {
                $text = "$user@$hostName"
                $icon = Get-ZetaGlyph 'arrow'
                $tone = 'warn'
            }
            elseif (Test-ZetaElevated) {
                $text = $user
                $icon = Get-ZetaGlyph 'lock'
                $tone = 'err'
            }
        }

        'dir' {
            $path = $State.Path
            $text = Get-ZetaDisplayPath -Path $path -MaxSegments 3 -Shorten
            $homePath = $HOME
            if ($homePath -and $path -eq $homePath) { $icon = Get-ZetaGlyph 'home' }
            else { $icon = Get-ZetaGlyph 'folder' }
            $tone = 'text'
        }

        'git' {
            $git = $State.Git
            if ($git -and $git.Repo -and $git.Branch) {
                $branchGlyph = Get-ZetaGlyph 'branch'
                $text = "$branchGlyph $($git.Branch)"
                $extra = @()
                if ($git.Ahead -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'ahead'), $git.Ahead) }
                if ($git.Behind -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'behind'), $git.Behind) }
                if ($git.Staged -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'plus'), $git.Staged) }
                if ($git.Modified -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'modified'), $git.Modified) }
                if ($git.Untracked -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'untracked'), $git.Untracked) }
                if ($git.Conflict -gt 0) { $extra += ('{0}{1}' -f (Get-ZetaGlyph 'conflict'), $git.Conflict) }
                if ($git.Stash -gt 0) { $extra += ('stash{0}' -f $git.Stash) }
                if ($extra.Count -gt 0) { $text = $text + ' ' + ($extra -join ' ') }
                if ($git.Conflict -gt 0) { $tone = 'err' }
                elseif ($git.Clean) { $tone = 'ok' }
                else { $tone = 'warn' }
            }
        }

        'langs' {
            $langs = $State.Langs
            if ($langs -and $langs.Count -gt 0) {
                $parts = @()
                foreach ($lang in $langs) {
                    $glyph = Get-ZetaGlyph $lang.Name
                    $label = $lang.Name
                    if ($lang.Version) { $label = $lang.Version }
                    if ($glyph) { $parts += "$glyph $label" } else { $parts += $label }
                }
                $text = $parts -join '  '
                $tone = 'info'
            }
        }

        'duration' {
            if ($State.DurationMs -ge 100) {
                $text = '{0} {1}' -f (Get-ZetaGlyph 'timer'), (Format-ZetaDuration $State.DurationMs)
                $tone = 'muted'
            }
        }

        'clock' {
            $text = (Get-Date).ToString('HH:mm')
            $tone = 'muted'
        }

        'status' {
            if ($State.ExitCode -ne 0) {
                $text = ('{0} {1}' -f (Get-ZetaGlyph 'conflict'), $State.ExitCode)
                $tone = 'err'
            }
        }

        'psversion' {
            $text = 'PS ' + $PSVersionTable.PSVersion.ToString(2)
            $tone = 'muted'
        }

        'jobs' {
            $count = @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' }).Count
            if ($count -gt 0) { $text = "$(Get-ZetaGlyph 'bolt') $count"; $tone = 'warn' }
        }

        'admin' {
            if (Test-ZetaElevated) { $text = Get-ZetaGlyph 'lock'; $tone = 'err' }
        }

        'kube' {
            if ($State.Kube) {
                $ctx = [string]$State.Kube
                if ($ctx.Length -gt 22) { $ctx = $ctx.Substring(0, 21) + [char]0x2026 }
                $text = "$(Get-ZetaGlyph 'kube') $ctx"
                $tone = 'info'
            }
        }

        'aws' {
            $profileName = $env:AWS_PROFILE
            if (-not $profileName) { $profileName = $env:AWS_DEFAULT_PROFILE }
            if ($profileName) { $text = "$(Get-ZetaGlyph 'cloud') $profileName"; $tone = 'warn' }
        }

        'docker' {
            if ($env:DOCKER_CONTEXT -and $env:DOCKER_CONTEXT -ne 'default') {
                $text = "$(Get-ZetaGlyph 'docker') $($env:DOCKER_CONTEXT)"
                $tone = 'info'
            }
        }

        'venv' {
            if ($env:VIRTUAL_ENV) {
                $text = "$(Get-ZetaGlyph 'python') $(Split-Path -Leaf $env:VIRTUAL_ENV)"
                $tone = 'ok'
            }
        }

        'battery' {
            $battery = $State.Battery
            if ($battery -and $battery.Percent -lt 100) {
                $text = "$($battery.Percent)%"
                if ($battery.Percent -le 15) { $tone = 'err' } else { $tone = 'muted' }
            }
        }

        'history' {
            if ($State.HistoryId) { $text = "#$($State.HistoryId)"; $tone = 'muted' }
        }

        'hostname' {
            $text = [System.Environment]::MachineName
            $tone = 'muted'
        }

        'time' {
            $text = (Get-Date).ToString('HH:mm:ss')
            $tone = 'muted'
        }

        'date' {
            $text = (Get-Date).ToString('yyyy-MM-dd')
            $tone = 'muted'
        }

        'cwd' {
            $text = $State.Path
            $tone = 'text'
        }

        default {
            return (New-ZetaCell -Id $Id -Text '' -Style 'plain')
        }
    }

    if ($Entry.ContainsKey('icon') -and $Entry.icon) { $icon = [string]$Entry.icon }
    if ($Entry.ContainsKey('prefix') -and $Entry.prefix) { $text = [string]$Entry.prefix + $text }
    if ($Entry.ContainsKey('suffix') -and $Entry.suffix) { $text = $text + [string]$Entry.suffix }

    $fg = $null
    if ($Entry.ContainsKey('fg') -and $Entry.fg) { $fg = Resolve-ZetaColor -Value ([string]$Entry.fg) -Theme $Theme }
    if (-not $fg) { $fg = Get-ZetaToneColor -Theme $Theme -Tone $tone }

    $bg = $null
    if ($Entry.ContainsKey('bg') -and $Entry.bg) { $bg = Resolve-ZetaColor -Value ([string]$Entry.bg) -Theme $Theme }

    $style = 'plain'
    if ($Entry.ContainsKey('style') -and $Entry.style) { $style = [string]$Entry.style }

    return (New-ZetaCell -Id $Id -Text $text -Icon $icon -Fg $fg -Bg $bg -Style $style -Bold:($Entry.ContainsKey('bold') -and $Entry.bold) -Dim:($Entry.ContainsKey('dim') -and $Entry.dim))
}

function Get-ZetaSegmentIds {
    return @(
        'context', 'dir', 'git', 'langs', 'duration', 'clock', 'status', 'psversion',
        'jobs', 'admin', 'kube', 'aws', 'docker', 'venv', 'battery', 'history',
        'hostname', 'time', 'date', 'cwd'
    )
}
