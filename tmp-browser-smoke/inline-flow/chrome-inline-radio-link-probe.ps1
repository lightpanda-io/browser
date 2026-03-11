$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\inline-flow"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$port = 8153
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "radio-link.png"
$browserOut = Join-Path $root "radio-link.browser.stdout.txt"
$browserErr = Join-Path $root "radio-link.browser.stderr.txt"
$serverOut = Join-Path $root "radio-link.server.stdout.txt"
$serverErr = Join-Path $root "radio-link.server.stderr.txt"
Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot\..\common\Win32Input.ps1"

function Get-ProcessCommandLine($TargetPid) {
  $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue |
    Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($meta) { return [string]$meta.CommandLine }
  return ""
}

function Stop-VerifiedProcess($TargetPid) {
  $cmd = Get-ProcessCommandLine $TargetPid
  if ($cmd -and $cmd -notmatch "codex\.js|@openai/codex") {
    try {
      Stop-Process -Id $TargetPid -Force -ErrorAction Stop
    } catch {
      if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) { throw }
    }
  }
}

function Add-Pixel($o, $x, $y) {
  if ($null -eq $o.min_x -or $x -lt $o.min_x) { $o.min_x = $x }
  if ($null -eq $o.min_y -or $y -lt $o.min_y) { $o.min_y = $y }
  if ($null -eq $o.max_x -or $x -gt $o.max_x) { $o.max_x = $x }
  if ($null -eq $o.max_y -or $y -gt $o.max_y) { $o.max_y = $y }
  $o.count++
}

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$hwnd = [IntPtr]::Zero
$radio = $null
$titleBefore = $null
$titleAfterClick = $null
$titleAfterLink = $null
$clickWorked = $false
$linkWorked = $false
$serverSawNext = $false
$failure = $null
$clickPoint = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/radio-link.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "inline radio link probe server did not become ready" }

  $profileRoot = Join-Path $root "profile-inline-radio-link"
  $appDataRoot = Join-Path $profileRoot "lightpanda"
  cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/radio-link.html","--window_width","760","--window_height","560","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "inline radio link screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "inline radio link window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $radio = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 200 -and $c.R -le 225 -and $c.G -ge 125 -and $c.G -le 150 -and $c.B -ge 15 -and $c.B -le 40) {
          Add-Pixel $radio $x $y
        }
      }
    }
  } finally {
    $bmp.Dispose()
  }

  if ($null -eq $radio.min_y) { throw "inline radio link probe did not isolate the radio control" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  $centerX = [int][Math]::Floor(($radio.min_x + $radio.max_x) / 2)
  $centerY = [int][Math]::Floor(($radio.min_y + $radio.max_y) / 2)
  $clickPoint = Invoke-SmokeClientClick $hwnd $centerX $centerY
  $titleAfterClick = $titleBefore
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterClick = Get-SmokeWindowTitle $hwnd
    if ($titleAfterClick -like "Inline Radio two True*") {
      $clickWorked = $true
      break
    }
  }
  if (-not $clickWorked) { throw "inline radio link probe radio did not select on click" }

  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  $titleAfterLink = $titleAfterClick
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 200
    $titleAfterLink = Get-SmokeWindowTitle $hwnd
    if ($titleAfterLink -like "Inline Flow Target*") {
      $linkWorked = $true
      break
    }
  }
  if (-not $linkWorked -and (Test-Path $serverErr)) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawNext = $serverLog -match 'GET /next\.html HTTP/1\.1" 200'
    if ($serverSawNext) {
      $linkWorked = $true
    }
  }
}
catch {
  $failure = $_.Exception.Message
}
finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-VerifiedProcess $browser.Id }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-VerifiedProcess $server.Id }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    radio_bounds = $radio
    title_before = $titleBefore
    title_after_click = $titleAfterClick
    title_after_link = $titleAfterLink
    click_screen = $clickPoint
    click_worked = $clickWorked
    link_worked = $linkWorked
    server_saw_next = $serverSawNext
    error = $failure
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
