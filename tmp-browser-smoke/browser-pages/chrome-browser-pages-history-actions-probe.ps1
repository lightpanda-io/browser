$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-actions"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8184
$browserOut = Join-Path $Root "chrome-browser-pages-history.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$server = $null
$browser = $null
$ready = $false
$navigated = $false
$historyOpened = $false
$reloadWorked = $false
$traverseWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "history actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history actions window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  $navigated = [bool]$titles.page_two
  if (-not $navigated) { throw "navigation to page two failed" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (2)"
  $historyOpened = [bool]$titles.history
  if (-not $historyOpened) { throw "browser://history did not load" }

  Send-SmokeF5
  Start-Sleep -Milliseconds 500
  $titles.history_after_reload = Get-SmokeWindowTitle $hwnd
  $reloadWorked = $titles.history_after_reload -like "*Browser History (2)*"
  if (-not $reloadWorked) { throw "history page did not survive reload" }

  Invoke-BrowserPagesTabActivate $hwnd 5
  $titles.page_one = Wait-TabTitle $browser.Id "Browser Pages One" 40
  $traverseWorked = [bool]$titles.page_one
  if (-not $traverseWorked) { throw "history traverse action failed" }
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
    history_opened = $historyOpened
    reload_worked = $reloadWorked
    traverse_worked = $traverseWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
