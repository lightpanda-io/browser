$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\tabs"
$port = 8153
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$run1Png = Join-Path $root "chrome-restore.run1.png"
$run2Png = Join-Path $root "chrome-restore.run2.png"
$run1Out = Join-Path $root "chrome-restore.run1.browser.stdout.txt"
$run1Err = Join-Path $root "chrome-restore.run1.browser.stderr.txt"
$run2Out = Join-Path $root "chrome-restore.run2.browser.stdout.txt"
$run2Err = Join-Path $root "chrome-restore.run2.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-restore.server.stdout.txt"
$serverErr = Join-Path $root "chrome-restore.server.stderr.txt"
$profileRoot = Join-Path $root "profile-restore"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $run1Png,$run2Png,$run1Out,$run1Err,$run2Out,$run2Err,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\TabProbeCommon.ps1"

$server = $null
$browser1 = $null
$browser2 = $null
$ready = $false
$sessionPrepared = $false
$activeRestoreWorked = $false
$otherTabWorked = $false
$run1ScreenshotReady = $false
$run2ScreenshotReady = $false
$titles = [ordered]@{}
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
  if (-not $ready) { throw "restore probe server did not become ready" }

  $browser1 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$run1Png -WorkingDirectory $repo -PassThru -RedirectStandardOutput $run1Out -RedirectStandardError $run1Err
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $run1Png) -and ((Get-Item $run1Png).Length -gt 0)) {
      $run1ScreenshotReady = $true
      break
    }
  }
  if (-not $run1ScreenshotReady) { throw "restore probe run1 screenshot did not become ready" }
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) { throw "restore probe run1 window handle not found" }
  Show-SmokeWindow $hwnd1

  $titles.run1_initial = Wait-TabTitle $browser1.Id "Tab One"
  if (-not $titles.run1_initial) { throw "restore probe run1 initial title missing" }

  $newTabPoint = Get-TabClientPoint 0 -New
  [void](Invoke-SmokeClientClick $hwnd1 $newTabPoint.X $newTabPoint.Y)
  $titles.run1_new_tab = Wait-TabTitle $browser1.Id "New Tab"
  if (-not $titles.run1_new_tab) { throw "restore probe run1 new tab missing" }

  [void](Invoke-SmokeClientClick $hwnd1 160 40)
  Start-Sleep -Milliseconds 150
  Send-SmokeText "http://127.0.0.1:$port/two.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $titles.run1_second = Wait-TabTitle $browser1.Id "Tab Two"
  if (-not $titles.run1_second) { throw "restore probe run1 second tab navigation missing" }
  $sessionPrepared = $true

  $browser1Meta = Stop-OwnedProbeProcess $browser1
  Start-Sleep -Milliseconds 300
  if (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) { throw "restore probe run1 browser did not exit" }

  $browser2 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$run2Png -WorkingDirectory $repo -PassThru -RedirectStandardOutput $run2Out -RedirectStandardError $run2Err
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $run2Png) -and ((Get-Item $run2Png).Length -gt 0)) {
      $run2ScreenshotReady = $true
      break
    }
  }
  if (-not $run2ScreenshotReady) { throw "restore probe run2 screenshot did not become ready" }
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) { throw "restore probe run2 window handle not found" }
  Show-SmokeWindow $hwnd2

  $titles.run2_active = Wait-TabTitle $browser2.Id "Tab Two"
  $activeRestoreWorked = [bool]$titles.run2_active
  if (-not $activeRestoreWorked) { throw "restore probe did not reopen the last active tab" }

  Send-SmokeCtrlShiftTab
  $titles.run2_other = Wait-TabTitle $browser2.Id "Tab One"
  $otherTabWorked = [bool]$titles.run2_other
  if (-not $otherTabWorked) { throw "restore probe did not restore the other saved tab" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  if (-not $browser1Meta) { $browser1Meta = Stop-OwnedProbeProcess $browser1 }
  $browser2Meta = Stop-OwnedProbeProcess $browser2
  Start-Sleep -Milliseconds 200
  $browser1Gone = if ($browser1) { -not (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) } else { $true }
  $browser2Gone = if ($browser2) { -not (Get-Process -Id $browser2.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    run1_browser_pid = if ($browser1) { $browser1.Id } else { 0 }
    run2_browser_pid = if ($browser2) { $browser2.Id } else { 0 }
    ready = $ready
    run1_screenshot_ready = $run1ScreenshotReady
    run2_screenshot_ready = $run2ScreenshotReady
    session_prepared = $sessionPrepared
    active_restore_worked = $activeRestoreWorked
    other_tab_worked = $otherTabWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser1_meta = $browser1Meta
    browser2_meta = $browser2Meta
    browser1_gone = $browser1Gone
    browser2_gone = $browser2Gone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
