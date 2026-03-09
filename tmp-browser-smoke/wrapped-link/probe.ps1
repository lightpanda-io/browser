$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\wrapped-link"
$port = 8142
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$beforePng = Join-Path $root "wrapped-before.png"
$browserOut = Join-Path $root "browser.stdout.txt"
$browserErr = Join-Path $root "browser.stderr.txt"
$serverOut = Join-Path $root "server.stdout.txt"
$serverErr = Join-Path $root "server.stderr.txt"
Remove-Item $beforePng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

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
$red = $null
$blue = $null
$wrapped = $false
$clickClientX = $null
$clickClientY = $null
$clickPoint = $null
$hwnd = [IntPtr]::Zero
$titleBefore = $null
$titleAfter = $null
$navigated = $false
$serverSawNext = $false
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
  if (-not $ready) { throw "wrapped-link probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$beforePng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $beforePng) -and ((Get-Item $beforePng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "wrapped-link screenshot did not become ready" }

  $proc = $null
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "wrapped-link window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($beforePng)
  try {
    $red = Get-ColorBounds $bmp { param($c) $c.R -ge 170 -and $c.G -le 90 -and $c.B -le 90 }
    $blue = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }

  if ($null -ne $red.min_y -and $null -ne $blue.min_y) {
    $wrapped = (($blue.min_y - $red.min_y) -ge 20)
  }
  if (-not $wrapped) { throw "wrapped-link fixture did not wrap as expected" }

  $clickClientX = [int][Math]::Floor(($blue.min_x + $blue.max_x) / 2)
  $clickClientY = [int][Math]::Floor(($blue.min_y + $blue.max_y) / 2)
  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd
  $clickPoint = Invoke-SmokeClientClick $hwnd $clickClientX $clickClientY

  $titleAfter = $titleBefore
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $titleAfter = Get-SmokeWindowTitle $hwnd
    if ($titleAfter -like "Wrapped Link Target*") {
      $navigated = $true
      break
    }
  }
  if (-not $navigated -and (Test-Path $serverErr)) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawNext = $serverLog -match 'GET /next\.html HTTP/1\.1" 200'
    if ($serverSawNext) {
      $navigated = $true
    }
  }
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
    screenshot_path = $beforePng
    screenshot_length = if (Test-Path $beforePng) { (Get-Item $beforePng).Length } else { 0 }
    red_bounds = $red
    blue_bounds = $blue
    wrapped = $wrapped
    click_client = if ($null -ne $clickClientX) { [ordered]@{ x = $clickClientX; y = $clickClientY } } else { $null }
    click_screen = if ($null -ne $clickClientX) { [ordered]@{ x = $clickPoint.X; y = $clickPoint.Y } } else { $null }
    title_before = $titleBefore
    title_after = $titleAfter
    navigated = $navigated
    server_saw_next = $serverSawNext
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
