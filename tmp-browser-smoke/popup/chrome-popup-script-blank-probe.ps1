$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-script-blank"
$port = 8171
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-script-blank.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-script-blank.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-script-blank.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-script-blank.server.stderr.txt"

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
$launcherRetained = $false
$serverSawResult = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/script-popup-blank-index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "script blank popup server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/script-popup-blank-index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "script blank popup window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Script Blank Start" 6
  Start-Sleep -Milliseconds 900
  Send-SmokeCtrlDigit 2
  $titles.result = Wait-TabTitle $browser.Id "Popup Script Blank Result" 24
  $popupWorked = [bool]$titles.result
  if (-not $popupWorked) { throw "script blank popup did not open result tab" }

  Send-SmokeCtrlDigit 1
  $titles.returned = Wait-TabTitle $browser.Id "Popup Script Blank Start" 12
  $launcherRetained = [bool]$titles.returned
  if (-not $launcherRetained) { throw "script blank popup did not preserve launcher tab" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawResult = $serverLog -match 'GET /script-popup-blank-result\.html'
  }
  if (-not $failure -and -not $serverSawResult) {
    $failure = "server did not observe script blank result request"
  }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    popup_worked = $popupWorked
    launcher_retained = $launcherRetained
    server_saw_result = $serverSawResult
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
