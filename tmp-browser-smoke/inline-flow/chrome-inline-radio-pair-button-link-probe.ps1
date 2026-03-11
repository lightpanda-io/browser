$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\inline-flow"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$port = 8153
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "radio-pair-button-link.png"
$browserOut = Join-Path $root "radio-pair-button-link.browser.stdout.txt"
$browserErr = Join-Path $root "radio-pair-button-link.browser.stderr.txt"
$serverOut = Join-Path $root "radio-pair-button-link.server.stdout.txt"
$serverErr = Join-Path $root "radio-pair-button-link.server.stderr.txt"
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
$radioOne = $null
$titleBefore = $null
$titleAfterRadioOne = $null
$titleAfterRadioTwo = $null
$titleAfterButton = $null
$titleAfterLink = $null
$radioOneWorked = $false
$radioTwoWorked = $false
$buttonWorked = $false
$linkWorked = $false
$serverSawNext = $false
$failure = $null
$radioOneClickPoint = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/radio-pair-button-link.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "inline radio pair button link probe server did not become ready" }

  $profileRoot = Join-Path $root "profile-inline-radio-pair-button-link"
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

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/radio-pair-button-link.html","--window_width","760","--window_height","560","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "inline radio pair button link screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "inline radio pair button link window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $radioOne = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 25 -and $c.R -le 60 -and $c.G -ge 135 -and $c.G -le 170 -and $c.B -ge 75 -and $c.B -le 120) {
          Add-Pixel $radioOne $x $y
        }
      }
    }
  } finally {
    $bmp.Dispose()
  }

  if ($null -eq $radioOne.min_y) { throw "inline radio pair button link probe did not isolate the first radio control" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  $radioOneCenterX = [int][Math]::Floor(($radioOne.min_x + $radioOne.max_x) / 2)
  $radioOneCenterY = [int][Math]::Floor(($radioOne.min_y + $radioOne.max_y) / 2)
  $radioOneClickPoint = Invoke-SmokeClientClick $hwnd $radioOneCenterX $radioOneCenterY
  $titleAfterRadioOne = $titleBefore
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterRadioOne = Get-SmokeWindowTitle $hwnd
    if ($titleAfterRadioOne -like "Dense Pair Radio one true*") {
      $radioOneWorked = $true
      break
    }
  }
  if (-not $radioOneWorked) { throw "inline radio pair button link probe first radio did not select on click" }

  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeSpace
  $titleAfterRadioTwo = $titleAfterRadioOne
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterRadioTwo = Get-SmokeWindowTitle $hwnd
    if ($titleAfterRadioTwo -like "Dense Pair Radio two true*") {
      $radioTwoWorked = $true
      break
    }
  }
  if (-not $radioTwoWorked) { throw "inline radio pair button link probe second radio did not select on space after tab" }

  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeSpace
  $titleAfterButton = $titleAfterRadioTwo
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterButton = Get-SmokeWindowTitle $hwnd
    if ($titleAfterButton -like "Dense Pair Button 1*") {
      $buttonWorked = $true
      break
    }
  }
  if (-not $buttonWorked) { throw "inline radio pair button link probe button did not activate on space after tab" }

  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  $titleAfterLink = $titleAfterButton
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
    radio_one_bounds = $radioOne
    title_before = $titleBefore
    title_after_radio_one = $titleAfterRadioOne
    title_after_radio_two = $titleAfterRadioTwo
    title_after_button = $titleAfterButton
    title_after_link = $titleAfterLink
    radio_one_click_screen = $radioOneClickPoint
    radio_one_worked = $radioOneWorked
    radio_two_worked = $radioTwoWorked
    button_worked = $buttonWorked
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
