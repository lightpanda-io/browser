$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-address"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8183
$browserOut = Join-Path $Root "chrome-browser-pages-address.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-address.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-address.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-address.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -AllowScriptPopups $true -Bookmarks $bookmarks -SeedDownload

$server = $null
$browser = $null
$ready = $false
$navigated = $false
$startWorked = $false
$historyWorked = $false
$bookmarksWorked = $false
$downloadsWorked = $false
$settingsWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "browser pages alias server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "browser pages alias window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "browser pages alias initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  $navigated = [bool]$titles.page_two
  if (-not $navigated) { throw "browser pages alias navigation to page two failed" }

  $titles.start = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://start" "Browser Start"
  $startWorked = [bool]$titles.start
  if (-not $startWorked) { throw "browser://start did not load" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (2)"
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) { throw "browser://history did not load" }

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (2)"
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) { throw "browser://bookmarks did not load" }

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) { throw "browser://downloads did not load" }

  $titles.settings = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://settings" "Browser Settings"
  $settingsWorked = [bool]$titles.settings
  if (-not $settingsWorked) { throw "browser://settings did not load" }
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
    start_worked = $startWorked
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
