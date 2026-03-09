$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\settings"
$profileRoot = Join-Path $root "profile-home"
$port = 8155
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-settings-home.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-settings-home.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-settings-home.server.stdout.txt"
$serverErr = Join-Path $root "chrome-settings-home.server.stderr.txt"
$settingsFile = Join-Path $profileRoot "lightpanda\browse-settings-v1.txt"

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
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
$browser = $null
$ready = $false
$defaultZoomSaved = $false
$homepageSaved = $false
$homeWorked = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/home.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "settings home probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/home.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "settings home probe window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Settings Home"
  if (-not $titles.initial) { throw "settings home probe initial title missing" }

  Send-SmokeCtrlComma
  Start-Sleep -Milliseconds 200
  Send-SmokeDown
  Start-Sleep -Milliseconds 100
  Send-SmokeRight
  $defaultZoomSaved = Wait-SettingsFileMatch $settingsFile "default_zoom_percent`t110"
  if (-not $defaultZoomSaved) { throw "settings home probe did not persist default zoom" }

  Send-SmokeDown
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $homepageSaved = Wait-SettingsFileMatch $settingsFile "homepage_url`thttp://127.0.0.1:$port/home.html"
  if (-not $homepageSaved) { throw "settings home probe did not persist homepage" }

  Send-SmokeCtrlComma
  Start-Sleep -Milliseconds 150
  [void](Invoke-SmokeClientClick $hwnd 160 40)
  Start-Sleep -Milliseconds 120
  Send-SmokeText "http://127.0.0.1:$port/index.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $titles.index = Wait-TabTitle $browser.Id "Settings Start"
  if (-not $titles.index) { throw "settings home probe did not navigate to index page" }

  Send-SmokeAltHome
  $titles.after_home = Wait-TabTitle $browser.Id "Settings Home"
  $homeWorked = [bool]$titles.after_home
  if (-not $homeWorked) { throw "settings home probe alt+home did not navigate to homepage" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Stop-OwnedProbeProcess $server } else { $null }
  $browserMeta = if ($browser) { Stop-OwnedProbeProcess $browser } else { $null }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    default_zoom_saved = $defaultZoomSaved
    homepage_saved = $homepageSaved
    home_worked = $homeWorked
    settings_file = $settingsFile
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
