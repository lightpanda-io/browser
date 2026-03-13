$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\sessionstorage-scope\SessionStorageProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-sessionstorage-restart"
$app = Reset-SessionStorageProfile $profileRoot
Seed-SessionStorageProfile $app.AppDataRoot
$port = 8422
$origin = "http://127.0.0.1:$port"
$browserOneOut = Join-Path $Root "chrome-sessionstorage-restart.run1.browser.stdout.txt"
$browserOneErr = Join-Path $Root "chrome-sessionstorage-restart.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $Root "chrome-sessionstorage-restart.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $Root "chrome-sessionstorage-restart.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-sessionstorage-restart.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-sessionstorage-restart.server.stderr.txt"
Remove-Item $browserOneOut,$browserOneErr,$browserTwoOut,$browserTwoErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browserOne = $null
$browserTwo = $null
$ready = $false
$seedWorked = $false
$restartMissing = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-SessionStorageServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-SessionStorageServer -Port $port
  if (-not $ready) { throw "sessionStorage server did not become ready" }

  $browserOne = Start-SessionStorageBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOneOut -Stderr $browserOneErr
  $hwndOne = Wait-TabWindowHandle $browserOne.Id
  if ($hwndOne -eq [IntPtr]::Zero) { throw "sessionStorage restart run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-SessionStorageWindowTitle $hwndOne "Session Storage Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish sessionStorage write" }

  $null = Stop-OwnedProbeProcess $browserOne
  $browserOne = $null
  Start-Sleep -Milliseconds 500

  $browserTwo = Start-SessionStorageBrowser -StartupUrl "$origin/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "sessionStorage restart run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart = Wait-SessionStorageWindowTitle $hwndTwo "Session Storage Echo missing" 40
  $restartMissing = [bool]$titles.restart
  if (-not $restartMissing) { throw "sessionStorage unexpectedly persisted across browser restart" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserOneMeta = if ($browserOne) { Stop-OwnedProbeProcess $browserOne } else { $null }
  $browserTwoMeta = if ($browserTwo) { Stop-OwnedProbeProcess $browserTwo } else { $null }
  Start-Sleep -Milliseconds 200
  $browserOneGone = if ($browserOne) { -not (Get-Process -Id $browserOne.Id -ErrorAction SilentlyContinue) } else { $true }
  $browserTwoGone = if ($browserTwo) { -not (Get-Process -Id $browserTwo.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  $result = [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_one_pid = if ($browserOne) { $browserOne.Id } else { 0 }
    browser_two_pid = if ($browserTwo) { $browserTwo.Id } else { 0 }
    ready = $ready
    seed_worked = $seedWorked
    restart_missing = $restartMissing
    titles = $titles
    error = $failure
    server_meta = Format-SessionStorageProbeProcessMeta $serverMeta
    browser_one_meta = Format-SessionStorageProbeProcessMeta $browserOneMeta
    browser_two_meta = Format-SessionStorageProbeProcessMeta $browserTwoMeta
    browser_one_gone = $browserOneGone
    browser_two_gone = $browserTwoGone
    server_gone = $serverGone
  }
  Write-SessionStorageProbeResult $result
  if ($failure -or -not $seedWorked -or -not $restartMissing) { exit 1 }
}
