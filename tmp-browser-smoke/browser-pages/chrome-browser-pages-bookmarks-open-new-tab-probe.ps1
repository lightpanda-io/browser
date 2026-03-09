$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-open-new-tab"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8204
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-open-new-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-open-new-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-open-new-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-open-new-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks

$server = $null
$browser = $null
$ready = $false
$bookmarksOpened = $false
$openNewTabWorked = $false
$returnedWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmarks open-new-tab server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmarks open-new-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "bookmarks open-new-tab initial page did not load" }

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (1)"
  $bookmarksOpened = [bool]$titles.bookmarks
  if (-not $bookmarksOpened) { throw "browser://bookmarks did not load" }

  $titles.opened = Invoke-BrowserPagesDocumentAction $hwnd 12 $browser.Id "Browser Pages Two"
  $openNewTabWorked = [bool]$titles.opened
  if (-not $openNewTabWorked) { throw "bookmark open-in-new-tab document action did not open page two" }

  Send-SmokeCtrlShiftTab
  $titles.returned = Wait-TabTitle $browser.Id "Browser Bookmarks (1)" 40
  $returnedWorked = [bool]$titles.returned
  if (-not $returnedWorked) { throw "bookmark open-in-new-tab did not preserve the original bookmarks tab" }
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
    open_new_tab_worked = $openNewTabWorked
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
