$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-download-open-folder"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8203
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-open-folder.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-open-folder.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-open-folder.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-open-folder.server.stderr.txt"
$shellLog = Join-Path $Root "chrome-browser-pages-downloads-open-folder.shell.log"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$shellLog -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port
$downloadsDir = (Resolve-Path $app.DownloadsDir).Path

$server = $null
$browser = $null
$ready = $false
$opened = $false
$actionWorked = $false
$pageStayed = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "downloads open-folder server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr -DownloadShellLog $shellLog
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads open-folder window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (0)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not open" }

  Invoke-BrowserPagesAddressCommit $hwnd "browser://downloads/open-folder"
  Start-Sleep -Milliseconds 450
  $titles.after = Wait-TabTitle $browser.Id "Browser Downloads (0)" 8
  $pageStayed = [bool]$titles.after

  $logLines = Read-BrowserPagesShellLog $shellLog
  $actionWorked = $logLines.Count -ge 1 -and $logLines[-1] -eq "open-folder`t$downloadsDir"
  if (-not $actionWorked) { throw "open-folder shell action did not log the expected path" }
  if (-not $pageStayed) { throw "downloads page did not remain open after open-folder action" }
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
    action_worked = $actionWorked
    page_stayed = $pageStayed
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
