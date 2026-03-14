$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-indexeddb-index"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$indexPattern = ConvertTo-IndexedDbIndexPattern $origin "lp-index-persist" "users" "by_email" "email"
$entryPattern = ConvertTo-IndexedDbEntryPattern $origin "lp-index-persist" "users" "user-1" '{"status":"ok","email":"ada@example.com"}'
$browserOut = Join-Path $Root "chrome-indexeddb-index.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-indexeddb-index.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-indexeddb-index.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-indexeddb-index.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$seedWorked = $false
$indexPersisted = $false
$entryPersisted = $false
$echoWorked = $false
$seedTabRetained = $false
$failure = $null
$titles = [ordered]@{}
$indexedDbData = ""

try {
  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb index server did not become ready" }

  $browser = Start-IndexedDbBrowser -StartupUrl "$origin/index-seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "indexeddb index window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-TabTitle $browser.Id "IndexedDB Index Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "index seed page did not finish indexeddb write" }

  $indexedDbData = Wait-IndexedDbFileMatch $app.IndexedDbFile $indexPattern
  $indexPersisted = [bool]$indexedDbData
  if (-not $indexPersisted) { throw "indexeddb index metadata did not persist to disk" }

  $indexedDbData = Wait-IndexedDbFileMatch $app.IndexedDbFile $entryPattern
  $entryPersisted = [bool]$indexedDbData
  if (-not $entryPersisted) { throw "indexeddb indexed entry did not persist to disk" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-IndexedDbAddressNavigate $hwnd $browser.Id "$origin/index-echo.html" "IndexedDB Index Echo ok"
  $echoWorked = [bool]$titles.echo
  if (-not $echoWorked) { throw "new tab did not resolve indexeddb lookup through persisted index" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-TabTitle $browser.Id "IndexedDB Index Seeded" 30
  $seedTabRetained = [bool]$titles.back_to_seed
  if (-not $seedTabRetained) { throw "index seed tab was not preserved after index echo check" }
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
    index_persisted = $indexPersisted
    entry_persisted = $entryPersisted
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

  if ($failure -or -not $seedWorked -or -not $indexPersisted -or -not $entryPersisted -or -not $echoWorked -or -not $seedTabRetained) {
    exit 1
  }
}
