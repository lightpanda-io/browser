$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\wrapped-link"
$port = 8146
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-reload.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-reload.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-reload.server.stdout.txt"
$serverErr = Join-Path $root "chrome-reload.server.stderr.txt"
$png = Join-Path $root "chrome-reload.before.png"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$png -Force -ErrorAction SilentlyContinue

. "$PSScriptRoot\..\common\Win32Input.ps1"

function Count-IndexHits {
  if (-not (Test-Path $serverErr)) { return 0 }
  return ([regex]::Matches((Get-Content $serverErr -Raw), 'GET /index\.html HTTP/1\.1" 200')).Count
}

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$reloadWorked = $false
$initialIndexHits = 0
$finalIndexHits = 0
$failure = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "chrome reload probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$png -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $png) -and ((Get-Item $png).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "chrome reload screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "chrome reload window handle not found" }

  $initialIndexHits = Count-IndexHits

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  [void](Invoke-SmokeClientClick $hwnd 89 40)

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $finalIndexHits = Count-IndexHits
    if ($finalIndexHits -gt $initialIndexHits) {
      $reloadWorked = $true
      break
    }
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    initial_index_hits = $initialIndexHits
    final_index_hits = $finalIndexHits
    reload_worked = $reloadWorked
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
