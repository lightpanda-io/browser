$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-open-new-tab"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8203
$browserOut = Join-Path $Root "chrome-browser-pages-history-open-new-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history-open-new-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history-open-new-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history-open-new-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$server = $null
$browser = $null
$ready = $false
$historyOpened = $false
$openNewTabWorked = $false
$returnedWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "history open-new-tab server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history open-new-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "history open-new-tab initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "history open-new-tab seed navigation to page two failed" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (2)"
  $historyOpened = [bool]$titles.history
  if (-not $historyOpened) { throw "browser://history did not load" }

  $titles.opened = Invoke-BrowserPagesDocumentAction $hwnd 11 $browser.Id "Browser Pages One"
  $openNewTabWorked = [bool]$titles.opened
  if (-not $openNewTabWorked) { throw "history open-in-new-tab document action did not open page one" }

  Send-SmokeCtrlShiftTab
  $titles.returned = Wait-TabTitle $browser.Id "Browser History (2)" 40
  $returnedWorked = [bool]$titles.returned
  if (-not $returnedWorked) { throw "history open-in-new-tab did not preserve the original history tab" }
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
