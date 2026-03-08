$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-sort"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8206
$browserOut = Join-Path $Root "chrome-browser-pages-history-sort.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history-sort.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history-sort.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history-sort.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

function Find-HistorySortTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  for ($count = 1; $count -le 18; $count++) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://history/filter-clear" "Browser History (2)" | Out-Null
    Invoke-BrowserPagesDocumentActionNoNavigate $Hwnd $count 500
    $title = Get-SmokeWindowTitle $Hwnd
    if ($title -like "*Browser History (2, newest first)*") {
      return [pscustomobject]@{ Worked = $true; Count = $count; Title = $title }
    }
  }
  return [pscustomobject]@{ Worked = $false; Count = -1; Title = (Get-SmokeWindowTitle $Hwnd) }
}

function Find-HistoryOpenTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  for ($count = 1; $count -le 20; $count++) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://history/filter-clear" "Browser History (2)" | Out-Null
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://history/sort/newest-first" "Browser History (2, newest first)" | Out-Null
    $result = Invoke-BrowserPagesDocumentAction $Hwnd $count $BrowserId "Browser Pages Two"
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
  if (-not $ready) { throw "history sort server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history sort window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "history sort initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "history sort seed navigation to page two failed" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (2)"
  $opened = [bool]$titles.history
  if (-not $opened) { throw "browser://history did not load" }

  $sortAttempt = Find-HistorySortTabCount $hwnd $browser.Id
  $sortWorked = [bool]$sortAttempt.Worked
  $sortCount = [int]$sortAttempt.Count
  $titles.sorted = $sortAttempt.Title
  if (-not $sortWorked) { throw "history sort document action did not reach newest first" }

  $openAttempt = Find-HistoryOpenTabCount $hwnd $browser.Id
  $openWorked = [bool]$openAttempt.Worked
  $openCount = [int]$openAttempt.Count
  $titles.opened = $openAttempt.Title
  if (-not $openWorked) { throw "history sorted first-row open action did not reach page two" }
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
