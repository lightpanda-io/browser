$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-tabs-recovery"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8191
$browserOut = Join-Path $Root "chrome-browser-pages-tabs-recovery.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-tabs-recovery.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-tabs-recovery.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-tabs-recovery.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$reloadWorked = $false
$closeWorked = $false
$reopenWorked = $false
$restoredCountWorked = $false
$pageTwoRequests = 0
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "tabs recovery server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "tabs recovery window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "tabs recovery initial page did not load" }

  Send-SmokeCtrlT
  $titles.content_tab = Wait-TabTitle $browser.Id "New Tab" 40
  if (-not $titles.content_tab) { throw "tabs recovery did not open the second blank tab" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "tabs recovery navigation to page two failed" }

  Send-SmokeCtrlShiftTab
  $titles.page_one_again = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.page_one_again) { throw "tabs recovery did not return to the first tab" }

  $titles.page_two_after_reload = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs/reload/1" "Browser Pages Two"
  if (-not $titles.page_two_after_reload) { throw "tabs route reload did not activate the target tab" }
  Start-Sleep -Milliseconds 700
  $pageTwoRequests = @((Get-Content $serverErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /page-two\.html' }).Count
  $reloadWorked = $pageTwoRequests -ge 2
  if (-not $reloadWorked) { throw "tabs route reload did not trigger a second page-two request" }

  Send-SmokeCtrlShiftTab
  $titles.page_one_after_reload = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.page_one_after_reload) { throw "tabs recovery did not return to the launcher tab after reload" }

  $titles.page_one_after_close = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs/close/1" "Browser Pages One"
  $closeWorked = [bool]$titles.page_one_after_close
  if (-not $closeWorked) { throw "tabs route close did not keep the launcher tab active" }

  $titles.page_two_reopened = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs/reopen-closed" "Browser Pages Two"
  $reopenWorked = [bool]$titles.page_two_reopened
  if (-not $reopenWorked) { throw "tabs route reopen-closed did not restore the closed tab" }

  Send-SmokeCtrlShiftTab
  $titles.page_one_restored = Wait-TabTitle $browser.Id "Browser Pages One" 40
  $restoredCountWorked = [bool]$titles.page_one_restored
  if (-not $restoredCountWorked) { throw "tabs recovery could not switch back to the launcher tab after reopen" }
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
    reload_worked = $reloadWorked
    close_worked = $closeWorked
    reopen_worked = $reopenWorked
    restored_count_worked = $restoredCountWorked
    page_two_requests = $pageTwoRequests
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
