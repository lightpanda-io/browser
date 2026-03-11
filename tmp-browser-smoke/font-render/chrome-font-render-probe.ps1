$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\font-render"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$profileRoot = Join-Path $root "profile-font-render"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8163
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "font_render_server.py"
$outPng = Join-Path $root "font-render.png"
$browserOut = Join-Path $root "font-render.browser.stdout.txt"
$browserErr = Join-Path $root "font-render.browser.stderr.txt"
$serverOut = Join-Path $root "font-render.server.stdout.txt"
$serverErr = Join-Path $root "font-render.server.stderr.txt"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) { throw "font render server did not become ready" }

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","520","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
$pngReady = $false
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
    $pngReady = $true
    break
  }
}
if (-not $pngReady) { throw "font render screenshot did not become ready" }

$redBounds = $null
$blueBounds = $null
$widthDelta = 0
$fontWorked = $false
$browserCommand = ""
$serverCommand = ""
$browserGone = $false
$serverGone = $false

try {
  Add-Type -AssemblyName System.Drawing

  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($outPng)
      try {
        $redMinX = $bmp.Width
        $redMinY = $bmp.Height
        $redMaxX = -1
        $redMaxY = -1
        $blueMinX = $bmp.Width
        $blueMinY = $bmp.Height
        $blueMaxX = -1
        $blueMaxY = -1

        for ($y = 0; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -ge 120 -and $c.G -le 100 -and $c.B -le 100) {
              if ($x -lt $redMinX) { $redMinX = $x }
              if ($y -lt $redMinY) { $redMinY = $y }
              if ($x -gt $redMaxX) { $redMaxX = $x }
              if ($y -gt $redMaxY) { $redMaxY = $y }
            }
            if ($c.B -ge 120 -and $c.G -le 100 -and $c.R -le 100) {
              if ($x -lt $blueMinX) { $blueMinX = $x }
              if ($y -lt $blueMinY) { $blueMinY = $y }
              if ($x -gt $blueMaxX) { $blueMaxX = $x }
              if ($y -gt $blueMaxY) { $blueMaxY = $y }
            }
          }
        }
      } finally {
        $bmp.Dispose()
      }

      if ($redMaxX -ge 0 -and $redMaxY -ge 0) {
        $redBounds = [ordered]@{
          left = $redMinX
          top = $redMinY
          right = $redMaxX
          bottom = $redMaxY
          width = $redMaxX - $redMinX + 1
          height = $redMaxY - $redMinY + 1
        }
      }
      if ($blueMaxX -ge 0 -and $blueMaxY -ge 0) {
        $blueBounds = [ordered]@{
          left = $blueMinX
          top = $blueMinY
          right = $blueMaxX
          bottom = $blueMaxY
          width = $blueMaxX - $blueMinX + 1
          height = $blueMaxY - $blueMinY + 1
        }
      }
      break
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }

  $widthDelta = if ($redBounds -and $blueBounds) { [math]::Abs([int]$redBounds.width - [int]$blueBounds.width) } else { 0 }
  $fontWorked = ($redBounds -ne $null) -and ($blueBounds -ne $null) -and $widthDelta -ge 40
  if (-not $fontWorked) {
    throw "font render probe did not observe materially different glyph widths"
  }
}
finally {
  $browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" -ErrorAction SilentlyContinue |
    Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($browserMeta) {
    $browserCommand = [string]$browserMeta.CommandLine
    if ($browserCommand -notmatch "codex\.js|@openai/codex") {
      try {
        Stop-Process -Id $browser.Id -Force -ErrorAction Stop
      } catch {
        if (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) { throw }
      }
    }
  }

  $serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" -ErrorAction SilentlyContinue |
    Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($serverMeta) {
    $serverCommand = [string]$serverMeta.CommandLine
    if ($serverCommand -notmatch "codex\.js|@openai/codex") {
      try {
        Stop-Process -Id $server.Id -Force -ErrorAction Stop
      } catch {
        if (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) { throw }
      }
    }
  }

  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
  $browserGone = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
  $serverGone = -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)
}

[ordered]@{
  server_pid = $server.Id
  browser_pid = $browser.Id
  ready = $ready
  screenshot_ready = $pngReady
  screenshot_path = $outPng
  screenshot_length = if (Test-Path $outPng) { (Get-Item $outPng).Length } else { 0 }
  red_bounds = $redBounds
  blue_bounds = $blueBounds
  width_delta = $widthDelta
  font_worked = $fontWorked
  browser_command = $browserCommand
  server_command = $serverCommand
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
