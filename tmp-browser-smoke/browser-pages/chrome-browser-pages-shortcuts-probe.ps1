$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-shortcuts"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8182
$browserOut = Join-Path $Root "chrome-browser-pages-shortcuts.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-shortcuts.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-shortcuts.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-shortcuts.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks -SeedDownload

$server = $null
$browser = $null
$ready = $false
$navigated = $false
$tabsWorked = $false
$historyWorked = $false
$bookmarksWorked = $false
$downloadsWorked = $false
$settingsWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "browser pages server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "browser pages window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "browser pages initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  $navigated = [bool]$titles.page_two
  if (-not $navigated) { throw "browser pages navigation to page two failed" }

  Send-SmokeCtrlShiftA
  $titles.tabs = Wait-TabTitle $browser.Id "Browser Tabs (1)" 40
  $tabsWorked = [bool]$titles.tabs
  if (-not $tabsWorked) { throw "tabs page shortcut did not load" }

  Send-SmokeCtrlH
  $titles.history = Wait-TabTitle $browser.Id "Browser History (2)" 40
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) { throw "history page shortcut did not load" }

  Send-SmokeCtrlShiftB
  $titles.bookmarks = Wait-TabTitle $browser.Id "Browser Bookmarks (2)" 40
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) { throw "bookmarks page shortcut did not load" }

  Send-SmokeCtrlJ
  $titles.downloads = Wait-TabTitle $browser.Id "Browser Downloads (1)" 40
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) { throw "downloads page shortcut did not load" }

  Send-SmokeCtrlComma
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
    tabs_worked = $tabsWorked
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
