$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-background-timer"
$port = 8177
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-background-timer.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-background-timer.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-background-timer.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-background-timer.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$popupWorked = $false
$backgroundWorked = $false
$serverSawPopup = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/script-popup-background-timer.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "popup background timer server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/script-popup-background-timer.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "popup background timer window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Background Timer Start" 6

  Start-Sleep -Milliseconds 900
  Send-SmokeCtrlDigit 2
  $titles.popup = Wait-TabTitle $browser.Id "Popup Script Blank Result" 24
  $popupWorked = [bool]$titles.popup
  if (-not $popupWorked) { throw "popup background timer did not open popup tab" }

  Send-SmokeCtrlDigit 1
  $titles.background = Wait-TabTitle $browser.Id "Popup Background Timer Fired" 24
  $backgroundWorked = [bool]$titles.background
  if (-not $backgroundWorked) { throw "popup background timer did not fire launcher callback after popup open" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawPopup = $serverLog -match 'GET /script-popup-blank-result\.html'
  }
  if (-not $failure -and -not $serverSawPopup) {
    $failure = "server did not observe popup background timer result request"
  }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    popup_worked = $popupWorked
    background_worked = $backgroundWorked
    server_saw_popup = $serverSawPopup
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
