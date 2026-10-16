# specter-login.ps1  (Specter auto-login)
#
# Opens Microsoft Edge (or Chrome) to the stats.fm login, waits for you to sign
# in with Spotify/Apple, reads the resulting `identityToken` cookie, and injects
# it into Specter via specter-link.ps1 - all in PowerShell, no extra installs.
#
# Run:  pwsh -File .\specter-login.ps1       (or: powershell -File .\specter-login.ps1)
# Close Specter first. Run as the same Windows user that runs Specter.

[CmdletBinding()]
param(
    [int]$Port = 9222,
    [int]$TimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'

function Find-Browser {
    $cands = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    throw "Could not find Edge or Chrome. Install one, or edit Find-Browser."
}

# Send one CDP command over a fresh WebSocket and return the parsed JSON reply.
function Invoke-Cdp {
    param([string]$WsUrl, [string]$Method, [hashtable]$Params = @{})
    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    try {
        $cts = [System.Threading.CancellationTokenSource]::new(8000)
        $ws.ConnectAsync([Uri]$WsUrl, $cts.Token).GetAwaiter().GetResult()
        $payload = @{ id = 1; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 6
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, $cts.Token).GetAwaiter().GetResult()
        $sb = [Text.StringBuilder]::new()
        for ($i = 0; $i -lt 50; $i++) {
            $buf = [ArraySegment[byte]]::new((New-Object byte[] 16384))
            $rcts = [System.Threading.CancellationTokenSource]::new(8000)
            $res = $ws.ReceiveAsync($buf, $rcts.Token).GetAwaiter().GetResult()
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf.Array, 0, $res.Count))
            if ($res.EndOfMessage) {
                $obj = $null
                try { $obj = $sb.ToString() | ConvertFrom-Json } catch { $sb.Clear() | Out-Null; continue }
                if ($obj.id -eq 1) { return $obj }
                $sb.Clear() | Out-Null
            }
        }
    } finally { $ws.Dispose() }
    return $null
}

function Read-StatsFmCookie {
    param([int]$Port)
    $targets = (Invoke-RestMethod "http://localhost:$Port/json" -TimeoutSec 5)
    $page = $targets | Where-Object { $_.type -eq 'page' -and $_.url -match 'stats\.fm' } | Select-Object -First 1
    if (-not $page) { $page = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 }
    if (-not $page) { return $null }
    $r = Invoke-Cdp -WsUrl $page.webSocketDebuggerUrl -Method 'Runtime.evaluate' `
        -Params @{ expression = 'document.cookie'; returnByValue = $true }
    return $r.result.result.value
}

# --- launch browser with a throwaway profile + remote debugging ---
$browser = Find-Browser
$profile = Join-Path $env:TEMP ("specter_cdp_{0}" -f ([guid]::NewGuid().ToString('N')))
$args = @(
    "--remote-debugging-port=$Port",
    "--user-data-dir=$profile",
    "--no-first-run", "--no-default-browser-check",
    "https://stats.fm/login"
)
Write-Host "Launching $([IO.Path]::GetFileName($browser)) - sign in with Spotify or Apple in the window..."
$proc = Start-Process -FilePath $browser -ArgumentList $args -PassThru

$token = $null
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($proc.HasExited) { break }
        $cookie = $null
        try { $cookie = Read-StatsFmCookie -Port $Port } catch {}
        if ($cookie -match 'identityToken=([^;]+)') {
            $val = [Uri]::UnescapeDataString($Matches[1])
            if ($val.Split('.').Count -eq 3 -and $val.Length -gt 40) { $token = $val; break }
        }
        Start-Sleep -Milliseconds 1500
    }
} finally {
    if (-not $proc.HasExited) { $proc.CloseMainWindow() | Out-Null; Start-Sleep 1; if (-not $proc.HasExited) { $proc.Kill() } }
    Remove-Item -Recurse -Force $profile -ErrorAction SilentlyContinue
}

if (-not $token) { throw "No identityToken captured (timed out or window closed). Nothing changed." }

Write-Host "Captured token (length $($token.Length)). Injecting into Specter..."
$link = Join-Path $PSScriptRoot 'specter-link.ps1'
if (-not (Test-Path $link)) { throw "specter-link.ps1 not found next to this script ($link)." }
& $link -Token $token
