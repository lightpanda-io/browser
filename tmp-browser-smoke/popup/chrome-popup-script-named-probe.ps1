$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-script-named"
$port = 8172
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-script-named.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-script-named.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-script-named.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-script-named.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$firstWorked = $false
$secondWorked = $false
$reusedTargetWorked = $false
$serverSawOne = $false
$serverSawTwo = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/script-popup-named-index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "script named popup server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/script-popup-named-index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "script named popup window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Script Named Start" 6
  Start-Sleep -Milliseconds 1300
  Send-SmokeCtrlDigit 2
  $titles.second = Wait-TabTitle $browser.Id "Popup Script Named Result Two" 30
  $secondWorked = [bool]$titles.second
  if (-not $secondWorked) { throw "script named popup did not open second result" }

  Send-SmokeCtrlDigit 1
  $titles.returned = Wait-TabTitle $browser.Id "Popup Script Named Start" 12
  if (-not $titles.returned) { throw "script named popup did not preserve launcher tab" }

  Send-SmokeCtrlDigit 2
  $titles.reused = Wait-TabTitle $browser.Id "Popup Script Named Result Two" 12
  $reusedTargetWorked = [bool]$titles.reused
  if (-not $reusedTargetWorked) { throw "script named popup target tab was not reused" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawOne = $serverLog -match 'GET /script-popup-named-one\.html'
    $serverSawTwo = $serverLog -match 'GET /script-popup-named-two\.html'
  }
  $firstWorked = $serverSawOne
  if (-not $failure) {
    if (-not $serverSawOne) {
      $failure = "server did not observe script named result one request"
    } elseif (-not $serverSawTwo) {
      $failure = "server did not observe script named result two request"
    }
  }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    first_worked = $firstWorked
    second_worked = $secondWorked
    reused_target_worked = $reusedTargetWorked
    server_saw_one = $serverSawOne
    server_saw_two = $serverSawTwo
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
