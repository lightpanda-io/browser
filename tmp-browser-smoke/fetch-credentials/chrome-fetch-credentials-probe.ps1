$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\fetch-credentials\FetchCredentialsProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-fetch-credentials"
$app = Reset-FetchProfile $profileRoot
Seed-FetchProfile $app.AppDataRoot
$pagePort = 8423
$crossPort = 8424
$pageUrl = "http://fetch%20user:p%40ss@127.0.0.1:$pagePort/page.html"
$browserOut = Join-Path $Root "chrome-fetch-credentials.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-fetch-credentials.browser.stderr.txt"
$pageServerOut = Join-Path $Root "chrome-fetch-credentials.page.server.stdout.txt"
$pageServerErr = Join-Path $Root "chrome-fetch-credentials.page.server.stderr.txt"
$crossServerOut = Join-Path $Root "chrome-fetch-credentials.cross.server.stdout.txt"
$crossServerErr = Join-Path $Root "chrome-fetch-credentials.cross.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$pageServerOut,$pageServerErr,$crossServerOut,$crossServerErr -Force -ErrorAction SilentlyContinue

$pageServer = $null
$crossServer = $null
$browser = $null
$ready = $false
$titleReady = $false
$failure = $null
$titles = [ordered]@{}

try {
  $pageServer = Start-FetchServer -Port $pagePort -PeerPort $crossPort -Stdout $pageServerOut -Stderr $pageServerErr
  $crossServer = Start-FetchServer -Port $crossPort -PeerPort $pagePort -Stdout $crossServerOut -Stderr $crossServerErr
  $ready = (Wait-FetchServer -Port $pagePort) -and (Wait-FetchServer -Port $crossPort)
  if (-not $ready) { throw "fetch credential servers did not become ready" }

  $browser = Start-FetchBrowser -StartupUrl $pageUrl -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "fetch credentials window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.final = Wait-TabTitle $browser.Id "Fetch Credentials Ready" 50
  $titleReady = [bool]$titles.final
  if (-not $titleReady) {
    $titles.fail = Wait-TabTitle $browser.Id "Fetch Credentials" 5
    throw "fetch credentials page did not reach the ready title"
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $pageServerMeta = Stop-OwnedProbeProcess $pageServer
  $crossServerMeta = Stop-OwnedProbeProcess $crossServer
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $pageServerGone = if ($pageServer) { -not (Get-Process -Id $pageServer.Id -ErrorAction SilentlyContinue) } else { $true }
  $crossServerGone = if ($crossServer) { -not (Get-Process -Id $crossServer.Id -ErrorAction SilentlyContinue) } else { $true }
  $result = [ordered]@{
    page_server_pid = if ($pageServer) { $pageServer.Id } else { 0 }
    cross_server_pid = if ($crossServer) { $crossServer.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    title_ready = $titleReady
    titles = $titles
    error = $failure
    page_server_meta = Format-FetchProbeProcessMeta $pageServerMeta
    cross_server_meta = Format-FetchProbeProcessMeta $crossServerMeta
    browser_meta = Format-FetchProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    page_server_gone = $pageServerGone
    cross_server_gone = $crossServerGone
  }
  Write-FetchProbeResult $result
  if ($failure -or -not $titleReady) { exit 1 }
}
