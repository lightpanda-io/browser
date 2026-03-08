$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-remove"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8211
$browserOut = Join-Path $Root "chrome-browser-pages-history-remove.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history-remove.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history-remove.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history-remove.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$server = $null
$browser = $null
$ready = $false
$historyOpened = $false
$removeWorked = $false
$traverseWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "history remove server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history remove window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "history remove initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Pages Two"
  if (-not $titles.page_two) { throw "history remove page two navigation failed" }

  $titles.page_three = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Pages Three"
  if (-not $titles.page_three) { throw "history remove page three navigation failed" }

  $titles.middle = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history/traverse/1" "Browser Pages Two"
  if (-not $titles.middle) { throw "history remove traverse to middle entry failed" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (3)"
  $historyOpened = [bool]$titles.history
  if (-not $historyOpened) { throw "history remove browser://history did not load" }

  $titles.after_remove = Invoke-BrowserPagesDocumentAction $hwnd 12 $browser.Id "Browser History (2)"
  $removeWorked = [bool]$titles.after_remove
  if (-not $removeWorked) { throw "history remove document action failed" }

  $titles.after_traverse = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history/traverse/0" "Browser Pages Two"
  $traverseWorked = [bool]$titles.after_traverse
  if (-not $traverseWorked) { throw "history remove did not retarget index 0 to page two" }
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
    remove_worked = $removeWorked
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
