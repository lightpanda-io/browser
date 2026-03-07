$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\stop-loading"
$port = 8152
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "slow_server.py"
$browserOut = Join-Path $root "chrome-stop.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-stop.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-stop.server.stdout.txt"
$serverErr = Join-Path $root "chrome-stop.server.stderr.txt"
$beforePng = Join-Path $root "chrome-stop.before.png"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$beforePng -Force -ErrorAction SilentlyContinue

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\Win32Input.ps1")

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$browserRunningAfterStop = $false
$liveContextRestored = $false
$titleBefore = $null
$titleAfterStop = $null
$titleAfterResume = $null
$slowStarted = $false
$serverSawAbort = $false
$serverSawResponse = $false
$failure = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/ping" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "stop probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$beforePng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $beforePng) -and ((Get-Item $beforePng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "stop probe screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "stop probe window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  [void](Invoke-SmokeClientClick $hwnd 120 40)
  Start-Sleep -Milliseconds 200
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 100
  Send-SmokeText "http://127.0.0.1:$port/slow.html"
  Start-Sleep -Milliseconds 200
  Send-SmokeEnter

  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $serverErr) {
      $serverLog = Get-Content $serverErr -Raw
      if ($serverLog -match 'SLOW_RESPONSE_BEGIN /slow\.html') {
        $slowStarted = $true
        break
      }
    }
  }
  if (-not $slowStarted) { throw "slow navigation did not begin" }

  [void](Invoke-SmokeClientClick $hwnd 89 40)
  Start-Sleep -Milliseconds 250

  $procAfter = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
  $browserRunningAfterStop = $null -ne $procAfter
  if (-not $browserRunningAfterStop) {
    throw "browser exited after stop"
  }
  $titleAfterStop = Get-SmokeWindowTitle $hwnd

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $procTick = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    $browserRunningAfterStop = $null -ne $procTick
    if (-not $browserRunningAfterStop) {
      break
    }
    $currentTitle = Get-SmokeWindowTitle $hwnd
    if ($currentTitle -ne $titleAfterStop -and $currentTitle -like "Stop Restore Tick *") {
      $titleAfterResume = $currentTitle
      $liveContextRestored = $true
    }
    if (Test-Path $serverErr) {
      $serverLog = Get-Content $serverErr -Raw
      $serverSawAbort = $serverLog -match 'SLOW_RESPONSE_ABORTED /slow\.html'
      $serverSawResponse = $serverLog -match 'SLOW_RESPONSE_SENT /slow\.html'
      if ($liveContextRestored -and ($serverSawAbort -or $serverSawResponse)) {
        break
      }
    }
  }

  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawAbort = $serverLog -match 'SLOW_RESPONSE_ABORTED /slow\.html'
    $serverSawResponse = $serverLog -match 'SLOW_RESPONSE_SENT /slow\.html'
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    title_before = $titleBefore
    title_after_stop = $titleAfterStop
    title_after_resume = $titleAfterResume
    slow_started = $slowStarted
    browser_running_after_stop = $browserRunningAfterStop
    live_context_restored = $liveContextRestored
    server_saw_abort = $serverSawAbort
    server_saw_response = $serverSawResponse
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
