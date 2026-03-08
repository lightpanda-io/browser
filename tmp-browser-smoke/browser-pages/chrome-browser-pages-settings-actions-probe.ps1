$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-settings-actions"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8187
$browserOut = Join-Path $Root "chrome-browser-pages-settings.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-settings.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-settings.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-settings.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -RestorePreviousSession $true -AllowScriptPopups $false -HomepageUrl "http://127.0.0.1:$port/index.html"
$settingsFile = Join-Path $app.AppDataRoot "browse-settings-v1.txt"

$server = $null
$browser = $null
$ready = $false
$pageTwoWorked = $false
$settingsOpened = $false
$restoreToggled = $false
$popupsToggled = $false
$homepageSet = $false
$settingsData = $null
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "settings actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "settings actions window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  $pageTwoWorked = [bool]$titles.page_two
  if (-not $pageTwoWorked) { throw "navigation to page two failed" }

  $titles.settings = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://settings" "Browser Settings"
  $settingsOpened = [bool]$titles.settings
  if (-not $settingsOpened) { throw "browser://settings did not load" }

  $titles.settings_after_restore = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://settings/toggle-restore-session" "Browser Settings"
  $restoreToggled = [bool]$titles.settings_after_restore
  if (-not $restoreToggled) { throw "restore-session action did not leave settings usable" }

  $titles.settings_after_popups = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://settings/toggle-script-popups" "Browser Settings"
  $popupsToggled = [bool]$titles.settings_after_popups
  if (-not $popupsToggled) { throw "script-popup action did not leave settings usable" }

  $titles.settings_after_homepage = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://settings/homepage/set-current" "Browser Settings"
  $homepageSet = [bool]$titles.settings_after_homepage
  if (-not $homepageSet) { throw "homepage action did not leave settings usable" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  if (Test-Path $settingsFile) { $settingsData = Get-Content $settingsFile -Raw }

  $restoreSaved = $settingsData -match "restore_previous_session\t0"
  $popupsSaved = $settingsData -match "allow_script_popups\t1"
  $homepageSaved = $settingsData -match [regex]::Escape("homepage_url`thttp://127.0.0.1:$port/page-two.html")

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    page_two_worked = $pageTwoWorked
    settings_opened = $settingsOpened
    restore_toggled = $restoreToggled
    popups_toggled = $popupsToggled
    homepage_action_invoked = $homepageSet
    restore_saved = $restoreSaved
    popups_saved = $popupsSaved
    homepage_saved = $homepageSaved
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7

  if ($failure -or -not $restoreSaved -or -not $popupsSaved -or -not $homepageSaved) {
    exit 1
  }
}
