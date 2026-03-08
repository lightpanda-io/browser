$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-start-shell"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8191
$browserOut = Join-Path $Root "chrome-browser-pages-start-shell.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-start-shell.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-start-shell.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-start-shell.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks -SeedDownload -HomepageUrl ""

$server = $null
$browser = $null
$ready = $false
$startWorked = $false
$tabsWorked = $false
$historyWorked = $false
$bookmarksWorked = $false
$downloadsWorked = $false
$settingsWorked = $false
$roundTripWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "start shell server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "start shell window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "start shell initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "start shell seed navigation to page two failed" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeAltHome
  $titles.start = Wait-TabTitle $browser.Id "Browser Start" 40
  $startWorked = [bool]$titles.start
  if (-not $startWorked) { throw "Alt+Home did not open Browser Start" }

  $titles.tabs = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Tabs (1)"
  $tabsWorked = [bool]$titles.tabs
  if (-not $tabsWorked) { throw "start shell tabs link failed" }

  $titles.history = Invoke-BrowserPagesDocumentAction $hwnd 2 $browser.Id "Browser History (2)"
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) { throw "start shell history link failed" }

  $titles.bookmarks = Invoke-BrowserPagesDocumentAction $hwnd 3 $browser.Id "Browser Bookmarks (2)"
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) { throw "start shell bookmarks link failed" }

  $titles.downloads = Invoke-BrowserPagesDocumentAction $hwnd 4 $browser.Id "Browser Downloads (1)"
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) { throw "start shell downloads link failed" }

  $titles.settings = Invoke-BrowserPagesDocumentAction $hwnd 5 $browser.Id "Browser Settings"
  $settingsWorked = [bool]$titles.settings
  if (-not $settingsWorked) { throw "start shell settings link failed" }

  $titles.start_round_trip = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Start"
  $roundTripWorked = [bool]$titles.start_round_trip
  if (-not $roundTripWorked) { throw "settings page start link failed" }
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
    start_worked = $startWorked
    tabs_worked = $tabsWorked
    history_worked = $historyWorked
    bookmarks_worked = $bookmarksWorked
    downloads_worked = $downloadsWorked
    settings_worked = $settingsWorked
    round_trip_worked = $roundTripWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
