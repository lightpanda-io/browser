$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$port = 8194
$serverOut = Join-Path $Root "chrome-browser-pages-tabs-closed-reopen.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-tabs-closed-reopen.server.stderr.txt"
Remove-Item $serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$ready = $false
$routeWorked = $false
$reopenWorked = $false
$workingTabCount = 0
$attempts = @()
$failure = $null

function Wait-TabsPageTitle([int]$BrowserId, [int]$Count, [int]$Attempts = 40) {
  $pretty = Wait-TabTitle $BrowserId "Browser Tabs ($Count)" $Attempts
  if ($pretty) { return $pretty }
  return Wait-TabTitle $BrowserId "browser://tabs" $Attempts
}

function Invoke-TabsPageDocumentAction([IntPtr]$Hwnd, [int]$TabCount, [int]$BrowserId, [string]$Needle, [int]$Attempts = 40) {
  [void](Invoke-SmokeClientClick $Hwnd 120 220)
  Start-Sleep -Milliseconds 150
  for ($i = 0; $i -lt $TabCount; $i++) {
    Send-SmokeTab
    Start-Sleep -Milliseconds 120
  }
  Send-SmokeEnter
  return Wait-TabTitle $BrowserId $Needle $Attempts
}

function Open-PreparedTabsPageSession {
  param(
    [string]$ProfileName,
    [string]$LogStem
  )

  $profileRoot = Join-Path $Root $ProfileName
  $app = Reset-BrowserPagesProfile $profileRoot
  Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -HomepageUrl ""

  $browserOut = Join-Path $Root ($LogStem + ".browser.stdout.txt")
  $browserErr = Join-Path $Root ($LogStem + ".browser.stderr.txt")
  Remove-Item $browserOut,$browserErr -Force -ErrorAction SilentlyContinue

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "window handle not found for $LogStem" }
  Show-SmokeWindow $hwnd

  $titles = [ordered]@{}
  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "initial page did not load for $LogStem" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlT
  $titles.new_tab_two = Wait-TabTitle $browser.Id "New Tab" 40
  if (-not $titles.new_tab_two) { throw "did not open first blank tab for $LogStem" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "did not navigate first blank tab to page two for $LogStem" }

  Send-SmokeCtrlW
  $titles.back_to_one_after_two_close = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.back_to_one_after_two_close) { throw "closing page-two tab did not return to page one for $LogStem" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlT
  $titles.new_tab_one = Wait-TabTitle $browser.Id "New Tab" 40
  if (-not $titles.new_tab_one) { throw "did not open second blank tab for $LogStem" }

  $titles.page_one_copy = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/index.html" "Browser Pages One"
  if (-not $titles.page_one_copy) { throw "did not navigate second blank tab to page one for $LogStem" }

  Send-SmokeCtrlW
  $titles.back_to_one_after_one_close = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.back_to_one_after_one_close) { throw "closing duplicated page one tab did not return to the original tab for $LogStem" }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlShiftA
  $titles.tabs = Wait-TabsPageTitle $browser.Id 1 40
  if (-not $titles.tabs) { throw "Ctrl+Shift+A did not open browser://tabs for $LogStem" }

  return [pscustomobject]@{
    Browser = $browser
    Hwnd = $hwnd
    Titles = $titles
  }
}

function Close-PreparedSession($Session) {
  $browserMeta = if ($Session -and $Session.Browser) { Stop-OwnedProbeProcess $Session.Browser } else { $null }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($Session -and $Session.Browser) { -not (Get-Process -Id $Session.Browser.Id -ErrorAction SilentlyContinue) } else { $true }
  return [pscustomobject]@{
    browser_pid = if ($Session -and $Session.Browser) { $Session.Browser.Id } else { 0 }
    browser_meta = $browserMeta
    browser_gone = $browserGone
  }
}

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "tabs closed reopen server did not become ready" }

  $routeSession = $null
  try {
    $routeSession = Open-PreparedTabsPageSession "profile-tabs-closed-reopen-route" "chrome-browser-pages-tabs-closed-reopen.route"
    $routeTitle = Invoke-BrowserPagesAddressNavigate $routeSession.Hwnd $routeSession.Browser.Id "browser://tabs/reopen-closed/1" "Browser Pages Two"
    $routeWorked = [bool]$routeTitle
    $attempts += [pscustomobject][ordered]@{
      mode = "route"
      worked = $routeWorked
      title = $routeTitle
      titles = $routeSession.Titles
    }
    if (-not $routeWorked) { throw "address route browser://tabs/reopen-closed/1 did not reopen page two" }
  } finally {
    $routeCleanup = Close-PreparedSession $routeSession
  }

  foreach ($tabCount in @(13, 12, 11, 14)) {
    $docSession = $null
    try {
      $docSession = Open-PreparedTabsPageSession ("profile-tabs-closed-reopen-doc-" + $tabCount) ("chrome-browser-pages-tabs-closed-reopen.doc-" + $tabCount)
      $docTitle = Invoke-TabsPageDocumentAction $docSession.Hwnd $tabCount $docSession.Browser.Id "Browser Pages Two"
      $docWorked = [bool]$docTitle
      $attempts += [pscustomobject][ordered]@{
        mode = "document"
        tab_count = $tabCount
        worked = $docWorked
        title = $docTitle
        titles = $docSession.Titles
      }
      if ($docWorked) {
        $reopenWorked = $true
        $workingTabCount = $tabCount
        break
      }
    } finally {
      $docCleanup = Close-PreparedSession $docSession
    }
  }

  if (-not $reopenWorked) { throw "browser://tabs indexed reopen did not reopen the older page-two tab through document actions" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  Start-Sleep -Milliseconds 200
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    ready = $ready
    route_worked = $routeWorked
    reopen_worked = $reopenWorked
    working_tab_count = $workingTabCount
    attempts = $attempts
    route_cleanup = $routeCleanup
    last_doc_cleanup = $docCleanup
    error = $failure
    server_meta = $serverMeta
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 8
}

if ($failure) { exit 1 }
