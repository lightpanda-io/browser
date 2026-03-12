$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\localstorage-persistence\StorageProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-localstorage-clear"
$app = Reset-StorageProfile $profileRoot
Seed-StorageProfile $app.AppDataRoot
$port = 8202
$origin = "http://127.0.0.1:$port"
$entryPattern = ConvertTo-LocalStorageEntryPattern $origin "lppersist" "ok"
$browserOneOut = Join-Path $Root "chrome-localstorage-clear.run1.browser.stdout.txt"
$browserOneErr = Join-Path $Root "chrome-localstorage-clear.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $Root "chrome-localstorage-clear.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $Root "chrome-localstorage-clear.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-localstorage-clear.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-localstorage-clear.server.stderr.txt"
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
$storageData = ""

try {
  $server = Start-StorageServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-StorageServer -Port $port
  if (-not $ready) { throw "localstorage server did not become ready" }

  $browserOne = Start-StorageBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOneOut -Stderr $browserOneErr
  $hwndOne = Wait-TabWindowHandle $browserOne.Id
  if ($hwndOne -eq [IntPtr]::Zero) { throw "localstorage clear run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-TabTitle $browserOne.Id "Local Storage Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish localStorage write" }

  $storageData = Wait-LocalStorageFileMatch $app.LocalStorageFile $entryPattern
  if (-not $storageData) { throw "localStorage data did not persist before clear" }

  $titles.settings = Invoke-StorageAddressNavigate $hwndOne $browserOne.Id "browser://settings" "Browser Settings"
  $settingsOpened = [bool]$titles.settings
  if (-not $settingsOpened) { throw "browser://settings did not load" }

  $titles.settings_after_clear = Invoke-StorageAddressNavigate $hwndOne $browserOne.Id "browser://settings/clear-local-storage" "Browser Settings"
  $clearInvoked = [bool]$titles.settings_after_clear
  if (-not $clearInvoked) { throw "clear localStorage action did not return to settings page" }

  $storageData = Wait-LocalStorageFileNoMatch $app.LocalStorageFile $entryPattern
  $clearedOnDisk = [bool]$storageData
  if (-not $clearedOnDisk) { throw "localStorage persisted file still contains cleared entry" }

  $titles.echo_missing = Invoke-StorageAddressNavigate $hwndOne $browserOne.Id "$origin/echo.html" "Local Storage Echo missing"
  $missingAfterClear = [bool]$titles.echo_missing
  if (-not $missingAfterClear) { throw "localStorage remained visible after clear" }

  $browserOneMeta = Stop-OwnedProbeProcess $browserOne
  $browserOneGoneBeforeRestart = Wait-OwnedProbeProcessGone $browserOne.Id
  $browserOne = $null
  if (-not $browserOneGoneBeforeRestart) { throw "run1 browser pid did not exit before restart" }
  Start-Sleep -Milliseconds 300

  $browserTwo = Start-StorageBrowser -StartupUrl "$origin/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "localstorage clear run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart_missing = Wait-TabTitle $browserTwo.Id "Local Storage Echo missing" 40
  $missingAfterRestart = [bool]$titles.restart_missing
  if (-not $missingAfterRestart) { throw "localStorage remained present after restart" }
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
  if (-not $storageData) { $storageData = Read-LocalStorageFileData $app.LocalStorageFile }
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
    local_storage_file = $storageData
    error = $failure
    server_meta = Format-StorageProbeProcessMeta $serverMeta
    browser_one_meta = Format-StorageProbeProcessMeta $browserOneMetaValue
    browser_two_meta = Format-StorageProbeProcessMeta $browserTwoMeta
    browser_one_gone_before_restart = $browserOneGoneBeforeRestart
    browser_one_gone = $browserOneGone
    browser_two_gone = $browserTwoGone
    server_gone = $serverGone
  }
  Write-StorageProbeResult $result

  if ($failure -or -not $seedWorked -or -not $settingsOpened -or -not $clearInvoked -or -not $clearedOnDisk -or -not $missingAfterClear -or -not $missingAfterRestart) {
    exit 1
  }
}
