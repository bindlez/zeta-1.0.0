# Renderer: segment models -> ANSI text. Measurement happens on the model, never on coloured text.

$script:ZetaAnsiRegex = [regex]'\x1b\[[0-9;]*[A-Za-z]'

function Get-ZetaVisibleLength {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return 0 }
    $stripped = $script:ZetaAnsiRegex.Replace($Text, '')
    $length = 0
    foreach ($ch in $stripped.ToCharArray()) {
        # Wide glyphs (CJK / nerd font icons) occupy two cells. Good enough for prompt layout.
        if ([int]$ch -ge 0x1100 -and ([int]$ch -le 0x115F -or [int]$ch -ge 0x2E80)) { $length += 2 }
        else { $length += 1 }
    }
    return $length
}

function New-ZetaCell {
    param(
        [string]$Id,
        [string]$Text,
        [string]$Icon,
        [string]$Fg,
        [string]$Bg,
        [string]$Style = 'plain',
        [switch]$Bold,
        [switch]$Dim
    )

    if ($Icon -and $Text) { $Text = "$Icon $Text" }
    elseif ($Icon -and -not $Text) { $Text = $Icon }

    return [pscustomobject]@{
        Id    = $Id
        Text  = $Text
        Fg    = $Fg
        Bg    = $Bg
        Style = $Style
        Bold  = [bool]$Bold
        Dim   = [bool]$Dim
    }
}

function Format-ZetaCells {
    <#
    .SYNOPSIS
        Turn cells into a coloured line.

    .DESCRIPTION
        Block cells (pill/block) become self-contained chips: background + padding + trailing
        reset. Gaps between chips are ordinary terminal background, which is why the layout
        looks identical in every glyph tier and never depends on powerline glyphs.
    #>
    param(
        [object[]]$Cells,
        [hashtable]$Theme,
        [string]$Mode = 'truecolor',
        [string]$Separator = '>'
    )

    $visible = @($Cells | Where-Object { $_ -and $_.Text })
    if ($visible.Count -eq 0) { return '' }

    if ($Mode -eq 'none') {
        return (($visible | ForEach-Object { $_.Text }) -join " $Separator ")
    }

    $sb = New-Object System.Text.StringBuilder
    $esc = $script:ZetaEsc
    $reset = $esc + '[0m'
    $defaultFg = Get-ZetaToneColor -Theme $Theme -Tone 'text'
    $previousEndedWithSpace = $false

    for ($i = 0; $i -lt $visible.Count; $i++) {
        $cell = $visible[$i]
        $isBlock = ($cell.Style -eq 'pill' -or $cell.Style -eq 'block') -and $cell.Bg

        # One gap between cells; a chip already ends with padding, so don't double it.
        if ($i -gt 0 -and -not $previousEndedWithSpace) { [void]$sb.Append(' ') }
        if ($i -eq 0 -and -not $isBlock) { [void]$sb.Append(' ') }

        if ($isBlock) {
            $fg = $cell.Fg
            if (-not $fg) { $fg = Get-ZetaToneColor -Theme $Theme -Tone 'bg' }
            [void]$sb.Append((ConvertTo-ZetaAnsi -Hex $cell.Bg -Background -Mode $Mode))
            [void]$sb.Append((ConvertTo-ZetaAnsi -Hex $fg -Mode $Mode))
            if ($cell.Bold) { [void]$sb.Append($esc + '[1m') }
            [void]$sb.Append(' ')
            [void]$sb.Append($cell.Text)
            [void]$sb.Append(' ')
            [void]$sb.Append($reset)
            $previousEndedWithSpace = $true
            continue
        }

        $fg = $cell.Fg
        if (-not $fg) { $fg = $defaultFg }
        [void]$sb.Append((ConvertTo-ZetaAnsi -Hex $fg -Mode $Mode))
        if ($cell.Bold) { [void]$sb.Append($esc + '[1m') }
        if ($cell.Dim) { [void]$sb.Append($esc + '[2m') }
        [void]$sb.Append($cell.Text)
        [void]$sb.Append($reset)
        $previousEndedWithSpace = $false
    }

    return $sb.ToString()
}

function Fit-ZetaCells {
    <#
    .SYNOPSIS
        Drop the least important cells, then ellipsise the directory, until the line fits.
    #>
    param(
        [object[]]$Cells,
        [int]$Width,
        [int]$RightReserve = 0
    )

    $list = New-Object System.Collections.ArrayList
    foreach ($cell in $Cells) { [void]$list.Add($cell) }
    if ($Width -le 0) { return $list.ToArray() }

    $budget = $Width - $RightReserve - 1
    $total = 0
    foreach ($cell in $list) { $total += (Get-ZetaVisibleLength $cell.Text) + 1 }
    if ($total -le $budget) { return $list.ToArray() }

    # Priority: keep context + dir + git. Drop right-most extras first.
    $protected = @('context', 'dir', 'git')
    for ($i = $list.Count - 1; $i -ge 0 -and $total -gt $budget; $i--) {
        if ($protected -contains $list[$i].Id) { continue }
        $total -= (Get-ZetaVisibleLength $list[$i].Text) + 1
        $list.RemoveAt($i)
    }

    if ($total -gt $budget) {
        for ($i = 0; $i -lt $list.Count; $i++) {
            if ($list[$i].Id -ne 'dir') { continue }
            $available = $budget - ($total - (Get-ZetaVisibleLength $list[$i].Text))
            if ($available -lt 6) { break }
            $text = $list[$i].Text
            if ($text.Length -gt $available) {
                $list[$i].Text = $text.Substring(0, [Math]::Max(1, $available - 1)) + [char]0x2026
                $total = $budget
            }
            break
        }
    }

    return $list.ToArray()
}

function Get-ZetaPromptWidth {
    $config = Get-ZetaConfig
    if ($env:ZETA_WIDTH) {
        $forced = 0
        if ([int]::TryParse($env:ZETA_WIDTH, [ref]$forced) -and $forced -gt 0) { return $forced }
    }
    if ($config.prompt.width -and [int]$config.prompt.width -gt 0) { return [int]$config.prompt.width }
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -and $w -gt 20) { return [int]$w }
    }
    catch { }
    return 120
}
