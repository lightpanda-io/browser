$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\browser-pages"
$profileRoot = Join-Path $root "profile-shortcuts"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$downloadsDir = Join-Path $appDataRoot "downloads"
$port = 8182
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-browser-pages-shortcuts.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-browser-pages-shortcuts.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-browser-pages-shortcuts.server.stdout.txt"
$serverErr = Join-Path $root "chrome-browser-pages-shortcuts.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

$seedDownloadPath = Join-Path $downloadsDir "seed.txt"
'seed file' | Set-Content -Path $seedDownloadPath -NoNewline
@"
lightpanda-browse-settings-v1
restore_previous_session	1
allow_script_popups	0
default_zoom_percent	130
homepage_url	http://127.0.0.1:$port/index.html
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline
@"
http://127.0.0.1:$port/index.html
http://127.0.0.1:$port/page-two.html
"@ | Set-Content -Path (Join-Path $appDataRoot "bookmarks.txt") -NoNewline
@"
2	12	12	1	seed.txt	$seedDownloadPath	http://127.0.0.1:$port/download.txt	
"@ | Set-Content -Path (Join-Path $appDataRoot "downloads-v1.txt") -NoNewline

$server = $null
$browser = $null
$ready = $false
$navigated = $false
$historyWorked = $false
$bookmarksWorked = $false
$downloadsWorked = $false
$settingsWorked = $false
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
  if (-not $ready) { throw "browser pages server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "browser pages window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "browser pages initial page did not load" }

  [void](Invoke-SmokeClientClick $hwnd 160 40)
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText "http://127.0.0.1:$port/page-two.html"
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter

  $titles.page_two = Wait-TabTitle $browser.Id "Browser Pages Two" 40
  $navigated = [bool]$titles.page_two
  if (-not $navigated) { throw "browser pages navigation to page two failed" }

  Send-SmokeCtrlAltH
  $titles.history = Wait-TabTitle $browser.Id "Browser History (2)" 40
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) { throw "history page shortcut did not load" }

  Send-SmokeCtrlAltB
  $titles.bookmarks = Wait-TabTitle $browser.Id "Browser Bookmarks (2)" 40
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) { throw "bookmarks page shortcut did not load" }

  Send-SmokeCtrlAltJ
  $titles.downloads = Wait-TabTitle $browser.Id "Browser Downloads (1)" 40
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) { throw "downloads page shortcut did not load" }

  Send-SmokeCtrlAltS
  $titles.settings = Wait-TabTitle $browser.Id "Browser Settings" 40
  $settingsWorked = [bool]$titles.settings
  if (-not $settingsWorked) { throw "settings page shortcut did not load" }
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
    navigated = $navigated
    history_worked = $historyWorked
    bookmarks_worked = $bookmarksWorked
    downloads_worked = $downloadsWorked
    settings_worked = $settingsWorked
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