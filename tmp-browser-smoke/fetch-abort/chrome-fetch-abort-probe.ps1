$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\fetch-abort\FetchAbortProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-fetch-abort"
$app = Reset-FetchAbortProfile $profileRoot
Seed-FetchAbortProfile $app.AppDataRoot
$port = 8463
$pageUrl = "http://127.0.0.1:$port/page.html"
$browserOut = Join-Path $Root "chrome-fetch-abort.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-fetch-abort.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-fetch-abort.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-fetch-abort.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$titleReady = $false
$sawSlowStart = $false
$sawSlowAbort = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-FetchAbortServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-FetchAbortServer -Port $port
  if (-not $ready) { throw "fetch abort server did not become ready" }

  $browser = Start-FetchAbortBrowser -StartupUrl $pageUrl -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "fetch abort window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.final = Wait-TabTitle $browser.Id "Fetch Abort Ready" 60
  $titleReady = [bool]$titles.final
  if (-not $titleReady) {
    $titles.fail = Wait-TabTitle $browser.Id "Fetch Abort" 5
    throw "fetch abort page did not reach the ready title"
  }

  $startLog = Wait-FetchAbortServerLogMatch -Path $serverErr -Pattern "SLOW_START" -Attempts 20
  $abortLog = Wait-FetchAbortServerLogMatch -Path $serverErr -Pattern "SLOW_ABORTED" -Attempts 30
  $sawSlowStart = $null -ne $startLog
  $sawSlowAbort = $null -ne $abortLog
  if (-not $sawSlowStart) { throw "server did not observe slow request start" }
  if (-not $sawSlowAbort) { throw "server did not observe slow request abort" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  $result = [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    title_ready = $titleReady
    saw_slow_start = $sawSlowStart
    saw_slow_abort = $sawSlowAbort
    titles = $titles
    error = $failure
    server_meta = Format-FetchAbortProcessMeta $serverMeta
    browser_meta = Format-FetchAbortProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-FetchAbortResult $result
  if ($failure -or -not $titleReady -or -not $sawSlowStart -or -not $sawSlowAbort) { exit 1 }
}
