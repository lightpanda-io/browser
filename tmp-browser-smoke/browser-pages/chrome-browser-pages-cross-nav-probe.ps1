$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-cross-nav"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8189
$browserOut = Join-Path $Root "chrome-browser-pages-cross-nav.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-cross-nav.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-cross-nav.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-cross-nav.server.stderr.txt"
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
  if (-not $ready) { throw "cross-nav server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "cross-nav window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "cross-nav seed navigation to page two failed" }

  Send-SmokeAltHome
  $titles.start = Wait-TabTitle $browser.Id "Browser Start" 40
  $startWorked = [bool]$titles.start
  if (-not $startWorked) { throw "Alt+Home did not open Browser Start fallback" }

  Invoke-BrowserPagesTabActivate $hwnd 1
  $titles.history = Wait-TabTitle $browser.Id "Browser History (2)" 40
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) { throw "start page history link failed" }

  Invoke-BrowserPagesTabActivate $hwnd 2
  $titles.bookmarks = Wait-TabTitle $browser.Id "Browser Bookmarks (2)" 40
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) { throw "history page bookmarks link failed" }

  Invoke-BrowserPagesTabActivate $hwnd 3
  $titles.downloads = Wait-TabTitle $browser.Id "Browser Downloads (1)" 40
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) { throw "bookmarks page downloads link failed" }

  Invoke-BrowserPagesTabActivate $hwnd 4
  $titles.settings = Wait-TabTitle $browser.Id "Browser Settings" 40
  $settingsWorked = [bool]$titles.settings
  if (-not $settingsWorked) { throw "downloads page settings link failed" }

  Invoke-BrowserPagesTabActivate $hwnd 1
  $titles.start_round_trip = Wait-TabTitle $browser.Id "Browser Start" 40
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

if ($failure) {
  exit 1
}
