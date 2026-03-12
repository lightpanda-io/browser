$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\cookie-persistence\CookieProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-cookie-clear"
$app = Reset-CookieProfile $profileRoot
Seed-CookieProfile $app.AppDataRoot
$port = 8194
$browserOneOut = Join-Path $Root "chrome-cookie-clear.run1.browser.stdout.txt"
$browserOneErr = Join-Path $Root "chrome-cookie-clear.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $Root "chrome-cookie-clear.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $Root "chrome-cookie-clear.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-cookie-clear.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-cookie-clear.server.stderr.txt"
Remove-Item $browserOneOut,$browserOneErr,$browserTwoOut,$browserTwoErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browserOne = $null
$browserTwo = $null
$ready = $false
$seedWorked = $false
$settingsOpened = $false
$clearInvoked = $false
$missingAfterClear = $false
$missingAfterRestart = $false
$cookieClearedOnDisk = $false
$browserOneGoneBeforeRestart = $false
$failure = $null
$titles = [ordered]@{}
$cookieData = ""

try {
  $server = Start-CookieServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-CookieServer -Port $port
  if (-not $ready) { throw "cookie server did not become ready" }

  $browserOne = Start-CookieBrowser -StartupUrl "http://127.0.0.1:$port/seed.html" -Stdout $browserOneOut -Stderr $browserOneErr
  $hwndOne = Wait-TabWindowHandle $browserOne.Id
  if ($hwndOne -eq [IntPtr]::Zero) { throw "cookie clear run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-TabTitle $browserOne.Id "Cookie Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not load" }

  $titles.settings = Invoke-CookieAddressNavigate $hwndOne $browserOne.Id "browser://settings" "Browser Settings"
  $settingsOpened = [bool]$titles.settings
  if (-not $settingsOpened) { throw "browser://settings did not load" }

  Invoke-CookieSettingsClear $hwndOne
  $titles.settings_after_clear = Wait-TabTitle $browserOne.Id "Browser Settings" 20
  $clearInvoked = [bool]$titles.settings_after_clear
  if (-not $clearInvoked) { throw "settings clear action did not return to Browser Settings" }

  $cookieData = Wait-CookieFileNoMatch $app.CookiesFile "cookie\tlppersist\tok\t127.0.0.1\t/"
  $cookieClearedOnDisk = [bool]$cookieData
  if (-not $cookieClearedOnDisk) { throw "cookie persisted file still contains cleared cookie" }

  $titles.echo_missing = Invoke-CookieAddressNavigate $hwndOne $browserOne.Id "http://127.0.0.1:$port/echo.html" "Cookie Echo missing"
  $missingAfterClear = [bool]$titles.echo_missing
  if (-not $missingAfterClear) { throw "cookie echo after clear still showed cookie" }

  $browserOneMeta = Stop-OwnedProbeProcess $browserOne
  $browserOneGoneBeforeRestart = Wait-OwnedProbeProcessGone $browserOne.Id
  $browserOne = $null
  if (-not $browserOneGoneBeforeRestart) { throw "run1 browser pid did not exit before restart" }
  Start-Sleep -Milliseconds 300

  $browserTwo = Start-CookieBrowser -StartupUrl "http://127.0.0.1:$port/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "cookie clear run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart_missing = Wait-TabTitle $browserTwo.Id "Cookie Echo missing" 40
  $missingAfterRestart = [bool]$titles.restart_missing
  if (-not $missingAfterRestart) { throw "cookie remained present after restart" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserOneMetaFinal = if ($browserOne) { Stop-OwnedProbeProcess $browserOne } else { $null }
  $browserTwoMeta = Stop-OwnedProbeProcess $browserTwo
  Start-Sleep -Milliseconds 200
  $browserOneGone = if ($browserOne) { -not (Get-Process -Id $browserOne.Id -ErrorAction SilentlyContinue) } else { $true }
  $browserTwoGone = if ($browserTwo) { -not (Get-Process -Id $browserTwo.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  if (-not $cookieData) { $cookieData = Read-CookieFileData $app.CookiesFile }
  $browserOneMetaValue = if ($browserOneMeta) { $browserOneMeta } else { $browserOneMetaFinal }

  $result = [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_one_pid = if ($browserOne) { $browserOne.Id } else { 0 }
    browser_two_pid = if ($browserTwo) { $browserTwo.Id } else { 0 }
    ready = $ready
    seed_worked = $seedWorked
    settings_opened = $settingsOpened
    clear_invoked = $clearInvoked
    cookie_cleared_on_disk = $cookieClearedOnDisk
    missing_after_clear = $missingAfterClear
    missing_after_restart = $missingAfterRestart
    titles = $titles
    cookie_file = $cookieData
    error = $failure
    server_meta = Format-CookieProbeProcessMeta $serverMeta
    browser_one_meta = Format-CookieProbeProcessMeta $browserOneMetaValue
    browser_two_meta = Format-CookieProbeProcessMeta $browserTwoMeta
    browser_one_gone_before_restart = $browserOneGoneBeforeRestart
    browser_one_gone = $browserOneGone
    browser_two_gone = $browserTwoGone
    server_gone = $serverGone
  }
  Write-CookieProbeResult $result

  if ($failure -or -not $seedWorked -or -not $settingsOpened -or -not $clearInvoked -or -not $cookieClearedOnDisk -or -not $missingAfterClear -or -not $missingAfterRestart) {
    exit 1
  }
}
