$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\localstorage-persistence\StorageProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-localstorage-storage-event"
$app = Reset-StorageProfile $profileRoot
Seed-StorageProfile $app.AppDataRoot
$port = 8321
$origin = "http://127.0.0.1:$port"
$browserOut = Join-Path $Root "chrome-localstorage-storage-event.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-localstorage-storage-event.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-localstorage-storage-event.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-localstorage-storage-event.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$listenerReady = $false
$writerWorked = $false
$listenerReceived = $false
$listenerRetained = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-StorageServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-StorageServer -Port $port
  if (-not $ready) { throw "localstorage server did not become ready" }

  $browser = Start-StorageBrowser -StartupUrl "$origin/listener.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "localstorage event window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.listener_ready = Wait-TabTitle $browser.Id "Local Storage Listener Ready" 40
  $listenerReady = [bool]$titles.listener_ready
  if (-not $listenerReady) { throw "listener page did not become ready" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.writer = Invoke-StorageAddressNavigate $hwnd $browser.Id "$origin/writer.html" "Local Storage Writer Wrote"
  $writerWorked = [bool]$titles.writer
  if (-not $writerWorked) { throw "writer page did not write localStorage" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_listener = Wait-TabTitle $browser.Id "Local Storage Event ok" 40
  $listenerReceived = [bool]$titles.back_to_listener
  if (-not $listenerReceived) { throw "listener tab did not receive storage event" }

  Send-SmokeCtrlTab
  $titles.return_to_writer = Wait-TabTitle $browser.Id "Local Storage Writer Wrote" 20
  $listenerRetained = [bool]$titles.return_to_writer
  if (-not $listenerRetained) { throw "writer tab was not preserved after storage event delivery" }
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
    listener_ready = $listenerReady
    writer_worked = $writerWorked
    listener_received = $listenerReceived
    writer_tab_retained = $listenerRetained
    titles = $titles
    error = $failure
    server_meta = Format-StorageProbeProcessMeta $serverMeta
    browser_meta = Format-StorageProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-StorageProbeResult $result

  if ($failure -or -not $listenerReady -or -not $writerWorked -or -not $listenerReceived -or -not $listenerRetained) {
    exit 1
  }
}
