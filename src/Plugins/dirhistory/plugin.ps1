# dirhistory: a j(ump) list you can walk with Alt+Left / Alt+Right.
# Note: this plugin rebinds Alt+Left/Right (word navigation) - enable it only if you want that.

$script:ZetaDirBack = New-Object System.Collections.Stack
$script:ZetaDirForward = New-Object System.Collections.Stack

function global:back {
    <#
    .SYNOPSIS
        Go to the previous directory in the jump list.
    #>
    if ($script:ZetaDirBack.Count -eq 0) { return }
    $script:ZetaDirForward.Push((Get-Location).Path)
    Set-Location -LiteralPath $script:ZetaDirBack.Pop()
}

function global:forward {
    <#
    .SYNOPSIS
        Go forward again after `back`.
    #>
    if ($script:ZetaDirForward.Count -eq 0) { return }
    $script:ZetaDirBack.Push((Get-Location).Path)
    Set-Location -LiteralPath $script:ZetaDirForward.Pop()
}

# Track history through the prompt hook rather than overriding Set-Location.
$script:ZetaDirLastPath = (Get-Location).Path
$script:ZetaVisitHook = {
    param([string]$Path)

    if ($script:ZetaDirLastPath -and $Path -ne $script:ZetaDirLastPath) {
        $script:ZetaDirBack.Push($script:ZetaDirLastPath)
        $script:ZetaDirForward.Clear()
        # Keep the stack bounded.
        while ($script:ZetaDirBack.Count -gt 200) { [void]$script:ZetaDirBack.Pop() }
    }
    $script:ZetaDirLastPath = $Path
}

try {
    Set-PSReadLineKeyHandler -Key 'Alt+LeftArrow' -ScriptBlock {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        back
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
    Set-PSReadLineKeyHandler -Key 'Alt+RightArrow' -ScriptBlock {
        [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
        forward
        [Microsoft.PowerShell.PSConsoleReadLine]::InvokePrompt()
    }
}
catch { Write-Verbose 'dirhistory: PSReadLine key handlers unavailable' }
