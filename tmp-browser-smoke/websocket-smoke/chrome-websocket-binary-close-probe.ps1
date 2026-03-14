$ErrorActionPreference = 'Stop'

$root = 'C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\websocket-smoke'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$browserExe = if ($env:LIGHTPANDA_BROWSER_EXE) { $env:LIGHTPANDA_BROWSER_EXE } else { Join-Path $repo 'zig-out\bin\lightpanda.exe' }
$serverScript = Join-Path $root 'websocket_server.py'
$browserOut = Join-Path $root 'websocket-binary-close.browser.stdout.txt'
$browserErr = Join-Path $root 'websocket-binary-close.browser.stderr.txt'
$serverOut = Join-Path $root 'websocket-binary-close.server.stdout.txt'
$serverErr = Join-Path $root 'websocket-binary-close.server.stderr.txt'
$profileRoot = Join-Path $root 'profile-websocket-binary-close'
$appDataRoot = Join-Path $profileRoot 'lightpanda'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot 'browse-settings-v1.txt') -NoNewline

function Get-FreePort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try { return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
}

function Get-ProcessCommandLine($TargetPid) {
  $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue | Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($meta) { return [string]$meta.CommandLine }
  return ''
}

function Stop-VerifiedProcess($TargetPid) {
  $cmd = Get-ProcessCommandLine $TargetPid
  if ($cmd -and $cmd -notmatch 'codex\.js|@openai/codex') {
    try { Stop-Process -Id $TargetPid -Force -ErrorAction Stop } catch {
      if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) { throw }
    }
  }
}

$port = Get-FreePort
$pageUrl = "http://127.0.0.1:$port/index.html?mode=binary-close"
$server = $null
$browser = $null
$ready = $false
$titleReady = $false
$failure = $null

try {
  $server = Start-Process -FilePath 'python' -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw 'websocket binary-close server did not become ready' }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList 'browse',$pageUrl,'--window_width','840','--window_height','560' -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if (-not $proc) { break }
    if ($proc.MainWindowHandle -eq 0) { continue }
    if ($proc.MainWindowTitle -like '*WebSocket Binary Close Ready*') {
      $titleReady = $true
      break
    }
    if ($proc.MainWindowTitle -like '*WebSocket Binary Close Error*') {
      break
    }
  }

  if (-not $titleReady) {
    $lastTitle = (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue).MainWindowTitle
    throw "websocket binary-close page did not reach ready title; last title: $lastTitle"
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  if ($browser) {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
  }
  if ($server) {
    Stop-VerifiedProcess $server.Id
    for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
  }

  $result = [ordered]@{
    ready = $ready
    title_ready = $titleReady
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_gone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
    server_gone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
    error = if ($failure) { $failure } else { '' }
    browser_stderr = if (Test-Path $browserErr) { (Get-Content $browserErr -Raw) -replace "`r","\\r" -replace "`n","\\n" } else { '' }
    server_stderr = if (Test-Path $serverErr) { (Get-Content $serverErr -Raw) -replace "`r","\\r" -replace "`n","\\n" } else { '' }
  }
  $result | ConvertTo-Json -Depth 5

  if ($failure -or -not $ready -or -not $titleReady) {
    exit 1
  }
}
