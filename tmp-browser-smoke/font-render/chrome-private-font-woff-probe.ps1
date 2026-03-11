$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\font-render"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "font_render_server.py"
$port = 8165
$serverOut = Join-Path $root "private-font-woff.server.stdout.txt"
$serverErr = Join-Path $root "private-font-woff.server.stderr.txt"

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

function Measure-RedWidth($Path) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width
        $minY = $bmp.Height
        $maxX = -1
        $maxY = -1
        for ($y = 0; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -ge 120 -and $c.G -le 100 -and $c.B -le 100) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minY) { $minY = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
      } finally {
        $bmp.Dispose()
      }
      if ($maxX -lt 0 -or $maxY -lt 0) { throw "red text not found in $Path" }
      return [ordered]@{
        left = $minX
        top = $minY
        right = $maxX
        bottom = $maxY
        width = $maxX - $minX + 1
        height = $maxY - $minY + 1
      }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}

function Run-BrowserCapture([string]$Name, [string]$Url) {
  $profileRoot = Join-Path $root ("profile-private-font-woff-" + $Name)
  $appDataRoot = Join-Path $profileRoot "lightpanda"
  $outPng = Join-Path $root ("private-font-woff-" + $Name + ".png")
  $browserOut = Join-Path $root ("private-font-woff-" + $Name + ".browser.stdout.txt")
  $browserErr = Join-Path $root ("private-font-woff-" + $Name + ".browser.stderr.txt")

  Remove-Item $outPng,$browserOut,$browserErr -Force -ErrorAction SilentlyContinue
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

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$Url,"--window_width","980","--window_height","460","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $result = $null
  try {
    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
        $pngReady = $true
        break
      }
    }
    if (-not $pngReady) { throw "screenshot for $Name did not become ready" }
    $bounds = Measure-RedWidth $outPng
    $result = [ordered]@{
      pid = $browser.Id
      screenshot = $outPng
      screenshot_length = (Get-Item $outPng).Length
      bounds = $bounds
      browser_command = Get-ProcessCommandLine $browser.Id
    }
  }
  finally {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) {
      if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 100
    }
    if ($result) {
      $result["browser_gone"] = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
    }
  }
  return $result
}

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/private-woff-loaded.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "woff private font render server did not become ready" }

  $loaded = Run-BrowserCapture "loaded" "http://127.0.0.1:$port/private-woff-loaded.html"
  $missing = Run-BrowserCapture "missing" "http://127.0.0.1:$port/private-woff-missing.html"
  $widthDelta = [math]::Abs([int]$loaded.bounds.width - [int]$missing.bounds.width)
  $fontWorked = $widthDelta -ge 10
  if (-not $fontWorked) {
    throw "private woff font render probe did not observe a sufficient width delta"
  }

  [ordered]@{
    ready = $ready
    loaded = $loaded
    missing = $missing
    width_delta = $widthDelta
    font_worked = $fontWorked
  } | ConvertTo-Json -Depth 6
}
finally {
  Stop-VerifiedProcess $server.Id
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
}
