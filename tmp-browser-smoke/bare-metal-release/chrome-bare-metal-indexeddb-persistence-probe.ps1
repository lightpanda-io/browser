$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$manifestPath = Join-Path $packageRoot "manifest.json"
$bootBinary = Join-Path $packageRoot "boot\lightpanda.exe"
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"

$env:LIGHTPANDA_BROWSER_EXE = $bootBinary
. "$repo\tmp-browser-smoke\indexeddb-persistence\IndexedDbProbeCommon.ps1"
$script:BrowserExe = $bootBinary

$profileRoot = Join-Path $root "profile-indexeddb-restart"
$app = Reset-IndexedDbProfile $profileRoot
Seed-IndexedDbProfile $app.AppDataRoot
$port = Get-FreeIndexedDbPort
$origin = "http://127.0.0.1:$port"
$entryPattern = ConvertTo-IndexedDbEntryPattern $origin "lp-persist" "items" "persist" '{"status":"ok"}'
$browserOneOut = Join-Path $root "chrome-bare-metal-indexeddb-restart.run1.browser.stdout.txt"
$browserOneErr = Join-Path $root "chrome-bare-metal-indexeddb-restart.run1.browser.stderr.txt"
$browserTwoOut = Join-Path $root "chrome-bare-metal-indexeddb-restart.run2.browser.stdout.txt"
$browserTwoErr = Join-Path $root "chrome-bare-metal-indexeddb-restart.run2.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-indexeddb-restart.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-indexeddb-restart.server.stderr.txt"
Remove-Item $browserOneOut,$browserOneErr,$browserTwoOut,$browserTwoErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$browserOne = $null
$browserTwo = $null
$ready = $false
$seedWorked = $false
$persistedToDisk = $false
$restartWorked = $false
$browserOneGoneBeforeRestart = $false
$failure = $null
$titles = [ordered]@{}
$indexedDbData = ""

try {
  if (-not (Test-Path $manifestPath) -or -not (Test-Path $bootBinary) -or -not (Test-Path $archivePath)) {
    & $packageScript -PackageRoot $packageRoot -Url "https://example.com/" | Tee-Object -FilePath (Join-Path $root "chrome-bare-metal-indexeddb-restart.package.stdout.txt") | ConvertFrom-Json | Out-Null
  }

  if (-not (Test-Path $manifestPath)) { throw "manifest missing: $manifestPath" }
  if (-not (Test-Path $bootBinary)) { throw "boot binary missing: $bootBinary" }
  if (-not (Test-Path $archivePath)) { throw "archive missing: $archivePath" }

  $server = Start-IndexedDbServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-IndexedDbServer -Port $port
  if (-not $ready) { throw "indexeddb server did not become ready" }

  $browserOne = Start-IndexedDbBrowser -StartupUrl "$origin/seed.html" -Stdout $browserOneOut -Stderr $browserOneErr
  $hwndOne = Wait-TabWindowHandle $browserOne.Id
  if ($hwndOne -eq [IntPtr]::Zero) { throw "indexeddb restart run1 window handle not found" }
  Show-SmokeWindow $hwndOne

  $titles.seed = Wait-TabTitle $browserOne.Id "IndexedDB Seeded" 40
  $seedWorked = [bool]$titles.seed
  if (-not $seedWorked) { throw "seed page did not finish indexeddb write" }

  $indexedDbData = Wait-IndexedDbFileMatch $app.IndexedDbFile $entryPattern
  $persistedToDisk = [bool]$indexedDbData
  if (-not $persistedToDisk) { throw "indexeddb data was not persisted before restart" }

  $browserOneMeta = Stop-OwnedProbeProcess $browserOne
  $browserOneGoneBeforeRestart = Wait-OwnedIndexedDbProbeProcessGone $browserOne.Id
  $browserOne = $null
  if (-not $browserOneGoneBeforeRestart) { throw "run1 browser pid did not exit before restart" }
  Start-Sleep -Milliseconds 300

  $browserTwo = Start-IndexedDbBrowser -StartupUrl "$origin/echo.html" -Stdout $browserTwoOut -Stderr $browserTwoErr
  $hwndTwo = Wait-TabWindowHandle $browserTwo.Id
  if ($hwndTwo -eq [IntPtr]::Zero) { throw "indexeddb restart run2 window handle not found" }
  Show-SmokeWindow $hwndTwo

  $titles.restart = Wait-TabTitle $browserTwo.Id "IndexedDB Echo ok" 40
  $restartWorked = [bool]$titles.restart
  if (-not $restartWorked) { throw "restarted browser did not reuse persisted indexeddb data" }
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
    persisted_to_disk = $persistedToDisk
    restart_worked = $restartWorked
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

  if ($failure -or -not $seedWorked -or -not $persistedToDisk -or -not $restartWorked) {
    exit 1
  }
}
