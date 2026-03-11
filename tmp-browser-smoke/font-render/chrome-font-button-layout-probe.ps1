$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\font-render"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "font_render_server.py"
$port = 8166
$serverOut = Join-Path $root "font-button-layout.server.stdout.txt"
$serverErr = Join-Path $root "font-button-layout.server.stderr.txt"

Remove-Item $serverOut,$serverErr -Force -ErrorAction SilentlyContinue

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

function Measure-ColorBounds($Path, [scriptblock]$Predicate) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($Path)
  try {
    $minX = $bmp.Width
    $minY = $bmp.Height
    $maxX = -1
    $maxY = -1
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if (& $Predicate $c) {
          if ($x -lt $minX) { $minX = $x }
          if ($y -lt $minY) { $minY = $y }
          if ($x -gt $maxX) { $maxX = $x }
          if ($y -gt $maxY) { $maxY = $y }
        }
      }
    }
    if ($maxX -lt 0 -or $maxY -lt 0) { throw "colored region not found in $Path" }
    return [ordered]@{
      left = $minX
      top = $minY
      right = $maxX
      bottom = $maxY
      width = $maxX - $minX + 1
      height = $maxY - $minY + 1
    }
  }
  finally {
    $bmp.Dispose()
  }
}

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/button-layout.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "font button layout server did not become ready" }

  $profileRoot = Join-Path $root "profile-font-button-layout"
  $appDataRoot = Join-Path $profileRoot "lightpanda"
  $outPng = Join-Path $root "font-button-layout.png"
  $browserOut = Join-Path $root "font-button-layout.browser.stdout.txt"
  $browserErr = Join-Path $root "font-button-layout.browser.stderr.txt"
  Remove-Item $outPng,$browserOut,$browserErr -Force -ErrorAction SilentlyContinue
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

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/button-layout.html","--window_width","980","--window_height","460","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $readyPng = $false
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
        $readyPng = $true
        break
      }
    }
    if (-not $readyPng) { throw "font button layout screenshot did not become ready" }

    $red = Measure-ColorBounds $outPng { param($c) $c.R -ge 150 -and $c.G -le 90 -and $c.B -le 90 }
    $blue = Measure-ColorBounds $outPng { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 90 }
    $widthDelta = [math]::Abs([int]$red.width - [int]$blue.width)
    $layoutWorked = $widthDelta -ge 10
    if (-not $layoutWorked) {
      throw "font button layout probe did not observe a sufficient width delta"
    }

    [ordered]@{
      ready = $true
      red = $red
      blue = $blue
      width_delta = $widthDelta
      layout_worked = $layoutWorked
    } | ConvertTo-Json -Depth 5
  }
  finally {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) {
      if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 100
    }
  }
}
finally {
  Stop-VerifiedProcess $server.Id
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
}
