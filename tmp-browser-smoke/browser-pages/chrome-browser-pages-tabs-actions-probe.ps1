$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-tabs-actions"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8190
$browserOut = Join-Path $Root "chrome-browser-pages-tabs-actions.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-tabs-actions.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-tabs-actions.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-tabs-actions.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$tabsOpened = $false
$newWorked = $false
$activateWorked = $false
$duplicateWorked = $false
$tabsFourWorked = $false
$titles = [ordered]@{}
$failure = $null

function Wait-TabsPageTitle([int]$BrowserId, [int]$Count, [int]$Attempts = 40) {
  $pretty = Wait-TabTitle $BrowserId "Browser Tabs ($Count)" $Attempts
  if ($pretty) { return $pretty }
  return Wait-TabTitle $BrowserId "browser://tabs" $Attempts
}

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "tabs actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "tabs actions window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "tabs actions initial page did not load" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlT
  $titles.new_tab_seed = Wait-TabTitle $browser.Id "New Tab" 40
  if (-not $titles.new_tab_seed) { throw "tabs actions did not open the second blank tab" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "tabs actions navigation to page two failed" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlT
  $titles.tabs_host_tab = Wait-TabTitle $browser.Id "New Tab" 40
  if (-not $titles.tabs_host_tab) { throw "tabs actions did not open the dedicated tabs host tab" }

  $titles.tabs_three = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs" "browser://tabs"
  $tabsOpened = [bool]$titles.tabs_three
  if (-not $tabsOpened) { throw "tabs host tab did not open browser://tabs" }

  $titles.new_tab = Invoke-BrowserPagesDocumentAction $hwnd 6 $browser.Id "New Tab"
  $newWorked = [bool]$titles.new_tab
  if (-not $newWorked) { throw "tabs page new-tab action did not open a blank tab" }

  Send-SmokeCtrlW
  $titles.tabs_after_new_close = Wait-TabsPageTitle $browser.Id 3 40
  if (-not $titles.tabs_after_new_close) { throw "closing the temporary blank tab did not return to the tabs page" }

  $titles.activated_first = Invoke-BrowserPagesDocumentAction $hwnd 8 $browser.Id "Browser Pages One"
  $activateWorked = [bool]$titles.activated_first
  if (-not $activateWorked) { throw "tabs page activate action did not switch to the first tab" }

  Send-SmokeCtrlTab
  $titles.page_two_again = Wait-TabTitle $browser.Id "Browser Pages Two" 40
  if (-not $titles.page_two_again) { throw "Ctrl+Tab did not reach the second content tab" }
  Send-SmokeCtrlTab
  $titles.tabs_three_again = Wait-TabsPageTitle $browser.Id 3 40
  if (-not $titles.tabs_three_again) { throw "Ctrl+Tab did not return to the dedicated tabs page" }

  $titles.duplicate_result = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs/duplicate/1" "Browser Pages Two"
  $duplicateWorked = [bool]$titles.duplicate_result
  if (-not $duplicateWorked) { throw "tabs page duplicate action did not open a duplicated tab" }

  Send-SmokeCtrlShiftTab
  $titles.tabs_four = Wait-TabsPageTitle $browser.Id 4 40
  $tabsFourWorked = [bool]$titles.tabs_four
  if (-not $tabsFourWorked) { throw "tabs page did not reflect the duplicated fourth tab" }
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
    tabs_opened = $tabsOpened
    new_worked = $newWorked
    activate_worked = $activateWorked
    duplicate_worked = $duplicateWorked
    tabs_four_worked = $tabsFourWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
