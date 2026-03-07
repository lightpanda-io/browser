$repo = "C:\Users\adyba\src\lightpanda-browser"
$serverRoot = Join-Path $repo "tmp-browser-smoke\wrapped-link"
$port = 8155
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$readyPng = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-close.ready.png"
$browserOut = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-close.browser.stdout.txt"
$browserErr = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-close.browser.stderr.txt"
$serverOut = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-close.server.stdout.txt"
$serverErr = Join-Path $repo "tmp-browser-smoke\bookmarks\bookmark-close.server.stderr.txt"
Remove-Item $readyPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot\..\common\Win32Input.ps1"
. "$PSScriptRoot\BookmarkProbeCommon.ps1"

function Get-ColorBounds([System.Drawing.Bitmap]$Bitmap, [scriptblock]$Matcher) {
  $bounds = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      $c = $Bitmap.GetPixel($x, $y)
      if (& $Matcher $c) {
        if ($null -eq $bounds.min_x -or $x -lt $bounds.min_x) { $bounds.min_x = $x }
        if ($null -eq $bounds.min_y -or $y -lt $bounds.min_y) { $bounds.min_y = $y }
        if ($null -eq $bounds.max_x -or $x -gt $bounds.max_x) { $bounds.max_x = $x }
        if ($null -eq $bounds.max_y -or $y -gt $bounds.max_y) { $bounds.max_y = $y }
        $bounds.count++
      }
    }
  }
  return $bounds
}

function Count-Hits([string]$Pattern) {
  if (-not (Test-Path $serverErr)) { return 0 }
  return ([regex]::Matches((Get-Content $serverErr -Raw), $Pattern)).Count
}

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$closeWorked = $false
$navigateWorked = $false
$initialNextHits = 0
$afterNextHits = 0
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
  if (-not $ready) { throw "bookmark close probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","320","--window_height","420","--screenshot_png",$readyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $readyPng) -and ((Get-Item $readyPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "bookmark close probe screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "bookmark close probe window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($readyPng)
  try {
    $blue = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $blue.min_x) { throw "bookmark close probe could not find wrapped link" }

  $linkX = [int][Math]::Floor(($blue.min_x + $blue.max_x) / 2)
  $linkY = [int][Math]::Floor(($blue.min_y + $blue.max_y) / 2)
  $initialNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  Send-SmokeCtrlShiftB
  Start-Sleep -Milliseconds 250
  [void](Invoke-SmokeClientClick $hwnd 286 115)
  Start-Sleep -Milliseconds 250
  $closeWorked = $true

  Show-SmokeWindow $hwnd
  [void](Invoke-SmokeClientClick $hwnd $linkX $linkY)

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $afterNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'
    if ($afterNextHits -gt $initialNextHits) {
      $navigateWorked = $true
      break
    }
  }
  if (-not $navigateWorked) { throw "bookmark close probe did not allow page navigation after close button" }
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
    screenshot_ready = $pngReady
    close_worked = $closeWorked
    navigate_worked = $navigateWorked
    initial_next_hits = $initialNextHits
    after_next_hits = $afterNextHits
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
