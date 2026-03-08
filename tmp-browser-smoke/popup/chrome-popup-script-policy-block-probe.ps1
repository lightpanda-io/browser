$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-script-policy-block"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$settingsPath = Join-Path $appDataRoot "browse-settings-v1.txt"
$port = 8177
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-script-policy-block.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-script-policy-block.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-script-policy-block.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-script-policy-block.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Set-Content -Path $settingsPath -Value "lightpanda-browse-settings-v1`nrestore_previous_session`t1`nallow_script_popups`t0`ndefault_zoom_percent`t100`nhomepage_url`t`n" -NoNewline

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

function Get-ResultHitCount {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return 0 }
  $log = Get-Content $Path -Raw
  return ([regex]::Matches($log, 'GET /script-popup-blank-result\.html')).Count
}

$server = $null
$browser = $null
$ready = $false
$blockedWorked = $false
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
  if (-not $ready) { throw "script popup block server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/script-popup-blank-index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "script popup block window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Script Blank Start" 8
  if (-not $titles.initial) { throw "script popup block start page did not load" }

  Start-Sleep -Seconds 2
  $resultHits = Get-ResultHitCount $serverErr
  $titles.stillInitial = Wait-TabTitle $browser.Id "Popup Script Blank Start" 4
  $blockedWorked = ($resultHits -eq 0) -and ($titles.stillInitial -ne $null)
  if (-not $blockedWorked) { throw "blocked script popup still reached the popup result page" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $finalHits = Get-ResultHitCount $serverErr
  if (-not $failure -and $finalHits -ne 0) {
    $failure = "expected zero blocked popup result requests but saw $finalHits"
  }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    blocked_worked = $blockedWorked
    settings_path = $settingsPath
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
