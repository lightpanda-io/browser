$ErrorActionPreference = "Stop"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\zoom"
$port = 8145
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$beforePng = Join-Path $root "zoom-before.png"
$browserOut = Join-Path $root "zoom-browser.stdout.txt"
$browserErr = Join-Path $root "zoom-browser.stderr.txt"
$serverOut = Join-Path $root "zoom-server.stdout.txt"
$serverErr = Join-Path $root "zoom-server.stderr.txt"
Remove-Item $beforePng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Get-ChildItem -Path $repo -Filter "lightpanda-screenshot-*.png" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

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

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$hwnd = [IntPtr]::Zero
$beforeBounds = $null
$afterBounds = $null
$afterPng = $null
$wheelPoint = $null
$zoomWorked = $false
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
  if (-not $ready) { throw "zoom probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","320","--window_height","420","--screenshot_png",$beforePng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $beforePng) -and ((Get-Item $beforePng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "zoom probe screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "zoom probe window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($beforePng)
  try {
    $beforeBounds = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $beforeBounds.min_x) { throw "zoom probe could not find initial blue box" }

  $clientX = [int][Math]::Floor(($beforeBounds.min_x + $beforeBounds.max_x) / 2)
  $clientY = [int][Math]::Floor(($beforeBounds.min_y + $beforeBounds.max_y) / 2)
  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 300
  $wheelPoint = Invoke-SmokeClientCtrlWheel $hwnd $clientX $clientY 120
  Start-Sleep -Milliseconds 300
  Send-SmokeCtrlShiftP

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $latest = Get-ChildItem -Path $repo -Filter "lightpanda-screenshot-*.png" -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($latest) {
      $afterPng = $latest.FullName
      break
    }
  }
  if (-not $afterPng) { throw "zoom probe did not create after screenshot" }

  $bmp = [System.Drawing.Bitmap]::new($afterPng)
  try {
    $afterBounds = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $afterBounds.min_x) { throw "zoom probe could not find zoomed blue box" }

  $beforeWidth = $beforeBounds.max_x - $beforeBounds.min_x + 1
  $beforeHeight = $beforeBounds.max_y - $beforeBounds.min_y + 1
  $afterWidth = $afterBounds.max_x - $afterBounds.min_x + 1
  $afterHeight = $afterBounds.max_y - $afterBounds.min_y + 1
  $zoomWorked = ($afterWidth -gt $beforeWidth) -and ($afterHeight -gt $beforeHeight)
  if (-not $zoomWorked) { throw "zoom probe box did not grow after Ctrl+wheel" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    before_png = $beforePng
    after_png = $afterPng
    before_bounds = $beforeBounds
    after_bounds = $afterBounds
    wheel_screen = if ($wheelPoint) { [ordered]@{ x = $wheelPoint.X; y = $wheelPoint.Y } } else { $null }
    before_width = if ($beforeBounds -and $null -ne $beforeBounds.min_x) { $beforeBounds.max_x - $beforeBounds.min_x + 1 } else { 0 }
    before_height = if ($beforeBounds -and $null -ne $beforeBounds.min_y) { $beforeBounds.max_y - $beforeBounds.min_y + 1 } else { 0 }
    after_width = if ($afterBounds -and $null -ne $afterBounds.min_x) { $afterBounds.max_x - $afterBounds.min_x + 1 } else { 0 }
    after_height = if ($afterBounds -and $null -ne $afterBounds.min_y) { $afterBounds.max_y - $afterBounds.min_y + 1 } else { 0 }
    zoom_worked = $zoomWorked
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
