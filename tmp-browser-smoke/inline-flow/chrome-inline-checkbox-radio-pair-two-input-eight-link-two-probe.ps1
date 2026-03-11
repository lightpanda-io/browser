$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\inline-flow"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$port = 8153
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "checkbox-radio-pair-two-input-eight-link-two.png"
$browserOut = Join-Path $root "checkbox-radio-pair-two-input-eight-link-two.browser.stdout.txt"
$browserErr = Join-Path $root "checkbox-radio-pair-two-input-eight-link-two.browser.stderr.txt"
$serverOut = Join-Path $root "checkbox-radio-pair-two-input-eight-link-two.server.stdout.txt"
$serverErr = Join-Path $root "checkbox-radio-pair-two-input-eight-link-two.server.stderr.txt"
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
$checkboxOne = $null
$titleBefore = $null
$titleAfterCheckboxOne = $null
$titleAfterCheckboxTwo = $null
$titleAfterRadioOne = $null
$titleAfterRadioTwo = $null
$titleAfterInputOne = $null
$titleAfterInputTwo = $null
$titleAfterLink = $null
$checkboxOneWorked = $false
$checkboxTwoWorked = $false
$radioOneWorked = $false
$radioTwoWorked = $false
$inputOneWorked = $false
$inputTwoWorked = $false
$linkWorked = $false
$serverSawNext = $false
$failure = $null
$checkboxOneClickPoint = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/checkbox-radio-pair-two-input-eight-link-submit.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "inline checkbox radio pair two input eight-link second probe server did not become ready" }

  $profileRoot = Join-Path $root "profile-inline-checkbox-radio-pair-two-input-eight-link-two"
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

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/checkbox-radio-pair-two-input-eight-link-submit.html","--window_width","760","--window_height","560","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "inline checkbox radio pair two input eight-link second screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "inline checkbox radio pair two input eight-link second window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $checkboxOne = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 25 -and $c.R -le 60 -and $c.G -ge 135 -and $c.G -le 170 -and $c.B -ge 75 -and $c.B -le 120) {
          Add-Pixel $checkboxOne $x $y
        }
      }
    }
  } finally {
    $bmp.Dispose()
  }

  if ($null -eq $checkboxOne.min_y) { throw "inline checkbox radio pair two input eight-link second probe did not isolate the first checkbox control" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  $checkboxOneCenterX = [int][Math]::Floor(($checkboxOne.min_x + $checkboxOne.max_x) / 2)
  $checkboxOneCenterY = [int][Math]::Floor(($checkboxOne.min_y + $checkboxOne.max_y) / 2)
  $checkboxOneClickPoint = Invoke-SmokeClientClick $hwnd $checkboxOneCenterX $checkboxOneCenterY
  $titleAfterCheckboxOne = $titleBefore
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterCheckboxOne = Get-SmokeWindowTitle $hwnd
    if ($titleAfterCheckboxOne -like "Dense Eight Link checkbox one true*") {
      $checkboxOneWorked = $true
      break
    }
  }
  if (-not $checkboxOneWorked) { throw "inline checkbox radio pair two input eight-link second probe first checkbox did not toggle on click" }

  Send-SmokeTab; Start-Sleep -Milliseconds 120; Send-SmokeSpace
  $titleAfterCheckboxTwo = $titleAfterCheckboxOne
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterCheckboxTwo = Get-SmokeWindowTitle $hwnd
    if ($titleAfterCheckboxTwo -like "Dense Eight Link checkbox two true*") { $checkboxTwoWorked = $true; break }
  }
  if (-not $checkboxTwoWorked) { throw "inline checkbox radio pair two input eight-link second probe second checkbox did not toggle on space after tab" }

  Send-SmokeTab; Start-Sleep -Milliseconds 120; Send-SmokeSpace
  $titleAfterRadioOne = $titleAfterCheckboxTwo
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterRadioOne = Get-SmokeWindowTitle $hwnd
    if ($titleAfterRadioOne -like "Dense Eight Link radio one true*") { $radioOneWorked = $true; break }
  }
  if (-not $radioOneWorked) { throw "inline checkbox radio pair two input eight-link second probe first radio did not select on space after tab" }

  Send-SmokeTab; Start-Sleep -Milliseconds 120; Send-SmokeSpace
  $titleAfterRadioTwo = $titleAfterRadioOne
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterRadioTwo = Get-SmokeWindowTitle $hwnd
    if ($titleAfterRadioTwo -like "Dense Eight Link radio two true*") { $radioTwoWorked = $true; break }
  }
  if (-not $radioTwoWorked) { throw "inline checkbox radio pair two input eight-link second probe second radio did not select on space after tab" }

  Send-SmokeTab; Start-Sleep -Milliseconds 120; Send-SmokeText "QZ"
  $titleAfterInputOne = $titleAfterRadioTwo
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterInputOne = Get-SmokeWindowTitle $hwnd
    if ($titleAfterInputOne -like "Dense Eight Link entry one QZ*") { $inputOneWorked = $true; break }
  }
  if (-not $inputOneWorked) { throw "inline checkbox radio pair two input eight-link second probe first input did not update after typing" }

  Send-SmokeTab; Start-Sleep -Milliseconds 120; Send-SmokeText "LM"
  $titleAfterInputTwo = $titleAfterInputOne
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 150
    $titleAfterInputTwo = Get-SmokeWindowTitle $hwnd
    if ($titleAfterInputTwo -like "Dense Eight Link entry two LM*") { $inputTwoWorked = $true; break }
  }
  if (-not $inputTwoWorked) { throw "inline checkbox radio pair two input eight-link second probe second input did not update after typing" }

  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeTab
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  $titleAfterLink = $titleAfterInputTwo
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 200
    $titleAfterLink = Get-SmokeWindowTitle $hwnd
    if ($titleAfterLink -like "Inline Flow Target Two*") { $linkWorked = $true; break }
  }
  if (-not $linkWorked -and (Test-Path $serverErr)) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawNext = $serverLog -match 'GET /next-two\.html(\?| )'
    if ($serverSawNext) { $linkWorked = $true }
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
    checkbox_one_bounds = $checkboxOne
    title_before = $titleBefore
    title_after_checkbox_one = $titleAfterCheckboxOne
    title_after_checkbox_two = $titleAfterCheckboxTwo
    title_after_radio_one = $titleAfterRadioOne
    title_after_radio_two = $titleAfterRadioTwo
    title_after_input_one = $titleAfterInputOne
    title_after_input_two = $titleAfterInputTwo
    title_after_link = $titleAfterLink
    checkbox_one_click_screen = $checkboxOneClickPoint
    checkbox_one_worked = $checkboxOneWorked
    checkbox_two_worked = $checkboxTwoWorked
    radio_one_worked = $radioOneWorked
    radio_two_worked = $radioTwoWorked
    input_one_worked = $inputOneWorked
    input_two_worked = $inputTwoWorked
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
