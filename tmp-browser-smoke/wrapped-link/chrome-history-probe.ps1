$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\wrapped-link"
$port = 8147
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$beforePng = Join-Path $root "chrome-history.before.png"
$browserOut = Join-Path $root "chrome-history.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-history.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-history.server.stdout.txt"
$serverErr = Join-Path $root "chrome-history.server.stderr.txt"
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

function Count-Hits([string]$Pattern) {
  if (-not (Test-Path $serverErr)) { return 0 }
  return ([regex]::Matches((Get-Content $serverErr -Raw), $Pattern)).Count
}

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$linkWorked = $false
$backWorked = $false
$forwardWorked = $false
$initialIndexHits = 0
$initialNextHits = 0
$afterLinkNextHits = 0
$finalIndexHits = 0
$finalNextHits = 0
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
  if (-not $ready) { throw "chrome history probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$beforePng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $beforePng) -and ((Get-Item $beforePng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "chrome history screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "chrome history window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250

  $initialIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
  $initialNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'

  $bmp = [System.Drawing.Bitmap]::new($beforePng)
  try {
    $blue = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
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
  if ($linkWorked) { Start-Sleep -Milliseconds 1500 }

  [void](Invoke-SmokeClientClick $hwnd 25 40)
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $finalIndexHits = Count-Hits 'GET /index\.html HTTP/1\.1" 200'
    if ($finalIndexHits -gt $initialIndexHits) {
      $backWorked = $true
      break
    }
  }
  if ($backWorked) { Start-Sleep -Milliseconds 1500 }

  [void](Invoke-SmokeClientClick $hwnd 57 40)
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $finalNextHits = Count-Hits 'GET /next\.html HTTP/1\.1" 200'
    if ($finalNextHits -gt $afterLinkNextHits) {
      $forwardWorked = $true
      break
    }
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    link_worked = $linkWorked
    back_worked = $backWorked
    forward_worked = $forwardWorked
    initial_index_hits = $initialIndexHits
    initial_next_hits = $initialNextHits
    after_link_next_hits = $afterLinkNextHits
    final_index_hits = $finalIndexHits
    final_next_hits = $finalNextHits
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
