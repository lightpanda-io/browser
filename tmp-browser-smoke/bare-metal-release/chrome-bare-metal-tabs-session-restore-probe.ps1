$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-tabs-session-restore-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-tabs-session-restore-probe.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-tabs-session-restore.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-tabs-session-restore.server.stderr.txt"
$browser1Out = Join-Path $root "chrome-bare-metal-tabs-session-restore.browser1.stdout.txt"
$browser1Err = Join-Path $root "chrome-bare-metal-tabs-session-restore.browser1.stderr.txt"
$browser2Out = Join-Path $root "chrome-bare-metal-tabs-session-restore.browser2.stdout.txt"
$browser2Err = Join-Path $root "chrome-bare-metal-tabs-session-restore.browser2.stderr.txt"
$run1Png = Join-Path $root "chrome-bare-metal-tabs-session-restore.run1.png"
$run2Png = Join-Path $root "chrome-bare-metal-tabs-session-restore.run2.png"
$profileRoot = Join-Path $root "profile-tabs-session-restore"
$profileAppData = Join-Path $profileRoot "lightpanda"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$manifestPath = Join-Path $packageRoot "manifest.json"
$bootBinary = Join-Path $packageRoot "boot\lightpanda.exe"
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"
$port = 8192

Remove-Item $stdout, $stderr, $browser1Out, $browser1Err, $browser2Out, $browser2Err, $serverOut, $serverErr, $run1Png, $run2Png -Force -ErrorAction SilentlyContinue
Remove-Item $profileRoot -Recurse -Force -ErrorAction SilentlyContinue

. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$script:Repo = $repo
$script:Root = Join-Path $repo "tmp-browser-smoke\tabs"
$script:BrowserExe = $bootBinary

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
$browser1 = $null
$browser2 = $null
$ready = $false
$run1ScreenshotReady = $false
$run2ScreenshotReady = $false
$sessionPrepared = $false
$restoredTabCount = 0
$restoreWorked = $false
$switchWorked = $false
$closeWorked = $false
$tabsPageWorked = $false
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
  Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -RestorePreviousSession $true -HomepageUrl ""
  $env:LIGHTPANDA_BARE_METAL_INPUT = Join-Path $app.AppDataRoot "bare-metal-input-v1.txt"

  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) {
    throw "bare metal tabs session restore server did not become ready"
  }

  $browser1 = Start-BareMetalReleaseBrowser -ExecutablePath $bootBinary -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browser1Out -Stderr $browser1Err -ScreenshotPath $run1Png
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) {
    throw "bare metal tabs session restore run1 window handle not found"
  }
  Show-SmokeWindow $hwnd1

  $run1ScreenshotReady = Wait-FileExists $run1Png
  if (-not $run1ScreenshotReady) {
    throw "bare metal tabs session restore run1 screenshot did not become ready"
  }

  $titles.run1_initial = Wait-TabTitle $browser1.Id "Tab One" 40
  if (-not $titles.run1_initial) {
    throw "bare metal tabs session restore run1 initial tab did not load"
  }

  Focus-BrowserPagesDocument $hwnd1
  Send-SmokeCtrlT
  $titles.run1_new_tab = Wait-TabTitle $browser1.Id "New Tab" 40
  if (-not $titles.run1_new_tab) {
    throw "bare metal tabs session restore run1 Ctrl+T did not open a new tab"
  }

  Focus-BrowserPagesDocument $hwnd1
  Send-SmokeCtrlL
  Start-Sleep -Milliseconds 120
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText "http://127.0.0.1:$port/two.html"
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  $titles.run1_second_tab = Wait-TabTitle $browser1.Id "Tab Two" 40
  if (-not $titles.run1_second_tab) {
    throw "bare metal tabs session restore run1 did not navigate the new tab to page two"
  }
  $sessionPrepared = $true

  $browser1Meta = Stop-OwnedProbeProcess $browser1
  Start-Sleep -Milliseconds 300
  if (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) {
    throw "bare metal tabs session restore run1 browser did not exit"
  }

  $sessionFile = Join-Path $profileAppData "browse-session-v1.txt"
  if (Test-Path $sessionFile) {
    $restoredTabCount = @(Get-Content $sessionFile | Where-Object { $_ -like "tab`t*" }).Count
  }
  if ($restoredTabCount -lt 2) {
    throw "bare metal tabs session restore did not persist enough tabs for a restart"
  }

  $browser2 = Start-BareMetalReleaseBrowser -ExecutablePath $bootBinary -StartupUrl "browser://tabs" -Stdout $browser2Out -Stderr $browser2Err -ScreenshotPath $run2Png
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) {
    throw "bare metal tabs session restore run2 window handle not found"
  }
  Show-SmokeWindow $hwnd2

  $run2ScreenshotReady = Wait-FileExists $run2Png
  if (-not $run2ScreenshotReady) {
    throw "bare metal tabs session restore run2 screenshot did not become ready"
  }

  $titles.run2_tabs_page = if ($run2ScreenshotReady) { "browser://tabs screenshot ready" } else { $null }
  $restoreWorked = [bool]$run2ScreenshotReady
  if (-not $restoreWorked) {
    throw "bare metal tabs session restore did not open browser://tabs after restart"
  }

  Send-SmokeCtrlTab
  Start-Sleep -Milliseconds 300
  $titles.run2_after_switch = Get-SmokeWindowTitle $hwnd2
  $titles.run2_other = Wait-TabTitle $browser2.Id "Tab One" 40
  $switchWorked = [bool]$titles.run2_other
  if (-not $switchWorked) {
    throw "bare metal tabs session restore did not switch back to the first saved tab"
  }

  Send-SmokeCtrlW
  $titles.run2_after_close = Wait-TabTitle $browser2.Id "Tab Two" 40
  $closeWorked = [bool]$titles.run2_after_close
  $tabsPageWorked = $restoreWorked
  if (-not $closeWorked) {
    throw "bare metal tabs session restore did not close the first saved tab"
  }

  $result = [ordered]@{
    browser1_pid = $browser1.Id
    browser2_pid = $browser2.Id
    server_pid = $server.Id
    ready = $ready
    run1_screenshot_ready = $run1ScreenshotReady
    run2_screenshot_ready = $run2ScreenshotReady
    session_prepared = $sessionPrepared
    restore_worked = $restoreWorked
    switch_worked = $switchWorked
    close_worked = $closeWorked
    tabs_page_worked = $tabsPageWorked
    titles = $titles
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browser1Meta = Stop-OwnedProbeProcess $browser1
  $browser2Meta = Stop-OwnedProbeProcess $browser2
  Start-Sleep -Milliseconds 200
  $browser1Gone = if ($browser1) { -not (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) } else { $true }
  $browser2Gone = if ($browser2) { -not (Get-Process -Id $browser2.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    package_root = $packageRoot
    manifest_path = $manifestPath
    boot_binary = $bootBinary
    archive_path = $archivePath
    browser1_pid = if ($result) { $result.browser1_pid } else { if ($browser1) { $browser1.Id } else { 0 } }
    browser2_pid = if ($result) { $result.browser2_pid } else { if ($browser2) { $browser2.Id } else { 0 } }
    server_pid = if ($result) { $result.server_pid } else { if ($server) { $server.Id } else { 0 } }
    ready = if ($result) { $result.ready } else { $ready }
    run1_screenshot_ready = if ($result) { $result.run1_screenshot_ready } else { $run1ScreenshotReady }
    run2_screenshot_ready = if ($result) { $result.run2_screenshot_ready } else { $run2ScreenshotReady }
    session_prepared = if ($result) { $result.session_prepared } else { $sessionPrepared }
    restore_worked = if ($result) { $result.restore_worked } else { $restoreWorked }
    switch_worked = if ($result) { $result.switch_worked } else { $switchWorked }
    close_worked = if ($result) { $result.close_worked } else { $closeWorked }
    tabs_page_worked = if ($result) { $result.tabs_page_worked } else { $tabsPageWorked }
    titles = if ($result) { $result.titles } else { $titles }
    browser1_gone = $browser1Gone
    browser2_gone = $browser2Gone
    server_gone = $serverGone
    server_meta = $serverMeta
    browser1_meta = $browser1Meta
    browser2_meta = $browser2Meta
    failure = $failure
    stdout_log = $stdout
    stderr_log = $stderr
    browser1_stdout = $browser1Out
    browser1_stderr = $browser1Err
    browser2_stdout = $browser2Out
    browser2_stderr = $browser2Err
    server_stdout = $serverOut
    server_stderr = $serverErr
  } | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
