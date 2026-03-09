$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-reorder"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8221
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-reorder.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-reorder.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-reorder.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-reorder.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/page-two.html",
  "http://127.0.0.1:$port/index.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks
$bookmarksFile = Join-Path $app.AppDataRoot "bookmarks.txt"

$server = $null
$browser = $null
$ready = $false
$opened = $false
$reorderWorked = $false
$openWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmarks reorder server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmarks reorder window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "bookmarks reorder initial page did not load" }

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (2)"
  $opened = [bool]$titles.bookmarks
  if (-not $opened) { throw "browser://bookmarks did not load" }

  Invoke-BrowserPagesDocumentActionNoNavigate $hwnd 13 800
  $titles.reordered = Get-SmokeWindowTitle $hwnd
  $bookmarkLines = @((Get-Content $bookmarksFile -ErrorAction SilentlyContinue) | Where-Object { $_ -match '\S' })
  $reorderWorked = ($titles.reordered -like "*Browser Bookmarks (2)*") -and
    ($bookmarkLines.Count -ge 2) -and
    ($bookmarkLines[0] -eq "http://127.0.0.1:$port/index.html") -and
    ($bookmarkLines[1] -eq "http://127.0.0.1:$port/page-two.html")
  if (-not $reorderWorked) { throw "bookmark move-down document action did not reorder persisted bookmarks" }

  $titles.opened = Invoke-BrowserPagesDocumentAction $hwnd 11 $browser.Id "Browser Pages One"
  $openWorked = [bool]$titles.opened
  if (-not $openWorked) { throw "bookmark reordered first-row open action did not reach page one" }
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
    reorder_worked = $reorderWorked
    open_worked = $openWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
