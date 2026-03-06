$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\form-controls"
$port = 8154
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "form_server.py"
$browserOut = Join-Path $root "label-click.browser.stdout.txt"
$browserErr = Join-Path $root "label-click.browser.stderr.txt"
$serverOut = Join-Path $root "label-click.server.stdout.txt"
$serverErr = Join-Path $root "label-click.server.stderr.txt"
$pngPath = Join-Path $root "label-click.before.png"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$pngPath -Force -ErrorAction SilentlyContinue

. (Join-Path (Split-Path $PSScriptRoot -Parent) "common\Win32Input.ps1")

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$titleBefore = $null
$titleAfterClick = $null
$clickedWorked = $false
$failure = $null

function Wait-ForTitleLike([IntPtr]$Hwnd, [string]$Pattern, [int]$Attempts = 20, [int]$SleepMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    $title = Get-SmokeWindowTitle $Hwnd
    if ($title -like $Pattern) {
      return $title
    }
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
  if (-not $ready) { throw "label probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/label.html","--window_width","420","--window_height","520","--screenshot_png",$pngPath -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $pngPath) -and ((Get-Item $pngPath).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "label probe screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "label probe window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  [void](Invoke-SmokeClientClick $hwnd 316 408)
  $titleAfterClick = Wait-ForTitleLike $hwnd "Label Smoke true*"
  if (-not $titleAfterClick) {
    Start-Sleep -Milliseconds 200
    $titleAfterClick = Get-SmokeWindowTitle $hwnd
  }
  $clickedWorked = $titleAfterClick -like "Label Smoke true*"
  if (-not $clickedWorked) { throw "label click did not toggle the checkbox" }
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
    title_after_click = $titleAfterClick
    clicked_worked = $clickedWorked
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
