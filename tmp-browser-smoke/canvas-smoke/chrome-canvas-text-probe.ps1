$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\canvas-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "canvas_server.py"
$port = 8332
$pageUrl = "http://127.0.0.1:$port/text.html"
$outPng = Join-Path $root "canvas-text.png"
$browserOut = Join-Path $root "canvas-text.browser.stdout.txt"
$browserErr = Join-Path $root "canvas-text.browser.stderr.txt"
$serverOut = Join-Path $root "canvas-text.server.stdout.txt"
$serverErr = Join-Path $root "canvas-text.server.stderr.txt"
$profileRoot = Join-Path $root "profile-canvas-text"
$appDataRoot = Join-Path $profileRoot "lightpanda"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null

@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline

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

function Count-TextPixels($Path) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($Path)
  try {
    $red = 0
    $blue = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -gt 160 -and $c.G -lt 90 -and $c.B -lt 90) { $red++ }
        if ($c.R -lt 90 -and $c.G -lt 90 -and $c.B -gt 120) { $blue++ }
      }
    }
    return [ordered]@{
      red_pixels = $red
      blue_pixels = $blue
      text_worked = ($red -gt 40) -and ($blue -gt 40)
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
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "canvas text server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","480","--window_height","360","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
        $pngReady = $true
        break
      }
    }
    if (-not $pngReady) { throw "canvas text screenshot did not become ready" }

    $counts = Count-TextPixels $outPng
    $counts["ready"] = $ready
    $counts["screenshot_length"] = (Get-Item $outPng).Length
    if (-not $counts.text_worked) {
      throw "canvas text probe did not observe expected screenshot pixels"
    }
    $counts | ConvertTo-Json -Depth 5
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
