$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-indexeddb-cursor"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$browserOut = Join-Path $Root "chrome-indexeddb-cursor.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-indexeddb-cursor.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-indexeddb-cursor.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-indexeddb-cursor.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$seedWorked = $false
$echoWorked = $false
$seedTabRetained = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb cursor server did not become ready" }

  $browser = Start-IndexedDbBrowser -StartupUrl "$origin/cursor-seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "indexeddb cursor window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-TabTitle $browser.Id "IndexedDB Cursor Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "cursor seed page did not finish indexeddb writes" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-IndexedDbAddressNavigate $hwnd $browser.Id "$origin/cursor-echo.html" "IndexedDB Cursor Echo ok"
  $echoWorked = [bool]$titles.echo
  if (-not $echoWorked) { throw "new tab did not resolve indexeddb cursor iteration" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-TabTitle $browser.Id "IndexedDB Cursor Seeded" 30
  $seedTabRetained = [bool]$titles.back_to_seed
  if (-not $seedTabRetained) { throw "cursor seed tab was not preserved after cursor echo check" }
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
    seed_worked = $seedWorked
    echo_worked = $echoWorked
    seed_tab_retained = $seedTabRetained
    titles = $titles
    error = $failure
    server_meta = Format-IndexedDbProbeProcessMeta $serverMeta
    browser_meta = Format-IndexedDbProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-IndexedDbProbeResult $result

  if ($failure -or -not $seedWorked -or -not $echoWorked -or -not $seedTabRetained) {
    exit 1
  }
}
