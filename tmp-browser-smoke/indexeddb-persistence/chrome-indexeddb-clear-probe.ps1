$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-indexeddb-clear"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$entryPattern = ConvertTo-IndexedDbEntryPattern $origin "lp-persist" "items" "persist" '{"status":"ok"}'
$browserOneOut = Join-Path $Root "chrome-indexeddb-clear.run1.browser.stdout.txt"
$browserOneErr = Join-Path $Root "chrome-indexeddb-clear.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $Root "chrome-indexeddb-clear.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $Root "chrome-indexeddb-clear.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-indexeddb-clear.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-indexeddb-clear.server.stderr.txt"
Remove-Item $browserOneOut,$browserOneErr,$browserTwoOut,$browserTwoErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browserOne = $null
$browserTwo = $null
$ready = $false
$seedWorked = $false
$settingsOpened = $false
$clearInvoked = $false
$clearedOnDisk = $false
$missingAfterClear = $false
$missingAfterRestart = $false
$browserOneGoneBeforeRestart = $false
$failure = $null
$titles = [ordered]@{}
$indexedDbData = ""

try {
  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb server did not become ready" }

  $browserOne = Start-IndexedDbBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOneOut -Stderr $browserOneErr
  $hwndOne = Wait-TabWindowHandle $browserOne.Id
  if ($hwndOne -eq [IntPtr]::Zero) { throw "indexeddb clear run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-TabTitle $browserOne.Id "IndexedDB Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish indexeddb write" }

  $indexedDbData = Wait-IndexedDbFileMatch $app.IndexedDbFile $entryPattern
  if (-not $indexedDbData) { throw "indexeddb data did not persist before clear" }

  $titles.settings = Invoke-IndexedDbAddressNavigate $hwndOne $browserOne.Id "browser://settings" "Browser Settings"
  $settingsOpened = [bool]$titles.settings
  if (-not $settingsOpened) { throw "browser://settings did not load" }

  $titles.settings_after_clear = Invoke-IndexedDbAddressNavigate $hwndOne $browserOne.Id "browser://settings/clear-indexed-db" "Browser Settings"
  $clearInvoked = [bool]$titles.settings_after_clear
  if (-not $clearInvoked) { throw "clear indexeddb action did not return to settings page" }

  $indexedDbData = Wait-IndexedDbFileNoMatch $app.IndexedDbFile $entryPattern
  $clearedOnDisk = [bool]$indexedDbData
  if (-not $clearedOnDisk) { throw "indexeddb persisted file still contains cleared entry" }

  $titles.echo_missing = Invoke-IndexedDbAddressNavigate $hwndOne $browserOne.Id "$origin/echo.html" "IndexedDB Echo missing"
  $missingAfterClear = [bool]$titles.echo_missing
  if (-not $missingAfterClear) { throw "indexeddb remained visible after clear" }

  $browserOneMeta = Stop-OwnedProbeProcess $browserOne
  $browserOneGoneBeforeRestart = Wait-OwnedIndexedDbProbeProcessGone $browserOne.Id
  $browserOne = $null
  if (-not $browserOneGoneBeforeRestart) { throw "run1 browser pid did not exit before restart" }
  Start-Sleep -Milliseconds 300

  $browserTwo = Start-IndexedDbBrowser -StartupUrl "$origin/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "indexeddb clear run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart_missing = Wait-TabTitle $browserTwo.Id "IndexedDB Echo missing" 40
  $missingAfterRestart = [bool]$titles.restart_missing
  if (-not $missingAfterRestart) { throw "indexeddb remained present after restart" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserOneMetaFinal = if ($browserOne) { Stop-OwnedProbeProcess $browserOne } else { $null }
  $browserTwoMeta = Stop-OwnedProbeProcess $browserTwo
  Start-Sleep -Milliseconds 200
  $browserOneGone = if ($browserOne) { -not (Get-Process -Id $browserOne.Id -ErrorAction SilentlyContinue) } else { $true }
  $browserTwoGone = if ($browserTwo) { -not (Get-Process -Id $browserTwo.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  if (-not $indexedDbData) { $indexedDbData = Read-IndexedDbFileData $app.IndexedDbFile }
  $browserOneMetaValue = if ($browserOneMeta) { $browserOneMeta } else { $browserOneMetaFinal }

  $result = [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_one_pid = if ($browserOne) { $browserOne.Id } else { 0 }
    browser_two_pid = if ($browserTwo) { $browserTwo.Id } else { 0 }
    ready = $ready
    seed_worked = $seedWorked
    settings_opened = $settingsOpened
    clear_invoked = $clearInvoked
    cleared_on_disk = $clearedOnDisk
    missing_after_clear = $missingAfterClear
    missing_after_restart = $missingAfterRestart
    titles = $titles
    indexed_db_file = $indexedDbData
    error = $failure
    server_meta = Format-IndexedDbProbeProcessMeta $serverMeta
    browser_one_meta = Format-IndexedDbProbeProcessMeta $browserOneMetaValue
    browser_two_meta = Format-IndexedDbProbeProcessMeta $browserTwoMeta
    browser_one_gone_before_restart = $browserOneGoneBeforeRestart
    browser_one_gone = $browserOneGone
    browser_two_gone = $browserTwoGone
    server_gone = $serverGone
  }
  Write-IndexedDbProbeResult $result

  if ($failure -or -not $seedWorked -or -not $settingsOpened -or -not $clearInvoked -or -not $clearedOnDisk -or -not $missingAfterClear -or -not $missingAfterRestart) {
    exit 1
  }
}
