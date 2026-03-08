$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-download-clear"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8193
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-clear.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-clear.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-clear.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-clear.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -SeedDownload
$seedDownloadPath = Join-Path $app.DownloadsDir "seed.txt"
$downloadsFile = Join-Path $app.AppDataRoot "downloads-v1.txt"

$server = $null
$browser = $null
$ready = $false
$opened = $false
$clearWorked = $false
$downloadDeleted = $false
$metadataCleared = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "downloads clear server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads clear window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (1)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not open" }

  $titles.cleared = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads/clear" "Browser Downloads (0)"
  $downloadDeleted = -not (Test-Path $seedDownloadPath)
  $downloadsRaw = if (Test-Path $downloadsFile) { Get-Content $downloadsFile -Raw } else { $null }
  $metadataCleared = [string]::IsNullOrWhiteSpace([string]$downloadsRaw)
  $clearWorked = [bool]$titles.cleared -and $downloadDeleted -and $metadataCleared
  if (-not $clearWorked) { throw "downloads clear action did not clear the page and persisted state" }
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
    clear_worked = $clearWorked
    download_deleted = $downloadDeleted
    metadata_cleared = $metadataCleared
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
