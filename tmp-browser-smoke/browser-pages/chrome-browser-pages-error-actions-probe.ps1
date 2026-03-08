$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$port = 8210
$serverOut = Join-Path $Root "chrome-browser-pages-error-actions.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-error-actions.server.stderr.txt"
$browserOut = Join-Path $Root "chrome-browser-pages-error-actions.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-error-actions.browser.stderr.txt"
Remove-Item $serverOut,$serverErr,$browserOut,$browserErr -Force -ErrorAction SilentlyContinue

$profileRoot = Join-Path $Root "profile-error-actions"
$app = Reset-BrowserPagesProfile $profileRoot
Seed-BrowserPagesProfile `
  -AppDataRoot $app.AppDataRoot `
  -DownloadsDir $app.DownloadsDir `
  -Port $port `
  -RestorePreviousSession $true `
  -AllowScriptPopups $false `
  -DefaultZoomPercent 120 `
  -HomepageUrl "http://127.0.0.1:$port/index.html"

$server = $null
$browser = $null
$failure = $null
$ready = $false
$titles = [ordered]@{}

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "error actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/page-two.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "error actions browser window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages Two" 40
  if (-not $titles.initial) { throw "initial page did not load" }

  $titles.invalid_one = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "two words" "Invalid Address"
  if (-not $titles.invalid_one) { throw "invalid address page did not open" }

  [void](Invoke-SmokeClientClick $hwnd 24 40)
  Start-Sleep -Milliseconds 250
  $titles.after_back_click = Wait-TabTitle $browser.Id "Invalid Address" 6

  [void](Invoke-SmokeClientClick $hwnd 56 40)
  Start-Sleep -Milliseconds 250
  $titles.after_forward_click = Wait-TabTitle $browser.Id "Invalid Address" 6

  $titles.home = Invoke-BrowserPagesDocumentAction $hwnd 8 $browser.Id "Browser Pages One"
  if (-not $titles.home) { throw "error page home action did not open homepage" }

  $titles.invalid_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "two words" "Invalid Address"
  if (-not $titles.invalid_two) { throw "second invalid address page did not open" }

  $titles.start = Invoke-BrowserPagesDocumentAction $hwnd 9 $browser.Id "Browser Start"
  if (-not $titles.start) { throw "error page start action did not open browser start" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverMeta = Stop-OwnedProbeProcess $server
  Start-Sleep -Milliseconds 200
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    ready = $ready
    invalid_opened = [bool]$titles.invalid_one
    back_disabled_worked = [bool]$titles.after_back_click
    forward_disabled_worked = [bool]$titles.after_forward_click
    home_worked = [bool]$titles.home
    start_worked = [bool]$titles.start
    error = $failure
    titles = $titles
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_pid = if ($server) { $server.Id } else { 0 }
    server_meta = $serverMeta
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 6
}

if ($failure) { exit 1 }
if (-not $titles.invalid_one -or -not $titles.after_back_click -or -not $titles.after_forward_click -or -not $titles.home -or -not $titles.start) {
  exit 1
}
