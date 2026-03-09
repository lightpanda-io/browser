$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-history-filter"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8191
$browserOut = Join-Path $Root "chrome-browser-pages-history-filter.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-history-filter.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-history-filter.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-history-filter.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$server = $null
$browser = $null
$ready = $false
$opened = $false
$quickFilterWorked = $false
$clearWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "history filter server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://localhost:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "history filter window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "initial page did not load" }

  $titles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
  if (-not $titles.page_two) { throw "page two did not load" }

  $titles.history = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://history" "Browser History (2)"
  $opened = [bool]$titles.history
  if (-not $opened) { throw "browser://history did not open" }

  $titles.filtered = Invoke-BrowserPagesDocumentAction $hwnd 8 $browser.Id "Browser History (1/2)"
  $quickFilterWorked = [bool]$titles.filtered
  if (-not $quickFilterWorked) { throw "history quick filter did not apply" }

  $titles.cleared = Invoke-BrowserPagesDocumentAction $hwnd 6 $browser.Id "Browser History (2)"
  $clearWorked = [bool]$titles.cleared
  if (-not $clearWorked) { throw "history filter clear did not restore full view" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    opened = $opened
    quick_filter_worked = $quickFilterWorked
    clear_worked = $clearWorked
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
