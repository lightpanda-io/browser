$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\wrapped-link"
$port = 8153
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$readyPng = Join-Path $root "chrome-history-keyboard.ready.png"
$browserOut = Join-Path $root "chrome-history-keyboard.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-history-keyboard.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-history-keyboard.server.stdout.txt"
$serverErr = Join-Path $root "chrome-history-keyboard.server.stderr.txt"
Remove-Item $readyPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot\..\common\Win32Input.ps1"

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
$linkWorked = $false
$overlayWorked = $false
$initialIndexHits = 0
$initialNextHits = 0
$afterLinkNextHits = 0
$afterOverlayIndexHits = 0
$failure = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "history keyboard probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$readyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $readyPng) -and ((Get-Item $readyPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "history keyboard probe screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "history keyboard probe window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250

  $initialIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
  $initialNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'

  $bmp = [System.Drawing.Bitmap]::new($readyPng)
  try {
    $blue = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $blue.min_x) { throw "history keyboard probe could not find wrapped link" }

  $linkX = [int][Math]::Floor(($blue.min_x + $blue.max_x) / 2)
  $linkY = [int][Math]::Floor(($blue.min_y + $blue.max_y) / 2)
  [void](Invoke-SmokeClientClick $hwnd $linkX $linkY)

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $afterLinkNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'
    if ($afterLinkNextHits -gt $initialNextHits) {
      $linkWorked = $true
      break
    }
  }
  if (-not $linkWorked) { throw "history keyboard probe did not reach next page before opening overlay" }

  Start-Sleep -Milliseconds 1200
  Show-SmokeWindow $hwnd
  Send-SmokeCtrlH
  Start-Sleep -Milliseconds 250
  Send-SmokeUp
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $afterOverlayIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
    if ($afterOverlayIndexHits -gt $initialIndexHits) {
      $overlayWorked = $true
      break
    }
  }
  if (-not $overlayWorked) { throw "history keyboard probe did not traverse back to the selected history row" }
} catch {
  $failure = $_.Exception.Message
} finally {
  if ($browser) { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 250

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    link_worked = $linkWorked
    overlay_worked = $overlayWorked
    initial_index_hits = $initialIndexHits
    initial_next_hits = $initialNextHits
    after_link_next_hits = $afterLinkNextHits
    after_overlay_index_hits = $afterOverlayIndexHits
    error = $failure
    browser_gone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
    server_gone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  } | ConvertTo-Json -Depth 6
}

if ($failure) {
  exit 1
}
