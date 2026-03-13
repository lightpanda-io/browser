$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\sessionstorage-scope\SessionStorageProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-sessionstorage-cross-tab"
$app = Reset-SessionStorageProfile $profileRoot
Seed-SessionStorageProfile $app.AppDataRoot
$port = 8421
$origin = "http://127.0.0.1:$port"
$browserOut = Join-Path $Root "chrome-sessionstorage-cross-tab.browser.stdout.txt"
$browserErr = Join-Path $Root "chrome-sessionstorage-cross-tab.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-sessionstorage-cross-tab.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-sessionstorage-cross-tab.server.stderr.txt"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browser = $null
$ready = $false
$seedWorked = $false
$echoMissing = $false
$seedTabRetained = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-SessionStorageServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-SessionStorageServer -Port $port
  if (-not $ready) { throw "sessionStorage server did not become ready" }

  $browser = Start-SessionStorageBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOut -Stderr $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "sessionStorage cross-tab window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.seed = Wait-SessionStorageWindowTitle $hwnd "Session Storage Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish sessionStorage write" }

  Send-SmokeCtrlT
  Start-Sleep -Milliseconds 350
  $titles.echo = Invoke-SessionStorageAddressNavigate $hwnd $browser.Id "$origin/echo.html" "Session Storage Echo missing"
  $echoMissing = [bool]$titles.echo
  if (-not $echoMissing) { throw "new tab unexpectedly saw sessionStorage from the first tab" }

  Send-SmokeCtrlShiftTab
  $titles.back_to_seed = Wait-SessionStorageWindowTitle $hwnd "Session Storage Seeded" 30
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
    echo_missing = $echoMissing
    seed_tab_retained = $seedTabRetained
    titles = $titles
    error = $failure
    server_meta = Format-SessionStorageProbeProcessMeta $serverMeta
    browser_meta = Format-SessionStorageProbeProcessMeta $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  }
  Write-SessionStorageProbeResult $result
  if ($failure -or -not $seedWorked -or -not $echoMissing -or -not $seedTabRetained) { exit 1 }
}
