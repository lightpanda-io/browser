$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-open-visible-new-tabs"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8212
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-open-visible-new-tabs.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-open-visible-new-tabs.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-open-visible-new-tabs.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-open-visible-new-tabs.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/page-three.html",
  "http://127.0.0.1:$port/page-two.html",
  "http://127.0.0.1:$port/index.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks

$server = $null
$browser = $null
$ready = $false
$bookmarksOpened = $false
$bulkOpenWorked = $false
$pageThreeWorked = $false
$pageTwoWorked = $false
$returnedWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmark bulk-open server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmark bulk-open window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "bookmark bulk-open initial page did not load" }

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/filter/page-" "Browser Bookmarks (2/3)"
  $bookmarksOpened = [bool]$titles.bookmarks
  if (-not $bookmarksOpened) { throw "filtered browser://bookmarks did not load" }

  $titles.bookmarks_after_bulk = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/open-visible-new-tabs" "Browser Bookmarks (2/3)"
  $bulkOpenWorked = [bool]$titles.bookmarks_after_bulk
  if (-not $bulkOpenWorked) { throw "bookmark bulk-open action did not preserve the filtered bookmarks tab" }

  Send-SmokeCtrlTab
  Start-Sleep -Milliseconds 180
  $titles.page_three = Wait-TabTitle $browser.Id "Browser Pages Three" 40
  $pageThreeWorked = [bool]$titles.page_three
  if (-not $pageThreeWorked) { throw "first visible bookmark tab did not open as page three" }

  Send-SmokeCtrlTab
  Start-Sleep -Milliseconds 180
  $titles.page_two = Wait-TabTitle $browser.Id "Browser Pages Two" 40
  $pageTwoWorked = [bool]$titles.page_two
  if (-not $pageTwoWorked) { throw "second visible bookmark tab did not open as page two" }

  Send-SmokeCtrlShiftTab
  Start-Sleep -Milliseconds 180
  Send-SmokeCtrlShiftTab
  Start-Sleep -Milliseconds 180
  $titles.returned = Wait-TabTitle $browser.Id "Browser Bookmarks (2/3)" 40
  $returnedWorked = [bool]$titles.returned
  if (-not $returnedWorked) { throw "bookmark bulk-open did not preserve the source bookmarks tab" }
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
    bookmarks_opened = $bookmarksOpened
    bulk_open_worked = $bulkOpenWorked
    page_three_worked = $pageThreeWorked
    page_two_worked = $pageTwoWorked
    returned_worked = $returnedWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }