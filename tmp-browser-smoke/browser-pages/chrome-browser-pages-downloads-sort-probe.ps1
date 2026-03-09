$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-downloads-sort"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8208
$browserOut = Join-Path $Root "chrome-browser-pages-downloads-sort.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-browser-pages-downloads-sort.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-downloads-sort.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-downloads-sort.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port
$downloadsFile = Join-Path $app.AppDataRoot "downloads-v1.txt"
$oldPath = Join-Path $app.DownloadsDir "older.txt"
$newPath = Join-Path $app.DownloadsDir "newer.txt"
'older' | Set-Content -Path $oldPath -NoNewline
'newer' | Set-Content -Path $newPath -NoNewline
@"
2	5	5	1	older.txt	$oldPath	http://127.0.0.1:$port/index.html	
2	5	5	1	newer.txt	$newPath	http://127.0.0.1:$port/download.txt	
"@ | Set-Content -Path $downloadsFile -NoNewline

function Find-DownloadSortTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  foreach ($count in @(7)) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://downloads/filter-clear" "Browser Downloads (2)" | Out-Null
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://downloads" "Browser Downloads (2)" | Out-Null
    Invoke-BrowserPagesDocumentActionNoNavigate $Hwnd $count 500
    $title = Get-SmokeWindowTitle $Hwnd
    if ($title -like "*Browser Downloads (2, newest first)*") {
      return [pscustomobject]@{ Worked = $true; Count = $count; Title = $title }
    }
  }
  return [pscustomobject]@{ Worked = $false; Count = -1; Title = (Get-SmokeWindowTitle $Hwnd) }
}

function Find-DownloadOpenTabCount([IntPtr]$Hwnd, [int]$BrowserId) {
  foreach ($count in @(14, 15)) {
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://downloads/filter-clear" "Browser Downloads (2)" | Out-Null
    Invoke-BrowserPagesAddressNavigate $Hwnd $BrowserId "browser://downloads/sort/newest-first" "Browser Downloads (2, newest first)" | Out-Null
    $result = Invoke-BrowserPagesDocumentAction $Hwnd $count $BrowserId "download.txt"
    if ($result) {
      return [pscustomobject]@{ Worked = $true; Count = $count; Title = $result }
    }
  }
  return [pscustomobject]@{ Worked = $false; Count = -1; Title = (Get-SmokeWindowTitle $Hwnd) }
}

$server = $null
$browser = $null
$ready = $false
$opened = $false
$sortWorked = $false
$openWorked = $false
$sortCount = -1
$openCount = -1
$downloadSourceRequests = 0
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "downloads sort server did not become ready" }

  $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "downloads sort window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "downloads sort initial page did not load" }

  $titles.downloads = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://downloads" "Browser Downloads (2)"
  $opened = [bool]$titles.downloads
  if (-not $opened) { throw "browser://downloads did not load" }

  $sortAttempt = Find-DownloadSortTabCount $hwnd $browser.Id
  $sortWorked = [bool]$sortAttempt.Worked
  $sortCount = [int]$sortAttempt.Count
  $titles.sorted = $sortAttempt.Title
  if (-not $sortWorked) { throw "download sort document action did not reach newest first" }

  $openAttempt = Find-DownloadOpenTabCount $hwnd $browser.Id
  Start-Sleep -Milliseconds 400
  $downloadSourceRequests = @((Get-Content $serverErr -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /download\.txt' }).Count
  $openWorked = [bool]$openAttempt.Worked -or ($downloadSourceRequests -ge 1)
  $openCount = [int]$openAttempt.Count
  $titles.opened = $openAttempt.Title
  if (-not $openWorked) { throw "download sorted first-row source action did not reach download.txt" }
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
    sort_worked = $sortWorked
    open_worked = $openWorked
    sort_count = $sortCount
    open_count = $openCount
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
