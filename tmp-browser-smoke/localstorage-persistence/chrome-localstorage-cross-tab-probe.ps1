$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\localstorage-persistence\StorageProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-localstorage-cross-tab"
$app = Reset-StorageProfile $profileRoot
Seed-StorageProfile $app.AppDataRoot
$port = 8200
$origin = "http://127.0.0.1:$port"
$entryPattern = ConvertTo-LocalStorageEntryPattern $origin "lppersist" "ok"
$browserOut = Join-Path $Root "chrome-localstorage-cross-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-localstorage-cross-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-localstorage-cross-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-localstorage-cross-tab.server.stderr.txt"
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
$storageData = ""

try {
  $server = Start-StorageServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-StorageServer -Port $port
  if (-not $ready) { throw "localstorage server did not become ready" }

  $browser = Start-StorageBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "localstorage cross-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-TabTitle $browser.Id "Local Storage Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish localStorage write" }

  $storageData = Wait-LocalStorageFileMatch $app.LocalStorageFile $entryPattern
  $persistedToDisk = [bool]$storageData
  if (-not $persistedToDisk) { throw "localStorage data did not persist to disk before cross-tab check" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-StorageAddressNavigate $hwnd $browser.Id "$origin/echo.html" "Local Storage Echo ok"
  $echoWorked = [bool]$titles.echo
  if (-not $echoWorked) { throw "new tab did not see shared localStorage" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-TabTitle $browser.Id "Local Storage Seeded" 30
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
    local_storage_file = if ($storageData) { $storageData } else { Read-LocalStorageFileData $app.LocalStorageFile }
    titles = $titles
    error = $failure
    server_meta = Format-StorageProbeProcessMeta $serverMeta
    browser_meta = Format-StorageProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-StorageProbeResult $result

  if ($failure -or -not $seedWorked -or -not $persistedToDisk -or -not $echoWorked -or -not $seedTabRetained) {
    exit 1
  }
}
