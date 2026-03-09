$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-bookmarks-sort"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8207
$browserOut = Join-Path $Root "chrome-browser-pages-bookmarks-sort.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-bookmarks-sort.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-bookmarks-sort.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-bookmarks-sort.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/page-two.html",
  "http://127.0.0.1:$port/index.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks

function Find-BookmarkSortTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  foreach ($count in @(7)) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://bookmarks/filter-clear" "Browser Bookmarks (2)" | Out-Null
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://bookmarks" "Browser Bookmarks (2)" | Out-Null
    Invoke-BrowserPagesDocumentActionNoNavigate $Hwnd $count 500
    $title = Get-SmokeWindowTitle $Hwnd
    if ($title -like "*Browser Bookmarks (2, alphabetical)*") {
      return [pscustomobject]@{ Worked = $true; Count = $count; Title = $title }
    }
  }
  return [pscustomobject]@{ Worked = $false; Count = -1; Title = (Get-SmokeWindowTitle $Hwnd) }
}

function Find-BookmarkOpenTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  foreach ($count in @(11, 12)) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://bookmarks/filter-clear" "Browser Bookmarks (2)" | Out-Null
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://bookmarks/sort/alphabetical" "Browser Bookmarks (2, alphabetical)" | Out-Null
    $result = Invoke-BrowserPagesDocumentAction $Hwnd $count $BrowserId "Browser Pages One"
    if ($result) {
      return [pscustomobject]@{ Worked = $true; Count = $count; Title = $result }
    }
  }
  return [pscustomobject]@{ Worked = $false; Count = -1; Title = (Get-SmokeWindowTitle $Hwnd) }
}

$server = $null
$browser = $null
$ready = $false
$opened = $false
$sortWorked = $false
$openWorked = $false
$sortCount = -1
$openCount = -1
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "bookmarks sort server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmarks sort window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "bookmarks sort initial page did not load" }

  $titles.bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://bookmarks" "Browser Bookmarks (2)"
  $opened = [bool]$titles.bookmarks
  if (-not $opened) { throw "browser://bookmarks did not load" }

  $sortAttempt = Find-BookmarkSortTabCount $hwnd $browser.Id
  $sortWorked = [bool]$sortAttempt.Worked
  $sortCount = [int]$sortAttempt.Count
  $titles.sorted = $sortAttempt.Title
  if (-not $sortWorked) { throw "bookmark sort document action did not reach alphabetical" }

  $openAttempt = Find-BookmarkOpenTabCount $hwnd $browser.Id
  $openWorked = [bool]$openAttempt.Worked
  $openCount = [int]$openAttempt.Count
  $titles.opened = $openAttempt.Title
  if (-not $openWorked) { throw "bookmark sorted first-row open action did not reach page one" }
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
    sort_worked = $sortWorked
    open_worked = $openWorked
    sort_count = $sortCount
    open_count = $openCount
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
