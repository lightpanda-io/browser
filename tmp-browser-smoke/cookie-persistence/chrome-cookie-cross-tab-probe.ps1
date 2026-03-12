$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\cookie-persistence\CookieProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-cookie-cross-tab"
$app = Reset-CookieProfile $profileRoot
Seed-CookieProfile $app.AppDataRoot
$port = 8192
$browserOut = Join-Path $Root "chrome-cookie-cross-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-cookie-cross-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-cookie-cross-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-cookie-cross-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$seedWorked = $false
$echoWorked = $false
$seedTabRetained = $false
$cookiePersisted = $false
$failure = $null
$titles = [ordered]@{}
$cookieData = ""

try {
  $server = Start-CookieServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-CookieServer -Port $port
  if (-not $ready) { throw "cookie server did not become ready" }

  $browser = Start-CookieBrowser -StartupUrl "http://127.0.0.1:$port/seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "cookie cross-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-TabTitle $browser.Id "Cookie Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not load" }
  $cookieData = Wait-CookieFileMatch $app.CookiesFile "cookie\tlppersist\tok\t127.0.0.1\t/"
  $cookiePersisted = [bool]$cookieData
  if (-not $cookiePersisted) { throw "seed cookie did not settle to disk before cross-tab check" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-CookieAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/echo.html" "Cookie Echo ok"
  $echoWorked = [bool]$titles.echo
  if (-not $echoWorked) { throw "cookie echo in new tab did not see shared cookie" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-TabTitle $browser.Id "Cookie Seeded" 30
  $seedTabRetained = [bool]$titles.back_to_seed
  if (-not $seedTabRetained) { throw "seed tab was not preserved after cross-tab check" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  $result = [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    seed_worked = $seedWorked
    cookie_persisted = $cookiePersisted
    echo_worked = $echoWorked
    seed_tab_retained = $seedTabRetained
    cookie_file = if ($cookieData) { $cookieData } else { Read-CookieFileData $app.CookiesFile }
    titles = $titles
    error = $failure
    server_meta = Format-CookieProbeProcessMeta $serverMeta
    browser_meta = Format-CookieProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-CookieProbeResult $result

  if ($failure -or -not $seedWorked -or -not $cookiePersisted -or -not $echoWorked -or -not $seedTabRetained) {
    exit 1
  }
}
