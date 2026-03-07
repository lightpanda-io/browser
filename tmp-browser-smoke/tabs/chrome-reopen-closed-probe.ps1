$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\tabs"
$port = 8152
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$initialPng = Join-Path $root "chrome-reopen.initial.png"
$browserOut = Join-Path $root "chrome-reopen.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-reopen.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-reopen.server.stdout.txt"
$serverErr = Join-Path $root "chrome-reopen.server.stderr.txt"
$profileRoot = Join-Path $root "profile-reopen"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $initialPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\TabProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$newTabWorked = $false
$navigateWorked = $false
$closeWorked = $false
$reopenWorked = $false
$screenshotReady = $false
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
  if (-not $ready) { throw "reopen probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$initialPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) {
      $screenshotReady = $true
      break
    }
  }
  if (-not $screenshotReady) { throw "reopen probe initial screenshot did not become ready" }
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "reopen probe window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Tab One"
  if (-not $titles.initial) { throw "initial tab title did not appear" }

  $newTabPoint = Get-TabClientPoint 0 -New
  [void](Invoke-SmokeClientClick $hwnd $newTabPoint.X $newTabPoint.Y)
  $titles.new_tab = Wait-TabTitle $browser.Id "New Tab"
  $newTabWorked = [bool]$titles.new_tab
  if (-not $newTabWorked) { throw "new tab did not open" }

  [void](Invoke-SmokeClientClick $hwnd 160 40)
  Start-Sleep -Milliseconds 150
  Send-SmokeText "http://127.0.0.1:$port/two.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $titles.second = Wait-TabTitle $browser.Id "Tab Two"
  $navigateWorked = [bool]$titles.second
  if (-not $navigateWorked) { throw "second tab navigation did not complete" }

  Send-SmokeCtrlW
  $titles.after_close = Wait-TabTitle $browser.Id "Tab One"
  $closeWorked = [bool]$titles.after_close
  if (-not $closeWorked) { throw "close tab shortcut did not return to tab one" }

  Send-SmokeCtrlShiftT
  $titles.after_reopen = Wait-TabTitle $browser.Id "Tab Two"
  $reopenWorked = [bool]$titles.after_reopen
  if (-not $reopenWorked) { throw "reopen closed tab shortcut did not restore tab two" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $screenshotReady
    new_tab_worked = $newTabWorked
    navigate_worked = $navigateWorked
    close_worked = $closeWorked
    reopen_worked = $reopenWorked
    titles = $titles
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
