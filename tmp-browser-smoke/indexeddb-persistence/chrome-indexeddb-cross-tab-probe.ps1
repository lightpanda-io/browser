$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-indexeddb-cross-tab"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$entryPattern = ConvertTo-IndexedDbEntryPattern $origin "lp-persist" "items" "persist" '{"status":"ok"}'
$browserOut = Join-Path $Root "chrome-indexeddb-cross-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-indexeddb-cross-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-indexeddb-cross-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-indexeddb-cross-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$seedWorked = $false
$persistedToDisk = $false
$echoWorked = $false
$seedTabRetained = $false
$failure = $null
$titles = [ordered]@{}
$indexedDbData = ""

try {
  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb server did not become ready" }

  $browser = Start-IndexedDbBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "indexeddb cross-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-TabTitle $browser.Id "IndexedDB Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish indexeddb write" }

  $indexedDbData = Wait-IndexedDbFileMatch $app.IndexedDbFile $entryPattern
  $persistedToDisk = [bool]$indexedDbData
  if (-not $persistedToDisk) { throw "indexeddb data did not persist to disk before cross-tab check" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-IndexedDbAddressNavigate $hwnd $browser.Id "$origin/echo.html" "IndexedDB Echo ok"
  $echoWorked = [bool]$titles.echo
  if (-not $echoWorked) { throw "new tab did not see shared indexeddb data" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-TabTitle $browser.Id "IndexedDB Seeded" 30
  $seedTabRetained = [bool]$titles.back_to_seed
  if (-not $seedTabRetained) { throw "seed tab was not preserved after cross-tab check" }
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
    persisted_to_disk = $persistedToDisk
    echo_worked = $echoWorked
    seed_tab_retained = $seedTabRetained
    indexed_db_file = if ($indexedDbData) { $indexedDbData } else { Read-IndexedDbFileData $app.IndexedDbFile }
    titles = $titles
    error = $failure
    server_meta = Format-IndexedDbProbeProcessMeta $serverMeta
    browser_meta = Format-IndexedDbProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-IndexedDbProbeResult $result

  if ($failure -or -not $seedWorked -or -not $persistedToDisk -or -not $echoWorked -or -not $seedTabRetained) {
    exit 1
  }
}
