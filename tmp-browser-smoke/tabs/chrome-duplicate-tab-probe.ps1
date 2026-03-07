$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\tabs"
$profileRoot = Join-Path $root "profile-duplicate"
$port = 8157
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-duplicate.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-duplicate.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-duplicate.server.stdout.txt"
$serverErr = Join-Path $root "chrome-duplicate.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\TabProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$duplicateWorked = $false
$switchBackWorked = $false
$switchForwardWorked = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/duplicate-one.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "duplicate tab probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/duplicate-one.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "duplicate tab probe window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Duplicate One"
  if (-not $titles.initial) { throw "duplicate tab probe initial title missing" }

  Send-SmokeCtrlShiftD
  Start-Sleep -Milliseconds 250
  [void](Invoke-SmokeClientClick $hwnd 160 40)
  Start-Sleep -Milliseconds 120
  Send-SmokeText "http://127.0.0.1:$port/duplicate-two.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter

  $titles.duplicate = Wait-TabTitle $browser.Id "Duplicate Two"
  $duplicateWorked = [bool]$titles.duplicate
  if (-not $duplicateWorked) { throw "duplicate tab probe did not navigate duplicated tab" }

  Send-SmokeCtrlShiftTab
  $titles.back = Wait-TabTitle $browser.Id "Duplicate One"
  $switchBackWorked = [bool]$titles.back
  if (-not $switchBackWorked) { throw "duplicate tab probe did not switch back to original tab" }

  Send-SmokeCtrlTab
  $titles.forward = Wait-TabTitle $browser.Id "Duplicate Two"
  $switchForwardWorked = [bool]$titles.forward
  if (-not $switchForwardWorked) { throw "duplicate tab probe did not switch forward to duplicated tab" }
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
    duplicate_worked = $duplicateWorked
    switch_back_worked = $switchBackWorked
    switch_forward_worked = $switchForwardWorked
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
