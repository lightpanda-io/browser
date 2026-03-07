$repo = "C:\Users\adyba\src\lightpanda-browser"
$serverRoot = Join-Path $repo "tmp-browser-smoke\wrapped-link"
$port = 8149
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browser1ReadyPng = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run1.ready.png"
$browser2ReadyPng = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run2.ready.png"
$browser1Out = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run1.stdout.txt"
$browser1Err = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run1.stderr.txt"
$browser2Out = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run2.stdout.txt"
$browser2Err = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-run2.stderr.txt"
$serverOut = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-server.stdout.txt"
$serverErr = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-server.stderr.txt"
Remove-Item $browser1ReadyPng,$browser2ReadyPng,$browser1Out,$browser1Err,$browser2Out,$browser2Err,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

. "$PSScriptRoot\..\common\Win32Input.ps1"

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
  throw "bookmark probe window handle not found"
}

function Wait-SmokeArtifact([string]$Path, [string]$Label) {
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
      return
    }
  }
  throw "bookmark probe $Label did not become ready"
}

$server = $null
$browser1 = $null
$browser2 = $null
$ready = $false
$bookmarkAdded = $false
$persistedWorked = $false
$bookmarkDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "lightpanda"
$bookmarkFile = Join-Path $bookmarkDir "bookmarks.txt"
$bookmarkBackup = "$bookmarkFile.codex-bak"
$bookmarkContent = $null
$overlayPoint = $null
$browser1Title = $null
$browser2Title = $null
$failure = $null

try {
  if (-not (Test-Path $bookmarkDir)) {
    New-Item -ItemType Directory -Path $bookmarkDir -Force | Out-Null
  }
  if (Test-Path $bookmarkBackup) {
    Remove-Item $bookmarkBackup -Force -ErrorAction Stop
  }
  if (Test-Path $bookmarkFile) {
    Copy-Item $bookmarkFile $bookmarkBackup -Force
  }
  Remove-Item $bookmarkFile -Force -ErrorAction SilentlyContinue

  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $serverRoot -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "bookmark probe server did not become ready" }

  $browser1 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","320","--window_height","420","--screenshot_png",$browser1ReadyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browser1Out -RedirectStandardError $browser1Err
  $hwnd1 = Wait-SmokeWindow $browser1
  Wait-SmokeArtifact $browser1ReadyPng "run1 screenshot"
  Show-SmokeWindow $hwnd1
  Start-Sleep -Milliseconds 250
  $browser1Title = Get-SmokeWindowTitle $hwnd1
  Send-SmokeCtrlD

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 200
    if (Test-Path $bookmarkFile) {
      $bookmarkContent = Get-Content $bookmarkFile -Raw
      if ($bookmarkContent -match [regex]::Escape("http://127.0.0.1:$port/index.html")) {
        $bookmarkAdded = $true
        break
      }
    }
  }
  if (-not $bookmarkAdded) { throw "bookmark probe did not persist the current page" }

  $browser1Meta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser1.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($browser1Meta -and $browser1Meta.CommandLine -and $browser1Meta.CommandLine -notmatch "codex\.js|@openai/codex") {
    Stop-Process -Id $browser1.Id -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 300

  $initialIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
  $browser2 = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/next.html","--window_width","320","--window_height","420","--screenshot_png",$browser2ReadyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browser2Out -RedirectStandardError $browser2Err
  $hwnd2 = Wait-SmokeWindow $browser2
  Wait-SmokeArtifact $browser2ReadyPng "run2 screenshot"
  Show-SmokeWindow $hwnd2
  Start-Sleep -Milliseconds 250
  $browser2Title = Get-SmokeWindowTitle $hwnd2
  Send-SmokeCtrlShiftB
  Start-Sleep -Milliseconds 350

  $overlayPoint = Invoke-SmokeClientClick $hwnd2 80 140
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $indexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
    if ($indexHits -gt $initialIndexHits) {
      $persistedWorked = $true
      break
    }
  }
  if (-not $persistedWorked) { throw "bookmark probe did not navigate from persisted bookmark overlay" }
} catch {
  $failure = $_.Exception.Message
} finally {
  if ($browser1) { Stop-Process -Id $browser1.Id -Force -ErrorAction SilentlyContinue }
  if ($browser2) { Stop-Process -Id $browser2.Id -Force -ErrorAction SilentlyContinue }
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 250

  if (Test-Path $bookmarkBackup) {
    Move-Item $bookmarkBackup $bookmarkFile -Force
  } elseif (Test-Path $bookmarkFile) {
    Remove-Item $bookmarkFile -Force -ErrorAction SilentlyContinue
  }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser1_pid = if ($browser1) { $browser1.Id } else { 0 }
    browser2_pid = if ($browser2) { $browser2.Id } else { 0 }
    ready = $ready
    bookmark_added = $bookmarkAdded
    persisted_worked = $persistedWorked
    bookmark_file = $bookmarkFile
    bookmark_content = $bookmarkContent
    browser1_ready_png = $browser1ReadyPng
    browser2_ready_png = $browser2ReadyPng
    browser1_title = $browser1Title
    browser2_title = $browser2Title
    overlay_point = $overlayPoint
    error = $failure
    browser1_gone = if ($browser1) { -not (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) } else { $true }
    browser2_gone = if ($browser2) { -not (Get-Process -Id $browser2.Id -ErrorAction SilentlyContinue) } else { $true }
    server_gone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
    bookmark_backup_restored = -not (Test-Path $bookmarkBackup)
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
