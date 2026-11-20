# fetch: a fast, dependency-free system panel. Everything is wrapped: a missing CIM class
# on a stripped-down Windows image must print "unknown", not break the command.

function script:Get-ZetaFetchValue {
    param([scriptblock]$Producer, [string]$Default = 'unknown')

    try {
        $value = & $Producer
        if ($null -eq $value -or "$value" -eq '') { return $Default }
        return [string]$value
    }
    catch { return $Default }
}

function script:Write-ZetaFetch {
    param([hashtable]$Theme)

    $mode = Get-ZetaAnsiMode
    $esc = $script:ZetaEsc
    $accent = Get-ZetaToneColor -Theme $Theme -Tone 'accent'
    $muted = Get-ZetaToneColor -Theme $Theme -Tone 'muted'
    $label = Get-ZetaToneColor -Theme $Theme -Tone 'info'
    $textColor = Get-ZetaToneColor -Theme $Theme -Tone 'text'

    $tier = Get-ZetaGlyphTier
    if ($tier -eq 'ascii') {
        $logo = @('=====', '   / ', '  /  ', ' /   ', '=====')
    }
    else {
        $logo = @(
            [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588
            '    ' + [string][char]0x2588
            '  ' + [string][char]0x2588 + [string][char]0x2588
            [string][char]0x2588
            [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588 + [string][char]0x2588
        )
    }

    $os = Get-ZetaFetchValue { (Get-CimInstance Win32_OperatingSystem).Caption } 'Windows'
    $version = Get-ZetaFetchValue { (Get-CimInstance Win32_OperatingSystem).Version } $([System.Environment]::OSVersion.Version.ToString())
    $cpu = Get-ZetaFetchValue { (Get-CimInstance Win32_Processor | Select-Object -First 1).Name } 'CPU'
    $cores = Get-ZetaFetchValue { (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum } '?'
    $memoryGb = Get-ZetaFetchValue {
        $bytes = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        [Math]::Round($bytes / 1GB, 1)
    } '?'
    $uptime = Get-ZetaFetchValue {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $span = (Get-Date) - $boot
        '{0}d {1}h {2}m' -f $span.Days, $span.Hours, $span.Minutes
    } '?'
    $shell = 'PowerShell ' + $PSVersionTable.PSVersion.ToString()
    $terminal = 'console'
    if ($env:WT_SESSION) { $terminal = 'Windows Terminal' }
    elseif ($env:TERM_PROGRAM) { $terminal = $env:TERM_PROGRAM }
    $disk = Get-ZetaFetchValue {
        $drive = (Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop)
        '{0} GB free / {1} GB' -f [Math]::Round($drive.Free / 1GB, 1), [Math]::Round(($drive.Free + $drive.Used) / 1GB, 1)
    } '?'

    $rows = @(
        @('OS', "$os ($version)")
        @('Host', [System.Environment]::MachineName)
        @('Uptime', $uptime)
        @('Shell', $shell)
        @('Terminal', $terminal)
        @('CPU', "$cpu ($cores threads)")
        @('Memory', "$memoryGb GB")
        @('Disk', $disk)
        @('Theme', $Theme.name)
        @('Plugins', ((Get-ZetaLoadedPluginNames) -join ', '))
    )

    $title = 'zeta'
    for ($i = 0; $i -lt $logo.Count; $i++) {
        $logoLine = $logo[$i]
        $row = $null
        if ($i -lt $rows.Count) { $row = $rows[$i] }

        if ($mode -ne 'none') {
            [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $accent -Mode $mode))
            [Console]::Out.Write($logoLine.PadRight(8))
            [Console]::Out.Write($esc + '[0m')
        }
        else {
            [Console]::Out.Write($logoLine.PadRight(8))
        }

        if ($row) {
            if ($mode -ne 'none') {
                [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $label -Mode $mode))
            }
            [Console]::Out.Write($row[0].PadRight(10))
            if ($mode -ne 'none') {
                [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $textColor -Mode $mode))
                [Console]::Out.Write($row[1])
                [Console]::Out.Write($esc + '[0m')
            }
            else { [Console]::Out.Write($row[1]) }
        }
        [Console]::Out.Write("`n")
    }

    # Remaining rows (beyond the logo height).
    for ($i = $logo.Count; $i -lt $rows.Count; $i++) {
        [Console]::Out.Write((' ' * 8))
        if ($mode -ne 'none') { [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $label -Mode $mode)) }
        [Console]::Out.Write($rows[$i][0].PadRight(10))
        if ($mode -ne 'none') {
            [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $textColor -Mode $mode))
            [Console]::Out.Write($rows[$i][1])
            [Console]::Out.Write($esc + '[0m')
        }
        else { [Console]::Out.Write($rows[$i][1]) }
        [Console]::Out.Write("`n")
    }

    if ($mode -ne 'none') { [Console]::Out.Write((ConvertTo-ZetaAnsi -Hex $muted -Mode $mode) + $title + $esc + '[0m' + "`n") }
}

function global:fetch {
    <#
    .SYNOPSIS
        Print a system information panel.
    #>
    $module = Get-Module -Name Zeta | Select-Object -First 1
    if (-not $module) { throw 'fetch: Zeta module is not loaded' }
    & $module {
        $config = Get-ZetaConfig
        Write-ZetaFetch -Theme (Import-ZetaTheme -Name $config.theme)
    }
}
