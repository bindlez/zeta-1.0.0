# Zeta Studio: a tiny loopback web UI for editing theme palettes.
#
# Design constraints that shaped this:
#   - No dependencies (no Node, no webserver module): raw TcpListener + hand-parsed HTTP/1.1.
#   - Loopback only, and every API call needs a per-session token, so nothing else on the
#     machine can silently rewrite your theme.
#   - Saves go to the *user* theme directory and immediately recompile the bash view; the
#     prompt caches are mtime-aware, so both shells pick the change up without a restart.

function New-ZetaStudioResponse {
    param(
        [int]$Status = 200,
        [string]$ContentType = 'application/json; charset=utf-8',
        [string]$Body = '',
        [switch]$Quit
    )
    $reason = 'OK'
    switch ($Status) {
        400 { $reason = 'Bad Request' }
        403 { $reason = 'Forbidden' }
        404 { $reason = 'Not Found' }
        500 { $reason = 'Internal Server Error' }
    }
    return @{ Status = $Status; Reason = $reason; ContentType = $ContentType; Body = $Body; Quit = [bool]$Quit }
}

function Read-ZetaStudioRequest {
    param([Parameter(Mandatory)]$Stream)

    $buffer = New-Object byte[] 8192
    $builder = New-Object System.Text.StringBuilder
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        [void]$builder.Append([System.Text.Encoding]::ASCII.GetString($buffer, 0, $read))
        $headerEnd = $builder.ToString().IndexOf("`r`n`r`n")
        if ($builder.Length -gt 65536) { return $null }
    }

    $raw = $builder.ToString()
    $split = $raw.IndexOf("`r`n`r`n")
    $head = $raw.Substring(0, $split)
    $bodySoFar = $raw.Substring($split + 4)
    $lines = $head -split "`r`n"

    $requestLine = $lines[0] -split ' '
    if ($requestLine.Count -lt 2) { return $null }

    $headers = @{}
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $colon = $lines[$i].IndexOf(':')
        if ($colon -gt 0) {
            $headers[$lines[$i].Substring(0, $colon).Trim().ToLowerInvariant()] = $lines[$i].Substring($colon + 1).Trim()
        }
    }

    $length = 0
    if ($headers.ContainsKey('content-length')) { [void][int]::TryParse($headers['content-length'], [ref]$length) }
    $body = $bodySoFar
    while ($body.Length -lt $length) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { break }
        $body += [System.Text.Encoding]::UTF8.GetString($buffer, 0, $read)
    }

    $target = $requestLine[1]
    $path = $target
    $query = @{}
    $question = $target.IndexOf('?')
    if ($question -ge 0) {
        $path = $target.Substring(0, $question)
        foreach ($pair in $target.Substring($question + 1).Split('&')) {
            if (-not $pair) { continue }
            $eq = $pair.IndexOf('=')
            if ($eq -gt 0) {
                $query[[uri]::UnescapeDataString($pair.Substring(0, $eq))] = [uri]::UnescapeDataString($pair.Substring($eq + 1))
            }
        }
    }

    return @{ Method = $requestLine[0].ToUpperInvariant(); Path = $path; Query = $query; Body = $body }
}

function Write-ZetaStudioResponse {
    param($Stream, $Response)

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Response.Body)
    $head = "HTTP/1.1 {0} {1}`r`nContent-Type: {2}`r`nContent-Length: {3}`r`nConnection: close`r`nCache-Control: no-store`r`n`r`n" -f `
        $Response.Status, $Response.Reason, $Response.ContentType, $bodyBytes.Length
    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

function Get-ZetaStudioState {
    $config = Get-ZetaConfig
    $themes = @(Get-ZetaThemeDefinition | ForEach-Object { $_.Name })
    return @{
        active   = [string]$config.theme
        themes   = $themes
        username = $env:USERNAME
        version  = $script:ZetaVersion
    }
}

function Save-ZetaStudioTheme {
    param([string]$Body, [string]$Token)

    try { $payload = ConvertFrom-Json -InputObject $Body -ErrorAction Stop }
    catch { return (New-ZetaStudioResponse -Status 400 -Body '{"error":"invalid json"}') }

    $name = [string]$payload.name
    if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
        return (New-ZetaStudioResponse -Status 400 -Body '{"error":"invalid name"}')
    }

    $theme = Import-ZetaTheme -Name $name
    $palette = @{}
    foreach ($key in $theme.palette.Keys) { $palette[$key] = [string]$theme.palette[$key] }

    $allowed = @('bg', 'surface', 'surface2', 'text', 'muted', 'accent', 'ok', 'warn', 'err', 'info', 'magenta', 'cyan')
    if ($payload.palette) {
        foreach ($property in $payload.palette.PSObject.Properties) {
            if ($allowed -notcontains $property.Name) { continue }
            $value = [string]$property.Value
            if ($value -notmatch '^#[0-9a-fA-F]{6}$') { continue }
            $palette[$property.Name] = $value.ToLowerInvariant()
        }
    }

    $document = @{
        name     = $name
        meta     = @{ variant = 'dark'; blurb = 'Edited in Zeta Studio'; author = $env:USERNAME }
        palette  = $palette
        glyphs   = $theme.glyphs
        prompt   = $theme.prompt
        terminal = $theme.terminal
    }

    $directory = Get-ZetaUserThemePath
    Ensure-ZetaDirectory -Path $directory
    $path = Join-Path $directory "$name.json"
    $json = $document | ConvertTo-Json -Depth 10
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $json, $encoding)

    # Recompile the bash view and drop this theme from the cache so the next render reparses.
    if ($script:ZetaThemeCache.ContainsKey($name)) { [void]$script:ZetaThemeCache.Remove($name) }
    try { [void](Export-ZetaBashTheme -ThemeName $name) } catch { }

    return (New-ZetaStudioResponse -Body (@{ ok = $true; path = $path; palette = $palette } | ConvertTo-Json -Depth 6 -Compress))
}

function Invoke-ZetaStudioRoute {
    param($Request, [string]$Token)

    if ($Request.Query['token'] -ne $Token) {
        return (New-ZetaStudioResponse -Status 403 -Body '{"error":"bad token"}')
    }

    switch ("$($Request.Method) $($Request.Path)") {
        'GET /' {
            $htmlPath = Join-Path (Join-Path $script:ModuleRoot 'Web') 'studio.html'
            if (-not (Test-Path -LiteralPath $htmlPath)) {
                return (New-ZetaStudioResponse -Status 500 -Body '{"error":"studio.html missing"}')
            }
            $html = [System.IO.File]::ReadAllText($htmlPath)
            $html = $html.Replace('__TOKEN__', $Token)
            return (New-ZetaStudioResponse -ContentType 'text/html; charset=utf-8' -Body $html)
        }
        'GET /api/state' {
            return (New-ZetaStudioResponse -Body (Get-ZetaStudioState | ConvertTo-Json -Depth 6 -Compress))
        }
        'GET /api/theme' {
            $name = $Request.Query['name']
            $theme = Import-ZetaTheme -Name $name
            return (New-ZetaStudioResponse -Body (@{ name = $theme.name; palette = $theme.palette } | ConvertTo-Json -Depth 6 -Compress))
        }
        'GET /api/info' {
            $name = $Request.Query['name']
            $definition = Get-ZetaThemeDefinition | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            $source = 'missing'
            $path = ''
            if ($definition) { $source = $definition.Source; $path = $definition.Path }
            return (New-ZetaStudioResponse -Body (@{ name = $name; source = $source; path = $path } | ConvertTo-Json -Compress))
        }
        'POST /api/delete' {
            try { $payload = ConvertFrom-Json -InputObject $Request.Body -ErrorAction Stop }
            catch { return (New-ZetaStudioResponse -Status 400 -Body '{"error":"invalid json"}') }
            $name = [string]$payload.name
            if ($name -notmatch '^[a-z0-9][a-z0-9-]{0,30}$') {
                return (New-ZetaStudioResponse -Status 400 -Body '{"error":"invalid name"}')
            }
            $userPath = Join-Path (Get-ZetaUserThemePath) "$name.json"
            if (-not (Test-Path -LiteralPath $userPath)) {
                return (New-ZetaStudioResponse -Status 400 -Body '{"error":"built-in themes cannot be deleted"}')
            }
            Remove-Item -LiteralPath $userPath -Force
            if ($script:ZetaThemeCache.ContainsKey($name)) { [void]$script:ZetaThemeCache.Remove($name) }
            if ((Get-ZetaConfig).theme -eq $name) { Set-ZetaTheme -Name 'zeta' -Persist -Confirm:$false | Out-Null }
            return (New-ZetaStudioResponse -Body '{"ok":true}')
        }
        'POST /api/save' {
            return (Save-ZetaStudioTheme -Body $Request.Body -Token $Token)
        }
        'POST /api/activate' {
            try { $payload = ConvertFrom-Json -InputObject $Request.Body -ErrorAction Stop }
            catch { return (New-ZetaStudioResponse -Status 400 -Body '{"error":"invalid json"}') }
            $name = [string]$payload.name
            try { Set-ZetaTheme -Name $name -Persist -Confirm:$false | Out-Null }
            catch { return (New-ZetaStudioResponse -Status 400 -Body '{"error":"unknown theme"}') }
            return (New-ZetaStudioResponse -Body '{"ok":true}')
        }
        'POST /api/quit' {
            return (New-ZetaStudioResponse -Body '{"ok":true}' -Quit)
        }
        default {
            return (New-ZetaStudioResponse -Status 404 -Body '{"error":"not found"}')
        }
    }
}

function Invoke-ZetaStudioServer {
    <#
    .SYNOPSIS
        Blocking serve loop. Runs inside a background job; never call it in your shell.
    #>
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Token,
        [Parameter(Mandatory)][string]$Manifest
    )

    # The module is already imported by the job before it calls this function. Re-importing
    # here with -Force would tear down the module that is currently executing.
    if (-not (Get-Module -Name Zeta)) { Import-Module -Name $Manifest -Force -ErrorAction Stop }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()
    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $request = Read-ZetaStudioRequest -Stream $stream
                if ($request) {
                    $response = Invoke-ZetaStudioRoute -Request $request -Token $Token
                    Write-ZetaStudioResponse -Stream $stream -Response $response
                    if ($response.Quit) { break }
                }
            }
            catch { }
            finally { $client.Close() }
        }
    }
    finally { $listener.Stop() }
}
