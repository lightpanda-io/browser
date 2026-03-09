$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$homePort = 8211
$retryPort = 8212
$homeServerOut = Join-Path $Root "chrome-browser-pages-error-status.home.server.stdout.txt"
$homeServerErr = Join-Path $Root "chrome-browser-pages-error-status.home.server.stderr.txt"
$retryServerOut = Join-Path $Root "chrome-browser-pages-error-status.retry.server.stdout.txt"
$retryServerErr = Join-Path $Root "chrome-browser-pages-error-status.retry.server.stderr.txt"
$browserOut = Join-Path $Root "chrome-browser-pages-error-status.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-error-status.browser.stderr.txt"
Remove-Item $homeServerOut,$homeServerErr,$retryServerOut,$retryServerErr,$browserOut,$browserErr -Force -ErrorAction SilentlyContinue

$profileRoot = Join-Path $Root "profile-error-status"
$app = Reset-BrowserPagesProfile $profileRoot
Seed-BrowserPagesProfile `
  -AppDataRoot $app.AppDataRoot `
  -DownloadsDir $app.DownloadsDir `
  -Port $homePort `
  -RestorePreviousSession $true `
  -AllowScriptPopups $false `
  -DefaultZoomPercent 120 `
  -HomepageUrl "http://127.0.0.1:$homePort/index.html"

$homeServer = $null
$retryServer = $null
$browser = $null
$failure = $null
$homeReady = $false
$retryReady = $false
$titles = [ordered]@{}

try {
  $homeServer = Start-BrowserPagesServer -Port $homePort -Stdout $homeServerOut -Stderr $homeServerErr
  $homeReady = Wait-BrowserPagesServer -Port $homePort
  if (-not $homeReady) { throw "error status home server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$homePort/page-two.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "error status browser window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages Two" 40
  if (-not $titles.initial) { throw "initial page did not load" }

  $titles.error = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$retryPort/index.html" "Navigation Error"
  if (-not $titles.error) { throw "navigation error page did not open" }

  $titles.start = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://start" "Browser Start"
  if (-not $titles.start) { throw "browser start did not open" }

  $titles.error_from_start = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://error" "Navigation Error"
  if (-not $titles.error_from_start) { throw "start page did not preserve current error state" }

  $titles.tabs = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://tabs" "Browser Tabs (1)"
  if (-not $titles.tabs) { throw "tabs page did not open" }

  $titles.error_from_tabs = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://error" "Navigation Error"
  if (-not $titles.error_from_tabs) { throw "tabs page did not preserve current error state" }

  $retryServer = Start-BrowserPagesServer -Port $retryPort -Stdout $retryServerOut -Stderr $retryServerErr
  $retryReady = Wait-BrowserPagesServer -Port $retryPort
  if (-not $retryReady) { throw "retry server did not become ready" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 150
  $titles.retry = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$retryPort/index.html" "Browser Pages One"
  if (-not $titles.retry) { throw "recovered navigation did not reach the target page" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $retryServerMeta = Stop-OwnedProbeProcess $retryServer
  Start-Sleep -Milliseconds 200
  $retryServerGone = if ($retryServer) { -not (Get-Process -Id $retryServer.Id -ErrorAction SilentlyContinue) } else { $true }
  $homeServerMeta = Stop-OwnedProbeProcess $homeServer
  Start-Sleep -Milliseconds 200
  $homeServerGone = if ($homeServer) { -not (Get-Process -Id $homeServer.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    home_ready = $homeReady
    retry_ready = $retryReady
    error_opened = [bool]$titles.error
    start_page_exposed_error = [bool]$titles.error_from_start
    tabs_page_exposed_error = [bool]$titles.error_from_tabs
    retry_worked = [bool]$titles.retry
    error = $failure
    titles = $titles
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    browser_meta = $browserMeta
    browser_gone = $browserGone
    retry_server_pid = if ($retryServer) { $retryServer.Id } else { 0 }
    retry_server_meta = $retryServerMeta
    retry_server_gone = $retryServerGone
    home_server_pid = if ($homeServer) { $homeServer.Id } else { 0 }
    home_server_meta = $homeServerMeta
    home_server_gone = $homeServerGone
  } | ConvertTo-Json -Depth 6
}

if ($failure) { exit 1 }
if (-not $titles.error -or -not $titles.error_from_start -or -not $titles.error_from_tabs -or -not $titles.retry) {
  exit 1
}
