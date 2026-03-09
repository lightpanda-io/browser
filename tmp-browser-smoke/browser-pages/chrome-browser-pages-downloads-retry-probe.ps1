$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-downloads-retry"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8222
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-retry.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-retry.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-retry.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-retry.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port
$downloadsFile = Join-Path $app.AppDataRoot "downloads-v1.txt"
$retryPath = Join-Path $app.DownloadsDir "retry.txt"
@"
3	0	0	0	retry.txt	$retryPath	http://127.0.0.1:$port/download.txt	Failed: CouldntConnect
"@ | Set-Content -Path $downloadsFile -NoNewline

$server = $null
$browser = $null
$ready = $false
$opened = $false
$retryWorked = $false
$failedCleared = $false
$downloadSourceRequests = 0
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "downloads retry server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads retry window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "downloads retry initial page did not load" }

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not load" }

  Invoke-BrowserPagesDocumentActionNoNavigate $hwnd 16 900
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 200
    $downloadSourceRequests = @((Get-Content $serverErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /download\.txt' }).Count
    if ($downloadSourceRequests -ge 1 -and (Test-Path $retryPath) -and ((Get-Item $retryPath).Length -gt 0)) {
      $retryWorked = $true
      break
    }
  }
  $titles.after_retry = Get-SmokeWindowTitle $hwnd
  if (-not $retryWorked) { throw "download retry document action did not create a new completed file" }

  $titles.failed_filter = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads/filter/failed" "Browser Downloads (0/1)"
  $failedCleared = [bool]$titles.failed_filter
  if (-not $failedCleared) { throw "download retry did not clear the failed-only filtered view" }
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
    retry_worked = $retryWorked
    failed_cleared = $failedCleared
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
