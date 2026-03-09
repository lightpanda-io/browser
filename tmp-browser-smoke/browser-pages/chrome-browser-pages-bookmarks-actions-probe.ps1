$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmark-actions"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8185
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks
$bookmarksFile = Join-Path $app.AppDataRoot "bookmarks.txt"

$server = $null
$browser = $null
$ready = $false
$opened = $false
$removeWorked = $false
$openWorked = $false
$bookmarksAfter = @()
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmark actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmark actions window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (2)"
  $opened = [bool]$titles.bookmarks
  if (-not $opened) { throw "browser://bookmarks did not load" }

  $titles.bookmarks_after_remove = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/remove/0" "Browser Bookmarks (1)"
  $removeWorked = [bool]$titles.bookmarks_after_remove
  if (-not $removeWorked) { throw "bookmark remove action failed" }

  $bookmarksAfter = [string[]]@(Get-Content $bookmarksFile | Where-Object { $_ -ne "" } | ForEach-Object { [string]$_ })
  if ($bookmarksAfter.Count -ne 1 -or $bookmarksAfter[0] -ne "http://127.0.0.1:$port/page-two.html") {
    throw "bookmark file was not rewritten to the remaining entry"
  }

  $titles.bookmarks_reopened = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (1)"
  if (-not $titles.bookmarks_reopened) { throw "browser://bookmarks did not reopen after removal" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks/open/0" "Browser Pages Two"
  $openWorked = [bool]$titles.page_two
  if (-not $openWorked) { throw "bookmark open action failed" }
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
    opened = $opened
    remove_worked = $removeWorked
    open_worked = $openWorked
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
