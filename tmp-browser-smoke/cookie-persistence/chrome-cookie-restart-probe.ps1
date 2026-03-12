$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\cookie-persistence\CookieProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-cookie-restart"
$app = Reset-CookieProfile $profileRoot
Seed-CookieProfile $app.AppDataRoot
$port = 8193
$browserOneOut = Join-Path $Root "chrome-cookie-restart.run1.browser.stdout.txt"
$browserOneErr = Join-Path $Root "chrome-cookie-restart.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $Root "chrome-cookie-restart.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $Root "chrome-cookie-restart.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-cookie-restart.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-cookie-restart.server.stderr.txt"
Remove-Item $browserOneOut,$browserOneErr,$browserTwoOut,$browserTwoErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browserOne = $null
$browserTwo = $null
$ready = $false
$seedWorked = $false
$persistedToDisk = $false
$restartWorked = $false
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
  if ($hwndOne -eq [IntPtr]::Zero) { throw "cookie restart run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-TabTitle $browserOne.Id "Cookie Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not load" }

  Start-Sleep -Milliseconds 700
  $cookieData = Read-CookieFileData $app.CookiesFile
  $persistedToDisk = $cookieData -match "cookie\tlppersist\tok\t127.0.0.1\t/"
  if (-not $persistedToDisk) { throw "cookie file was not persisted before restart" }

  $browserOneMeta = Stop-OwnedProbeProcess $browserOne
  $browserOneGoneBeforeRestart = Wait-OwnedProbeProcessGone $browserOne.Id
  $browserOne = $null
  if (-not $browserOneGoneBeforeRestart) { throw "run1 browser pid did not exit before restart" }
  Start-Sleep -Milliseconds 300

  $browserTwo = Start-CookieBrowser -StartupUrl "http://127.0.0.1:$port/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "cookie restart run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart = Wait-TabTitle $browserTwo.Id "Cookie Echo ok" 40
  $restartWorked = [bool]$titles.restart
  if (-not $restartWorked) { throw "restarted browser did not reuse persisted cookie" }
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
    persisted_to_disk = $persistedToDisk
    restart_worked = $restartWorked
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

  if ($failure -or -not $seedWorked -or -not $persistedToDisk -or -not $restartWorked) {
    exit 1
  }
}
