$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-download-actions"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8186
$browserOut = Join-Path $Root "chrome-browser-pages-downloads.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -SeedDownload
$seedDownloadPath = Join-Path $app.DownloadsDir "seed.txt"
$downloadsFile = Join-Path $app.AppDataRoot "downloads-v1.txt"

$server = $null
$browser = $null
$ready = $false
$opened = $false
$sourceWorked = $false
$removeWorked = $false
$downloadDeleted = $false
$metadataCleared = $false
$downloadSourceRequests = 0
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "download actions server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "download actions window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not load" }

  $titles.source = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads/source/0" "download.txt"
  Start-Sleep -Milliseconds 700
  $downloadSourceRequests = @((Get-Content $serverErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /download\.txt' }).Count
  $browserNavigatedToSource = @((Get-Content $browserErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'url = http://127\.0\.0\.1:8186/download\.txt' }).Count -ge 1
  $sourceWorked = [bool]$titles.source -or ($downloadSourceRequests -ge 1) -or $browserNavigatedToSource
  if (-not $sourceWorked) { throw "download source action failed" }

  $titles.downloads_reopened = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  if (-not $titles.downloads_reopened) { throw "browser://downloads did not reopen after source action" }

  $null = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads/remove/0" "Browser Downloads"
  Start-Sleep -Milliseconds 400

  $downloadDeleted = -not (Test-Path $seedDownloadPath)
  $downloadsRaw = if (Test-Path $downloadsFile) { Get-Content $downloadsFile -Raw } else { $null }
  $metadataCleared = [string]::IsNullOrWhiteSpace([string]$downloadsRaw)
  $titles.downloads_after_remove = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (0)"
  $removeWorked = $downloadDeleted -and $metadataCleared
  if (-not $downloadDeleted) { throw "download file was not deleted" }
  if (-not $metadataCleared) { throw "downloads metadata was not cleared" }
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
    source_worked = $sourceWorked
    remove_worked = $removeWorked
    download_deleted = $downloadDeleted
    metadata_cleared = $metadataCleared
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
