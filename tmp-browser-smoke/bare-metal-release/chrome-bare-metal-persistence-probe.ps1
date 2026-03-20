$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-persistence-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-persistence-probe.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-persistence.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-persistence.server.stderr.txt"
$browser1Out = Join-Path $root "chrome-bare-metal-persistence.browser1.stdout.txt"
$browser1Err = Join-Path $root "chrome-bare-metal-persistence.browser1.stderr.txt"
$browser2Out = Join-Path $root "chrome-bare-metal-persistence.browser2.stdout.txt"
$browser2Err = Join-Path $root "chrome-bare-metal-persistence.browser2.stderr.txt"
$run1Png = Join-Path $root "chrome-bare-metal-persistence.run1.png"
$run2Png = Join-Path $root "chrome-bare-metal-persistence.run2.png"
$profileRoot = Join-Path $root "profile-persistence"
$profileAppData = Join-Path $profileRoot "lightpanda"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$manifestPath = Join-Path $packageRoot "manifest.json"
$bootBinary = Join-Path $packageRoot "boot\lightpanda.exe"
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"
$port = 8193
$settingsFile = Join-Path $profileAppData "browse-settings-v1.txt"
$bookmarksFile = Join-Path $profileAppData "bookmarks.txt"

Remove-Item $stdout, $stderr, $browser1Out, $browser1Err, $browser2Out, $browser2Err, $serverOut, $serverErr, $run1Png, $run2Png -Force -ErrorAction SilentlyContinue
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

function Invoke-BrowserPagesAddressNavigate([IntPtr]$Hwnd, [int]$BrowserId, [string]$Url, [string]$Needle, [int]$Attempts = 40) {
  Focus-BrowserPagesDocument $Hwnd
  Send-SmokeCtrlL
  Start-Sleep -Milliseconds 120
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText $Url
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  return Wait-TabTitle $BrowserId $Needle $Attempts
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

function Wait-TextFileContains([string]$Path, [string]$Needle, [int]$Attempts = 40, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    if (Test-Path $Path) {
      $content = Get-Content $Path -Raw
      if ($content -match [regex]::Escape($Needle)) {
        return $content
      }
    }
  }
  return $null
}

function Wait-TextFileAbsent([string]$Path, [int]$Attempts = 40, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    if (-not (Test-Path $Path)) {
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
$bookmarkSaved = $false
$bookmarkOpened = $false
$bookmarkCountVisible = $false
$settingsOpened = $false
$defaultZoomSaved = $false
$popupsSaved = $false
$homepageSaved = $false
$homepageWorked = $false
$bookmarksVisibleAfterRestart = $false
$bookmarkOpenedAfterRestart = $false
$settingsOpenedAfterRestart = $false
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
  Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -RestorePreviousSession $true -AllowScriptPopups $false -DefaultZoomPercent 100 -HomepageUrl ""
  $env:LIGHTPANDA_BARE_METAL_INPUT = Join-Path $app.AppDataRoot "bare-metal-input-v1.txt"

  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) {
    throw "bare metal persistence server did not become ready"
  }

  $browser1 = Start-BareMetalReleaseBrowser -ExecutablePath $bootBinary -StartupUrl "http://127.0.0.1:$port/page-two.html" -Stdout $browser1Out -Stderr $browser1Err -ScreenshotPath $run1Png
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) {
    throw "bare metal persistence run1 window handle not found"
  }
  Show-SmokeWindow $hwnd1

  $run1ScreenshotReady = Wait-FileExists $run1Png
  if (-not $run1ScreenshotReady) {
    throw "bare metal persistence run1 screenshot did not become ready"
  }

  $titles.run1_initial = Wait-TabTitle $browser1.Id "Browser Pages Two" 40
  if (-not $titles.run1_initial) {
    throw "bare metal persistence run1 initial page did not load"
  }

  $titles.run1_bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://bookmarks/add-current" "Browser Bookmarks (1)"
  $bookmarkSaved = [bool]$titles.run1_bookmarks
  if (-not $bookmarkSaved) {
    throw "bare metal persistence bookmark add-current failed"
  }

  $bookmarkContent = Wait-TextFileContains $bookmarksFile "http://127.0.0.1:$port/page-two.html"
  if (-not $bookmarkContent) {
    throw "bare metal persistence bookmark file did not persist the current page"
  }
  $bookmarkCountVisible = $bookmarkContent -match [regex]::Escape("http://127.0.0.1:$port/page-two.html")

  $titles.run1_bookmark_open = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://bookmarks/open/0" "Browser Pages Two"
  $bookmarkOpened = [bool]$titles.run1_bookmark_open
  if (-not $bookmarkOpened) {
    throw "bare metal persistence bookmark open after add-current failed"
  }

  $titles.run1_index = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "http://127.0.0.1:$port/index.html" "Browser Pages One"
  if (-not $titles.run1_index) {
    throw "bare metal persistence run1 did not navigate to the homepage candidate"
  }

  $titles.run1_settings = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://settings" "Browser Settings"
  $settingsOpened = [bool]$titles.run1_settings
  if (-not $settingsOpened) {
    throw "bare metal persistence settings page did not open"
  }

  $titles.run1_zoom = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://settings/default-zoom/in" "Browser Settings"
  $defaultZoomSaved = [bool]$titles.run1_zoom
  if (-not $defaultZoomSaved) {
    throw "bare metal persistence settings default zoom action failed"
  }

  $titles.run1_popups = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://settings/toggle-script-popups" "Browser Settings"
  $popupsSaved = [bool]$titles.run1_popups
  if (-not $popupsSaved) {
    throw "bare metal persistence settings popup toggle failed"
  }

  $titles.run1_homepage = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://settings/homepage/set-current" "Browser Settings"
  $homepageSaved = [bool]$titles.run1_homepage
  if (-not $homepageSaved) {
    throw "bare metal persistence settings homepage action failed"
  }

  $settingsContent = Wait-TextFileContains $settingsFile "homepage_url`thttp://127.0.0.1:$port/index.html"
  if (-not $settingsContent) {
    throw "bare metal persistence settings file did not persist the homepage"
  }

  $titles.run1_final = Invoke-BrowserPagesAddressNavigate $hwnd1 $browser1.Id "browser://bookmarks/open/0" "Browser Pages Two"
  if (-not $titles.run1_final) {
    throw "bare metal persistence did not return to the bookmarked page before restart"
  }

  $browser1Meta = Stop-OwnedProbeProcess $browser1
  Start-Sleep -Milliseconds 300
  if (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) {
    throw "bare metal persistence run1 browser did not exit"
  }

  $browser2 = Start-BareMetalReleaseBrowser -ExecutablePath $bootBinary -StartupUrl "http://127.0.0.1:$port/page-two.html" -Stdout $browser2Out -Stderr $browser2Err -ScreenshotPath $run2Png
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) {
    throw "bare metal persistence run2 window handle not found"
  }
  Show-SmokeWindow $hwnd2

  $run2ScreenshotReady = Wait-FileExists $run2Png
  if (-not $run2ScreenshotReady) {
    throw "bare metal persistence run2 screenshot did not become ready"
  }

  $titles.run2_initial = Wait-TabTitle $browser2.Id "Browser Pages Two" 40
  if (-not $titles.run2_initial) {
    throw "bare metal persistence run2 initial page did not load"
  }

  Focus-BrowserPagesDocument $hwnd2
  Send-SmokeAltHome
  $titles.run2_homepage = Wait-TabTitle $browser2.Id "Browser Pages One" 40
  $homepageWorked = [bool]$titles.run2_homepage
  if (-not $homepageWorked) {
    throw "bare metal persistence Alt+Home did not navigate to the persisted homepage"
  }

  $titles.run2_bookmarks = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://bookmarks" "Browser Bookmarks (1)"
  $bookmarksVisibleAfterRestart = [bool]$titles.run2_bookmarks
  if (-not $bookmarksVisibleAfterRestart) {
    throw "bare metal persistence bookmarks page did not show the persisted bookmark"
  }

  $titles.run2_bookmark_open = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://bookmarks/open/0" "Browser Pages Two"
  $bookmarkOpenedAfterRestart = [bool]$titles.run2_bookmark_open
  if (-not $bookmarkOpenedAfterRestart) {
    throw "bare metal persistence bookmark open after restart failed"
  }

  $titles.run2_settings = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://settings" "Browser Settings"
  $settingsOpenedAfterRestart = [bool]$titles.run2_settings
  if (-not $settingsOpenedAfterRestart) {
    throw "bare metal persistence settings page did not open after restart"
  }

  $result = [ordered]@{
    browser1_pid = $browser1.Id
    browser2_pid = $browser2.Id
    server_pid = $server.Id
    ready = $ready
    run1_screenshot_ready = $run1ScreenshotReady
    run2_screenshot_ready = $run2ScreenshotReady
    bookmark_saved = $bookmarkSaved
    bookmark_opened = $bookmarkOpened
    bookmark_count_visible = $bookmarkCountVisible
    settings_opened = $settingsOpened
    default_zoom_saved = $defaultZoomSaved
    popups_saved = $popupsSaved
    homepage_saved = $homepageSaved
    homepage_worked = $homepageWorked
    bookmarks_visible_after_restart = $bookmarksVisibleAfterRestart
    bookmark_opened_after_restart = $bookmarkOpenedAfterRestart
    settings_opened_after_restart = $settingsOpenedAfterRestart
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
    bookmark_saved = if ($result) { $result.bookmark_saved } else { $bookmarkSaved }
    bookmark_opened = if ($result) { $result.bookmark_opened } else { $bookmarkOpened }
    bookmark_count_visible = if ($result) { $result.bookmark_count_visible } else { $bookmarkCountVisible }
    settings_opened = if ($result) { $result.settings_opened } else { $settingsOpened }
    default_zoom_saved = if ($result) { $result.default_zoom_saved } else { $defaultZoomSaved }
    popups_saved = if ($result) { $result.popups_saved } else { $popupsSaved }
    homepage_saved = if ($result) { $result.homepage_saved } else { $homepageSaved }
    homepage_worked = if ($result) { $result.homepage_worked } else { $homepageWorked }
    bookmarks_visible_after_restart = if ($result) { $result.bookmarks_visible_after_restart } else { $bookmarksVisibleAfterRestart }
    bookmark_opened_after_restart = if ($result) { $result.bookmark_opened_after_restart } else { $bookmarkOpenedAfterRestart }
    settings_opened_after_restart = if ($result) { $result.settings_opened_after_restart } else { $settingsOpenedAfterRestart }
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
    bookmarks_file = $bookmarksFile
    settings_file = $settingsFile
  } | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
