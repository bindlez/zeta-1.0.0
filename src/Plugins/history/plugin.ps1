# history: search and analyse the command history. Complements PSReadLine's UpArrow search.

function global:h {
    <#
    .SYNOPSIS
        Search command history.

    .EXAMPLE
        h docker
    #>
    param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Term)

    $pattern = ($Term -join ' ')
    $items = Get-History
    if ($pattern) {
        $items = $items | Where-Object { $_.CommandLine -match [regex]::Escape($pattern) }
    }
    $items | Select-Object -Last 25 | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Command = $_.CommandLine }
    } | Format-Table -AutoSize -Wrap
}

function global:hs {
    <#
    .SYNOPSIS
        Your most frequently used commands.
    #>
    param([int]$Top = 15)

    $counts = @{}
    foreach ($item in (Get-History)) {
        $key = $item.CommandLine.Trim()
        if (-not $key) { continue }
        if ($counts.ContainsKey($key)) { $counts[$key]++ } else { $counts[$key] = 1 }
    }
    $counts.GetEnumerator() |
        Sort-Object -Property Value -Descending |
        Select-Object -First $Top |
        ForEach-Object { [pscustomobject]@{ Count = $_.Value; Command = $_.Key } } |
        Format-Table -AutoSize
}

function global:hclear {
    Clear-History
    Write-Host 'history cleared (this session)' -ForegroundColor Green
}

Set-Alias -Name hist -Value Get-History -Scope Global -Force
