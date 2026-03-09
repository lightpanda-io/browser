$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-downloads-filter"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8193
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-filter.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-filter.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-filter.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-filter.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port

$downloadsFile = Join-Path $app.AppDataRoot "downloads-v1.txt"
$okPath = Join-Path $app.DownloadsDir "seed.txt"
$failPath = Join-Path $app.DownloadsDir "error.txt"
'seed file' | Set-Content -Path $okPath -NoNewline
'error file' | Set-Content -Path $failPath -NoNewline
@"
2	12	12	1	seed.txt	$okPath	http://127.0.0.1:$port/download.txt	
3	0	0	0	error.txt	$failPath	http://localhost:$port/error.txt	Failed: CouldntConnect
"@ | Set-Content -Path $downloadsFile -NoNewline

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
  if (-not $ready) { throw "downloads filter server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads filter window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (2)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not open" }

  $titles.filtered = Invoke-BrowserPagesDocumentAction $hwnd 10 $browser.Id "Browser Downloads (1/2)"
  $quickFilterWorked = [bool]$titles.filtered
  if (-not $quickFilterWorked) { throw "downloads failed quick filter did not apply" }

  $titles.cleared = Invoke-BrowserPagesDocumentAction $hwnd 6 $browser.Id "Browser Downloads (2)"
  $clearWorked = [bool]$titles.cleared
  if (-not $clearWorked) { throw "downloads filter clear did not restore full view" }
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
