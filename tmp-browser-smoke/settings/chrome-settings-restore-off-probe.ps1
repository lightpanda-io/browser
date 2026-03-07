$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\settings"
$profileRoot = Join-Path $root "profile-restore-off"
$port = 8156
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$run1Out = Join-Path $root "chrome-settings-restore-off.run1.browser.stdout.txt"
$run1Err = Join-Path $root "chrome-settings-restore-off.run1.browser.stderr.txt"
$run2Out = Join-Path $root "chrome-settings-restore-off.run2.browser.stdout.txt"
$run2Err = Join-Path $root "chrome-settings-restore-off.run2.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-settings-restore-off.server.stdout.txt"
$serverErr = Join-Path $root "chrome-settings-restore-off.server.stderr.txt"
$settingsFile = Join-Path $profileRoot "lightpanda\browse-settings-v1.txt"
$sessionFile = Join-Path $profileRoot "lightpanda\browse-session-v1.txt"

Remove-Item $run1Out,$run1Err,$run2Out,$run2Err,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Remove-Item $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\common\Win32Input.ps1"
. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

function Wait-SettingsFileMatch([string]$Path, [string]$Needle, [int]$Attempts = 40) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $Path) -and ((Get-Content $Path -Raw) -like "*$Needle*")) {
      return $true
    }
  }
  return $false
}

$server = $null
$browser1 = $null
$browser2 = $null
$ready = $false
$sessionPrepared = $false
$restoreDisabledSaved = $false
$sessionCleared = $false
$notRestored = $false
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
  if (-not $ready) { throw "settings restore-off probe server did not become ready" }

  $browser1 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $run1Out -RedirectStandardError $run1Err
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) { throw "settings restore-off run1 window handle not found" }
  Show-SmokeWindow $hwnd1
  $titles.run1_initial = Wait-TabTitle $browser1.Id "Settings Start"
  if (-not $titles.run1_initial) { throw "settings restore-off run1 initial title missing" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 200
  $titles.run1_new_tab = Wait-TabTitle $browser1.Id "New Tab"
  if (-not $titles.run1_new_tab) { throw "settings restore-off run1 new tab missing" }

  [void](Invoke-SmokeClientClick $hwnd1 160 40)
  Start-Sleep -Milliseconds 120
  Send-SmokeText "http://127.0.0.1:$port/home.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $titles.run1_second = Wait-TabTitle $browser1.Id "Settings Home"
  if (-not $titles.run1_second) { throw "settings restore-off run1 second tab title missing" }
  $sessionPrepared = $true

  Send-SmokeCtrlComma
  Start-Sleep -Milliseconds 200
  Send-SmokeSpace
  $restoreDisabledSaved = Wait-SettingsFileMatch $settingsFile "restore_previous_session`t0"
  if (-not $restoreDisabledSaved) { throw "settings restore-off did not persist restore_previous_session=0" }

  $browser1Meta = Stop-OwnedProbeProcess $browser1
  Start-Sleep -Milliseconds 500
  $sessionCleared = -not (Test-Path $sessionFile)
  if (-not $sessionCleared) { throw "settings restore-off did not clear saved session file" }

  $browser2 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $run2Out -RedirectStandardError $run2Err
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) { throw "settings restore-off run2 window handle not found" }
  Show-SmokeWindow $hwnd2
  $titles.run2_initial = Wait-TabTitle $browser2.Id "Settings Start"
  $notRestored = [bool]$titles.run2_initial
  if (-not $notRestored) { throw "settings restore-off reopened a restored tab instead of startup page" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Stop-OwnedProbeProcess $server } else { $null }
  if (-not $browser1Meta) { $browser1Meta = if ($browser1) { Stop-OwnedProbeProcess $browser1 } else { $null } }
  $browser2Meta = if ($browser2) { Stop-OwnedProbeProcess $browser2 } else { $null }
  Start-Sleep -Milliseconds 200
  $browser1Gone = if ($browser1) { -not (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) } else { $true }
  $browser2Gone = if ($browser2) { -not (Get-Process -Id $browser2.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    run1_browser_pid = if ($browser1) { $browser1.Id } else { 0 }
    run2_browser_pid = if ($browser2) { $browser2.Id } else { 0 }
    ready = $ready
    session_prepared = $sessionPrepared
    restore_disabled_saved = $restoreDisabledSaved
    session_cleared = $sessionCleared
    not_restored = $notRestored
    settings_file = $settingsFile
    session_file = $sessionFile
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
