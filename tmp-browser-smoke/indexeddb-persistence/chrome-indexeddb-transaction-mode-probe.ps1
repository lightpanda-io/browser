$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-indexeddb-transaction-mode"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$browserOut = Join-Path $Root "chrome-indexeddb-transaction-mode.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-indexeddb-transaction-mode.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-indexeddb-transaction-mode.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-indexeddb-transaction-mode.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$modeWorked = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb transaction mode server did not become ready" }

  $browser = Start-IndexedDbBrowser -StartupUrl "$origin/transaction-mode.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "indexeddb transaction mode window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.mode = Wait-TabTitle $browser.Id "IndexedDB Transaction Mode ok" 40
  $modeWorked = [bool]$titles.mode
  if (-not $modeWorked) { throw "indexeddb transaction mode page did not resolve expected title" }
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
    mode_worked = $modeWorked
    titles = $titles
    error = $failure
    server_meta = Format-IndexedDbProbeProcessMeta $serverMeta
    browser_meta = Format-IndexedDbProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-IndexedDbProbeResult $result

  if ($failure -or -not $modeWorked) {
    exit 1
  }
}

exit 0
