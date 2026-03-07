$ErrorActionPreference = "Stop"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\find"
$port = 8146
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$readyPng = Join-Path $root "find-ready.png"
$browserOut = Join-Path $root "find-browser.stdout.txt"
$browserErr = Join-Path $root "find-browser.stderr.txt"
$serverOut = Join-Path $root "find-server.stdout.txt"
$serverErr = Join-Path $root "find-server.stderr.txt"
Remove-Item $readyPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
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

function Get-LatestAutoScreenshot([datetime]$AfterUtc) {
  return Get-ChildItem -Path $repo -Filter "lightpanda-screenshot-*.png" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTimeUtc -ge $AfterUtc.AddMilliseconds(-200) } |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1
}

function Wait-AutoScreenshot([datetime]$AfterUtc) {
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $latest = Get-LatestAutoScreenshot $AfterUtc
    if ($latest) { return $latest.FullName }
  }
  throw "find probe screenshot did not become ready"
}

$server = $null
$browser = $null
$ready = $false
$readyPngWritten = $false
$hwnd = [IntPtr]::Zero
$firstPng = $null
$secondPng = $null
$thirdPng = $null
$firstBounds = $null
$secondBounds = $null
$thirdBounds = $null
$findNextPoint = $null
$findPreviousPoint = $null
$titleBefore = $null
$titleAfterFind = $null
$titleAfterNext = $null
$titleAfterPrevious = $null
$findWorked = $false
$nextWorked = $false
$previousWorked = $false
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
  if (-not $ready) { throw "find probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","360","--window_height","420","--screenshot_png",$readyPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $readyPng) -and ((Get-Item $readyPng).Length -gt 0)) { $readyPngWritten = $true; break }
  }
  if (-not $readyPngWritten) { throw "find probe ready screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "find probe window handle not found" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 350
  $titleBefore = Get-SmokeWindowTitle $hwnd

  Send-SmokeCtrlF
  Start-Sleep -Milliseconds 150
  Send-SmokeText "target"
  Start-Sleep -Milliseconds 350
  $titleAfterFind = Get-SmokeWindowTitle $hwnd

  $captureStart = [DateTime]::UtcNow
  Send-SmokeCtrlShiftP
  $firstPng = Wait-AutoScreenshot $captureStart

  $bmp = [System.Drawing.Bitmap]::new($firstPng)
  try {
    $clientWidth = $bmp.Width
    $firstBounds = Get-ColorBounds $bmp { param($c) $c.R -ge 250 -and $c.G -ge 235 -and $c.G -le 250 -and $c.B -ge 120 -and $c.B -le 180 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $firstBounds.min_y) { throw "find probe could not find initial highlight" }
  $findWorked = $true

  $findNextX = [int]($clientWidth - 24)
  $findPreviousX = [int]($clientWidth - 48)
  $findButtonY = 15

  Start-Sleep -Milliseconds 1200
  $findNextPoint = Invoke-SmokeClientClick $hwnd $findNextX $findButtonY
  Start-Sleep -Milliseconds 350
  $titleAfterNext = Get-SmokeWindowTitle $hwnd

  $captureStart = [DateTime]::UtcNow
  Send-SmokeCtrlShiftP
  $secondPng = Wait-AutoScreenshot $captureStart

  $bmp = [System.Drawing.Bitmap]::new($secondPng)
  try {
    $secondBounds = Get-ColorBounds $bmp { param($c) $c.R -ge 250 -and $c.G -ge 235 -and $c.G -le 250 -and $c.B -ge 120 -and $c.B -le 180 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $secondBounds.min_y) { throw "find probe could not find next highlight" }

  $nextWorked = ($secondBounds.min_y -gt ($firstBounds.min_y + 20))
  if (-not $nextWorked) { throw "find probe highlight did not move after next button click" }

  Start-Sleep -Milliseconds 1200
  $findPreviousPoint = Invoke-SmokeClientClick $hwnd $findPreviousX $findButtonY
  Start-Sleep -Milliseconds 350
  $titleAfterPrevious = Get-SmokeWindowTitle $hwnd

  $captureStart = [DateTime]::UtcNow
  Send-SmokeCtrlShiftP
  $thirdPng = Wait-AutoScreenshot $captureStart

  $bmp = [System.Drawing.Bitmap]::new($thirdPng)
  try {
    $thirdBounds = Get-ColorBounds $bmp { param($c) $c.R -ge 250 -and $c.G -ge 235 -and $c.G -le 250 -and $c.B -ge 120 -and $c.B -le 180 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $thirdBounds.min_y) { throw "find probe could not find previous highlight" }

  $previousWorked = ($thirdBounds.min_y -lt ($secondBounds.min_y - 20))
  if (-not $previousWorked) { throw "find probe highlight did not move back after previous button click" }
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
    ready_screenshot = $readyPngWritten
    ready_png = $readyPng
    first_png = $firstPng
    second_png = $secondPng
    third_png = $thirdPng
    title_before = $titleBefore
    title_after_find = $titleAfterFind
    title_after_next = $titleAfterNext
    title_after_previous = $titleAfterPrevious
    find_next_point = $findNextPoint
    find_previous_point = $findPreviousPoint
    first_bounds = $firstBounds
    second_bounds = $secondBounds
    third_bounds = $thirdBounds
    find_worked = $findWorked
    next_worked = $nextWorked
    previous_worked = $previousWorked
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
