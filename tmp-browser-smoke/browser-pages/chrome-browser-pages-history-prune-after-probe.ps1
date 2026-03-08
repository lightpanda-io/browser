$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-prune-after"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8213
$browserOut = Join-Path $Root "chrome-browser-pages-history-prune-after.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history-prune-after.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history-prune-after.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history-prune-after.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$server = $null
$browser = $null
$ready = $false
$historyOpened = $false
$pruneWorked = $false
$noOpenWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "history prune-after server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history prune-after window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "history prune-after initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Pages Two"
  if (-not $titles.page_two) { throw "history prune-after page two navigation failed" }

  $titles.page_three = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Pages Three"
  if (-not $titles.page_three) { throw "history prune-after page three navigation failed" }

  $titles.page_four = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Pages Four"
  if (-not $titles.page_four) { throw "history prune-after page four navigation failed" }

  $titles.current_middle = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history/traverse/1" "Browser Pages Two"
  if (-not $titles.current_middle) { throw "history prune-after traverse to current entry failed" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (4)"
  $historyOpened = [bool]$titles.history
  if (-not $historyOpened) { throw "history prune-after browser://history did not load" }

  $titles.after_prune = Invoke-BrowserPagesDocumentAction $hwnd 16 $browser.Id "Browser History (2)"
  $pruneWorked = [bool]$titles.after_prune
  if (-not $pruneWorked) { throw "history prune-after document action failed" }

  Invoke-BrowserPagesAddressCommit $hwnd "browser://history/open-new-tab/2"
  Start-Sleep -Milliseconds 1200
  $titles.after_invalid_open = Get-SmokeWindowTitle $hwnd
  $noOpenWorked = $titles.after_invalid_open -like "*Browser History (2)*"
  if (-not $noOpenWorked) { throw "history prune-after still allowed opening removed index 2" }
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
    history_opened = $historyOpened
    prune_worked = $pruneWorked
    no_open_worked = $noOpenWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
