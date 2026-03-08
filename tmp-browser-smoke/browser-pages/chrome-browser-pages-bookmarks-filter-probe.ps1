$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-filter"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8192
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-filter.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-filter.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-filter.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-filter.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://localhost:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks

$server = $null
$browser = $null
$ready = $false
$opened = $false
$quickFilterWorked = $false
$clearWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmarks filter server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmarks filter window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (2)"
  $opened = [bool]$titles.bookmarks
  if (-not $opened) { throw "browser://bookmarks did not open" }

  $titles.filtered = Invoke-BrowserPagesDocumentAction $hwnd 8 $browser.Id "Browser Bookmarks (1/2)"
  $quickFilterWorked = [bool]$titles.filtered
  if (-not $quickFilterWorked) { throw "bookmark quick filter did not apply" }

  $titles.cleared = Invoke-BrowserPagesDocumentAction $hwnd 6 $browser.Id "Browser Bookmarks (2)"
  $clearWorked = [bool]$titles.cleared
  if (-not $clearWorked) { throw "bookmark filter clear did not restore full view" }
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
    quick_filter_worked = $quickFilterWorked
    clear_worked = $clearWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
