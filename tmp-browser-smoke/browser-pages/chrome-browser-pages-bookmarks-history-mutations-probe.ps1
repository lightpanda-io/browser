$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-history-mutations"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8194
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-history-mutations.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-history-mutations.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-history-mutations.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-history-mutations.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port
$bookmarksFile = Join-Path $app.AppDataRoot "bookmarks.txt"

$server = $null
$browser = $null
$ready = $false
$pageTwoWorked = $false
$bookmarkAddWorked = $false
$bookmarkOpenWorked = $false
$historyClearWorked = $false
$bookmarksAfter = @()
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmark/history mutations server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmark/history mutations window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "bookmark/history mutations initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  $pageTwoWorked = [bool]$titles.page_two
  if (-not $pageTwoWorked) { throw "page two navigation failed" }

  $titles.bookmarks_after_add = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/add-current" "Browser Bookmarks (1)"
  $bookmarkAddWorked = [bool]$titles.bookmarks_after_add
  if (-not $bookmarkAddWorked) { throw "bookmarks add-current did not produce the expected page" }

  $bookmarksAfter = [string[]]@(Get-Content $bookmarksFile | Where-Object { $_ -ne "" } | ForEach-Object { [string]$_ })
  if ($bookmarksAfter.Count -ne 1 -or $bookmarksAfter[0] -ne "http://127.0.0.1:$port/page-two.html") {
    throw "bookmark add-current did not persist the current page"
  }

  $titles.bookmark_open = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/open/0" "Browser Pages Two"
  $bookmarkOpenWorked = [bool]$titles.bookmark_open
  if (-not $bookmarkOpenWorked) { throw "bookmark open after add-current failed" }

  $titles.history_before_clear = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (3)"
  if (-not $titles.history_before_clear) { throw "browser://history did not open with the expected count" }

  $titles.history_after_clear = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history/clear-session" "Browser History (1)"
  $historyClearWorked = [bool]$titles.history_after_clear
  if (-not $historyClearWorked) { throw "history clear-session did not collapse history to the current entry" }
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
    page_two_worked = $pageTwoWorked
    bookmark_add_worked = $bookmarkAddWorked
    bookmark_open_worked = $bookmarkOpenWorked
    history_clear_worked = $historyClearWorked
    bookmarks_after = $bookmarksAfter
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
