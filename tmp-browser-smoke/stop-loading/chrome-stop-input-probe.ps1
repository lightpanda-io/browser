$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\stop-loading"
$port = 8153
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "slow_server.py"
$browserOut = Join-Path $root "chrome-stop-input.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-stop-input.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-stop-input.server.stdout.txt"
$serverErr = Join-Path $root "chrome-stop-input.server.stderr.txt"
$beforePng = Join-Path $root "chrome-stop-input.before.png"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$beforePng -Force -ErrorAction SilentlyContinue

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\Win32Input.ps1")

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$browserRunningAfterStop = $false
$preflightWorked = $false
$restoredInputWorked = $false
$usedTabFallback = $false
$usedClickFallback = $false
$titleBefore = $null
$titleAfterPreflight = $null
$titleAfterStop = $null
$titleAfterRestoreInput = $null
$slowStarted = $false
$serverSawAbort = $false
$serverSawResponse = $false
$failure = $null

function Wait-ForTitleLike([IntPtr]$Hwnd, [string]$Pattern, [int]$Attempts = 20, [int]$SleepMs = 250) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    $title = Get-SmokeWindowTitle $Hwnd
    if ($title -like $Pattern) {
      return $title
    }
  }
  return $null
}

function Try-TypeIntoRestoredInput([IntPtr]$Hwnd, [string]$Text, [string]$Pattern, [switch]$AllowTabFallback) {
  Send-SmokeText $Text
  $title = Wait-ForTitleLike $Hwnd $Pattern 10 200
  if ($title) { return [ordered]@{ title = $title; click = $false; tab = $false } }

  [void](Invoke-SmokeClientClick $Hwnd 150 230)
  Start-Sleep -Milliseconds 120
  Send-SmokeText $Text
  $title = Wait-ForTitleLike $Hwnd $Pattern 10 200
  if ($title) { return [ordered]@{ title = $title; click = $true; tab = $false } }

  if ($AllowTabFallback) {
    Send-SmokeTab
    Start-Sleep -Milliseconds 120
    Send-SmokeText $Text
    $title = Wait-ForTitleLike $Hwnd $Pattern 10 200
    if ($title) { return [ordered]@{ title = $title; click = $false; tab = $true } }
  }

  return $null
}

try {
  $server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/ping" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "stop input probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/input.html","--window_width","260","--window_height","520","--screenshot_png",$beforePng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $beforePng) -and ((Get-Item $beforePng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "stop input probe screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "stop input probe window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  $preflight = Try-TypeIntoRestoredInput $hwnd "A" "Stop Restore Input A*" -AllowTabFallback
  if ($preflight) {
    $titleAfterPreflight = $preflight.title
    $preflightWorked = $true
    $usedClickFallback = $preflight.click
    $usedTabFallback = $preflight.tab
  } else {
    throw "preflight page input did not update the title"
  }

  [void](Invoke-SmokeClientClick $hwnd 130 40)
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
  Start-Sleep -Milliseconds 350

  $procAfter = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
  $browserRunningAfterStop = $null -ne $procAfter
  if (-not $browserRunningAfterStop) {
    throw "browser exited after stop"
  }
  $titleAfterStop = Get-SmokeWindowTitle $hwnd

  $restoreInput = Try-TypeIntoRestoredInput $hwnd "B" "Stop Restore Input AB*" -AllowTabFallback
  if ($restoreInput) {
    $titleAfterRestoreInput = $restoreInput.title
    if ($restoreInput.click) { $usedClickFallback = $true }
    if ($restoreInput.tab) { $usedTabFallback = $true }
  }
  $restoredInputWorked = $null -ne $titleAfterRestoreInput

  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawAbort = $serverLog -match 'SLOW_RESPONSE_ABORTED /slow\.html'
    $serverSawResponse = $serverLog -match 'SLOW_RESPONSE_SENT /slow\.html'
  }

  if (-not $restoredInputWorked) {
    throw "restored page input did not preserve state and extend to AB after stop"
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
    title_after_preflight = $titleAfterPreflight
    title_after_stop = $titleAfterStop
    title_after_restore_input = $titleAfterRestoreInput
    preflight_worked = $preflightWorked
    slow_started = $slowStarted
    browser_running_after_stop = $browserRunningAfterStop
    restored_input_worked = $restoredInputWorked
    used_click_fallback = $usedClickFallback
    used_tab_fallback = $usedTabFallback
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
