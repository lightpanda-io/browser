$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-script-policy"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$settingsPath = Join-Path $appDataRoot "browse-settings-v1.txt"
$port = 8176
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-script-policy.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-script-policy.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-script-policy.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-script-policy.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"
. "$PSScriptRoot\..\common\Win32Input.ps1"

function Wait-SettingsValue {
  param(
    [string]$Path,
    [string]$Needle,
    [int]$TimeoutSeconds = 8
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    if (Test-Path $Path) {
      $raw = Get-Content $Path -Raw
      if ($raw -match [regex]::Escape($Needle)) {
        return $true
      }
    }
    Start-Sleep -Milliseconds 200
  }
  return $false
}

$server = $null
$browser = $null
$ready = $false
$toggleOffWorked = $false
$toggleOnWorked = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/script-popup-policy-index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "script popup policy server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/script-popup-policy-index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "script popup policy window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Policy Start" 8
  if (-not $titles.initial) { throw "script popup policy start page did not load" }

  Send-SmokeCtrlComma
  Start-Sleep -Milliseconds 250
  Send-SmokeDown
  Start-Sleep -Milliseconds 150
  Send-SmokeSpace
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlComma
  $toggleOffWorked = Wait-SettingsValue $settingsPath "allow_script_popups`t0"
  if (-not $toggleOffWorked) { throw "settings overlay did not persist script popup policy off" }

  Send-SmokeCtrlComma
  Start-Sleep -Milliseconds 250
  Send-SmokeDown
  Start-Sleep -Milliseconds 150
  Send-SmokeSpace
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlComma
  $toggleOnWorked = Wait-SettingsValue $settingsPath "allow_script_popups`t1"
  if (-not $toggleOnWorked) { throw "settings overlay did not persist script popup policy on" }
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
    toggle_off_worked = $toggleOffWorked
    toggle_on_worked = $toggleOnWorked
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
