$repo = "C:\Users\adyba\src\lightpanda-browser"
$serverRoot = Join-Path $repo "tmp-browser-smoke\wrapped-link"
$port = 8151
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$readyPng = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-keyboard.ready.png"
$browserOut = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-keyboard.browser.stdout.txt"
$browserErr = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-keyboard.browser.stderr.txt"
$serverOut = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-keyboard.server.stdout.txt"
$serverErr = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-keyboard.server.stderr.txt"
Remove-Item $readyPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

. "$PSScriptRoot\..\common\Win32Input.ps1"
. "$PSScriptRoot\BookmarkProbeCommon.ps1"

function Count-Hits([string]$Pattern) {
  if (-not (Test-Path $serverErr)) { return 0 }
  return ([regex]::Matches((Get-Content $serverErr -Raw), $Pattern)).Count
}

function Wait-SmokeWindow([System.Diagnostics.Process]$Process) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $Process.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      return [IntPtr]$proc.MainWindowHandle
    }
  }
  throw "bookmark keyboard probe window handle not found"
}

function Wait-SmokeArtifact([string]$Path, [string]$Label) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
      return
    }
  }
  throw "bookmark keyboard probe $Label did not become ready"
}

$server = $null
$browser = $null
$ready = $false
$overlayWorked = $false
$initialIndexHits = 0
$afterOverlayIndexHits = 0
$backup = $null
$failure = $null

try {
  $backup = Backup-BookmarkProbeFile
  Set-BookmarkProbeEntries @("http://127.0.0.1:$port/index.html")

  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $serverRoot -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "bookmark keyboard probe server did not become ready" }

  $initialIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/next.html","--window_width","320","--window_height","420","--screenshot_png",$readyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-SmokeWindow $browser
  Wait-SmokeArtifact $readyPng "screenshot"
  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250

  Send-SmokeCtrlShiftB
  Start-Sleep -Milliseconds 250
  Send-SmokeEnter

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $afterOverlayIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
    if ($afterOverlayIndexHits -gt $initialIndexHits) {
      $overlayWorked = $true
      break
    }
  }
  if (-not $overlayWorked) { throw "bookmark keyboard probe did not navigate from bookmark overlay enter" }
} catch {
  $failure = $_.Exception.Message
} finally {
  if ($browser) { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 250
  Restore-BookmarkProbeFile $backup

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    overlay_worked = $overlayWorked
    initial_index_hits = $initialIndexHits
    after_overlay_index_hits = $afterOverlayIndexHits
    bookmark_file = Get-BookmarkProbeFile
    error = $failure
    browser_gone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
    server_gone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
    backup_restored = if ($backup) { -not (Test-Path $backup) } else { $true }
  } | ConvertTo-Json -Depth 6
}

if ($failure) {
  exit 1
}
