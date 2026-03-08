$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-downloads-open-new-tab"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8205
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-open-new-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-open-new-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-open-new-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-open-new-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -SeedDownload

$server = $null
$browser = $null
$ready = $false
$downloadsOpened = $false
$openNewTabWorked = $false
$returnedWorked = $false
$downloadSourceRequests = 0
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "downloads open-new-tab server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads open-new-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "downloads open-new-tab initial page did not load" }

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  $downloadsOpened = [bool]$titles.downloads
  if (-not $downloadsOpened) { throw "browser://downloads did not load" }

  $titles.opened = Invoke-BrowserPagesDocumentAction $hwnd 13 $browser.Id "download.txt"
  Start-Sleep -Milliseconds 600
  $downloadSourceRequests = @((Get-Content $serverErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /download\.txt' }).Count
  $openNewTabWorked = [bool]$titles.opened -or ($downloadSourceRequests -ge 1)
  if (-not $openNewTabWorked) { throw "download source-in-new-tab document action did not open download.txt" }

  Send-SmokeCtrlShiftTab
  $titles.returned = Wait-TabTitle $browser.Id "Browser Downloads (1)" 40
  $returnedWorked = [bool]$titles.returned
  if (-not $returnedWorked) { throw "download source-in-new-tab did not preserve the original downloads tab" }
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
    downloads_opened = $downloadsOpened
    open_new_tab_worked = $openNewTabWorked
    returned_worked = $returnedWorked
    download_source_requests = $downloadSourceRequests
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }