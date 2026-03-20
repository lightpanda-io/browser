$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-start-shell-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-start-shell-probe.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-start-shell.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-start-shell.server.stderr.txt"
$browserOut = Join-Path $root "chrome-bare-metal-start-shell.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-bare-metal-start-shell.browser.stderr.txt"
$initialPng = Join-Path $root "chrome-bare-metal-start-shell.initial.png"
$profileRoot = Join-Path $root "profile-start-shell"
$releaseBrowserExe = Join-Path $packageRoot "boot\lightpanda.exe"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$manifestPath = Join-Path $packageRoot "manifest.json"
$bootBinary = $releaseBrowserExe
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"
$port = 8191

Remove-Item $stdout, $stderr, $browserOut, $browserErr, $serverOut, $serverErr, $initialPng -Force -ErrorAction SilentlyContinue
Remove-Item $profileRoot -Recurse -Force -ErrorAction SilentlyContinue

. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

function Start-BareMetalReleaseBrowser {
  param(
    [string]$ExecutablePath,
    [string]$StartupUrl,
    [string]$Stdout,
    [string]$Stderr,
    [string]$ScreenshotPath
  )

  $arguments = @(
    "browse",
    $StartupUrl,
    "--window_width",
    "960",
    "--window_height",
    "640",
    "--screenshot_png",
    $ScreenshotPath
  )

  return Start-Process -FilePath $ExecutablePath -ArgumentList $arguments -WorkingDirectory $repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Wait-FileExists([string]$Path, [int]$Attempts = 60, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
      return $true
    }
  }
  return $false
}

$failure = $null
$result = $null
$server = $null
$browser = $null
$ready = $false
$startWorked = $false
$tabsWorked = $false
$historyWorked = $false
$bookmarksWorked = $false
$downloadsWorked = $false
$settingsWorked = $false
$roundTripWorked = $false
$tabsOpened = $false
$tabsSwitchedForward = $false
$tabsSwitchedBack = $false
$tabsClosed = $false
$screenshotReady = $false
$titles = [ordered]@{}

try {
  if (-not (Test-Path $manifestPath) -or -not (Test-Path $bootBinary) -or -not (Test-Path $archivePath)) {
    & $packageScript -PackageRoot $packageRoot -Url "https://example.com/" | Tee-Object -FilePath $stdout | ConvertFrom-Json | Out-Null
  }

  if (-not (Test-Path $manifestPath)) {
    throw "manifest missing: $manifestPath"
  }

  if (-not (Test-Path $bootBinary)) {
    throw "boot binary missing: $bootBinary"
  }

  if (-not (Test-Path $archivePath)) {
    throw "archive missing: $archivePath"
  }

  $app = Reset-BrowserPagesProfile $profileRoot
  $bookmarks = @(
    "http://127.0.0.1:$port/index.html",
    "http://127.0.0.1:$port/page-two.html"
  )
  Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -Bookmarks $bookmarks -SeedDownload -HomepageUrl ""
  $env:LIGHTPANDA_BARE_METAL_INPUT = Join-Path $app.AppDataRoot "bare-metal-input-v1.txt"

  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) {
    throw "bare metal start shell server did not become ready"
  }

  $browser = Start-BareMetalReleaseBrowser -ExecutablePath $releaseBrowserExe -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr -ScreenshotPath $initialPng
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "bare metal start shell window handle not found"
  }
  Show-SmokeWindow $hwnd

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) {
      $screenshotReady = $true
      break
    }
  }
  if (-not $screenshotReady) {
    throw "bare metal start shell screenshot did not become ready"
  }

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) {
    throw "bare metal start shell initial page did not load"
  }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeAltHome
  $titles.start = Wait-TabTitle $browser.Id "Browser Start" 40
  $startWorked = [bool]$titles.start
  if (-not $startWorked) {
    throw "Alt+Home did not open Browser Start"
  }

  $titles.tabs = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Tabs (1)"
  $tabsWorked = [bool]$titles.tabs
  if (-not $tabsWorked) {
    throw "start shell tabs link failed"
  }

$titles.history = Invoke-BrowserPagesDocumentAction $hwnd 2 $browser.Id "Browser History"
  $historyWorked = [bool]$titles.history
  if (-not $historyWorked) {
    throw "start shell history link failed"
  }

$titles.bookmarks = Invoke-BrowserPagesDocumentAction $hwnd 3 $browser.Id "Browser Bookmarks"
  $bookmarksWorked = [bool]$titles.bookmarks
  if (-not $bookmarksWorked) {
    throw "start shell bookmarks link failed"
  }

$titles.downloads = Invoke-BrowserPagesDocumentAction $hwnd 4 $browser.Id "Browser Downloads"
  $downloadsWorked = [bool]$titles.downloads
  if (-not $downloadsWorked) {
    throw "start shell downloads link failed"
  }

  $titles.settings = Invoke-BrowserPagesDocumentAction $hwnd 5 $browser.Id "Browser Settings"
  $settingsWorked = [bool]$titles.settings
  if (-not $settingsWorked) {
    throw "start shell settings link failed"
  }

  $titles.start_round_trip = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Start"
  $roundTripWorked = [bool]$titles.start_round_trip
  if (-not $roundTripWorked) {
    throw "settings page start link failed"
  }

  $titles.tabs_page = Invoke-BrowserPagesDocumentAction $hwnd 1 $browser.Id "Browser Tabs (1)"
  if (-not $titles.tabs_page) {
    throw "start shell tabs link did not reload after the round trip"
  }

  Focus-BrowserPagesDocument $hwnd
  Send-SmokeCtrlT
  $titles.new_tab = Wait-TabTitle $browser.Id "New Tab" 40
  $tabsOpened = [bool]$titles.new_tab
  if (-not $tabsOpened) {
    throw "Ctrl+T did not open a new tab"
  }

  Send-SmokeCtrlTab
  $titles.tabs_after_forward = Wait-TabTitle $browser.Id "Browser Tabs (2)" 40
  $tabsSwitchedForward = [bool]$titles.tabs_after_forward
  if (-not $tabsSwitchedForward) {
    throw "Ctrl+Tab did not switch to the tabs page"
  }

  Send-SmokeCtrlShiftTab
  $titles.new_tab_again = Wait-TabTitle $browser.Id "New Tab" 40
  $tabsSwitchedBack = [bool]$titles.new_tab_again
  if (-not $tabsSwitchedBack) {
    throw "Ctrl+Shift+Tab did not switch back to the new tab"
  }

  Send-SmokeCtrlW
  $titles.tabs_after_close = Wait-TabTitle $browser.Id "Browser Tabs (1)" 40
  $tabsClosed = [bool]$titles.tabs_after_close
  if (-not $tabsClosed) {
    throw "Ctrl+W did not close the new tab and return to the tabs page"
  }

  $result = [ordered]@{
    browser_pid = $browser.Id
    server_pid = $server.Id
    ready = $ready
    screenshot_ready = $screenshotReady
    screenshot_path = $initialPng
    screenshot_length = if (Test-Path $initialPng) { (Get-Item $initialPng).Length } else { 0 }
    start_worked = $startWorked
    tabs_worked = $tabsWorked
    history_worked = $historyWorked
    bookmarks_worked = $bookmarksWorked
    downloads_worked = $downloadsWorked
    settings_worked = $settingsWorked
    round_trip_worked = $roundTripWorked
    tabs_opened = $tabsOpened
    tabs_switched_forward = $tabsSwitchedForward
    tabs_switched_back = $tabsSwitchedBack
    tabs_closed = $tabsClosed
    titles = $titles
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    package_root = $packageRoot
    manifest_path = $manifestPath
    boot_binary = $bootBinary
    archive_path = $archivePath
    browser_pid = if ($result) { $result.browser_pid } else { if ($browser) { $browser.Id } else { 0 } }
    server_pid = if ($result) { $result.server_pid } else { if ($server) { $server.Id } else { 0 } }
    ready = if ($result) { $result.ready } else { $ready }
    screenshot_ready = if ($result) { $result.screenshot_ready } else { $screenshotReady }
    screenshot_path = if ($result) { $result.screenshot_path } else { $initialPng }
    screenshot_length = if ($result) { $result.screenshot_length } else { if (Test-Path $initialPng) { (Get-Item $initialPng).Length } else { 0 } }
    start_worked = if ($result) { $result.start_worked } else { $startWorked }
    tabs_worked = if ($result) { $result.tabs_worked } else { $tabsWorked }
    history_worked = if ($result) { $result.history_worked } else { $historyWorked }
    bookmarks_worked = if ($result) { $result.bookmarks_worked } else { $bookmarksWorked }
    downloads_worked = if ($result) { $result.downloads_worked } else { $downloadsWorked }
    settings_worked = if ($result) { $result.settings_worked } else { $settingsWorked }
    round_trip_worked = if ($result) { $result.round_trip_worked } else { $roundTripWorked }
    tabs_opened = if ($result) { $result.tabs_opened } else { $tabsOpened }
    tabs_switched_forward = if ($result) { $result.tabs_switched_forward } else { $tabsSwitchedForward }
    tabs_switched_back = if ($result) { $result.tabs_switched_back } else { $tabsSwitchedBack }
    tabs_closed = if ($result) { $result.tabs_closed } else { $tabsClosed }
    titles = if ($result) { $result.titles } else { $titles }
    browser_gone = $browserGone
    server_gone = $serverGone
    server_meta = $serverMeta
    browser_meta = $browserMeta
    failure = $failure
    stdout_log = $stdout
    stderr_log = $stderr
    browser_stdout = $browserOut
    browser_stderr = $browserErr
    server_stdout = $serverOut
    server_stderr = $serverErr
  } | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
