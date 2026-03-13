$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\canvas-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "canvas_server.py"
$port = 8333
$pageUrl = "http://127.0.0.1:$port/measuretext.html"
$outPng = Join-Path $root "canvas-measuretext.png"
$browserOut = Join-Path $root "canvas-measuretext.browser.stdout.txt"
$browserErr = Join-Path $root "canvas-measuretext.browser.stderr.txt"
$serverOut = Join-Path $root "canvas-measuretext.server.stdout.txt"
$serverErr = Join-Path $root "canvas-measuretext.server.stderr.txt"
$profileRoot = Join-Path $root "profile-canvas-measuretext"
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

function Get-MaxBarWidth($Bitmap, [scriptblock]$MatchPixel) {
  $best = 0
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    $first = -1
    $last = -1
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      $c = $Bitmap.GetPixel($x, $y)
      if (& $MatchPixel $c) {
        if ($first -lt 0) { $first = $x }
        $last = $x
      }
    }
    if ($first -ge 0 -and $last -ge 0) {
      $width = $last - $first + 1
      if ($width -gt $best) { $best = $width }
    }
  }
  return $best
}

function Measure-Bars($Path) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($Path)
  try {
    $redWidth = Get-MaxBarWidth $bmp { param($c) $c.R -gt 180 -and $c.G -lt 80 -and $c.B -lt 80 }
    $blueWidth = Get-MaxBarWidth $bmp { param($c) $c.R -lt 80 -and $c.G -lt 80 -and $c.B -gt 180 }
    return [ordered]@{
      red_width = $redWidth
      blue_width = $blueWidth
      width_delta = [Math]::Abs($redWidth - $blueWidth)
      measuretext_worked = [Math]::Abs($redWidth - $blueWidth) -gt 20
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
  if (-not $ready) { throw "canvas measureText server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","560","--window_height","320","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
        $pngReady = $true
        break
      }
    }
    if (-not $pngReady) { throw "canvas measureText screenshot did not become ready" }

    $counts = Measure-Bars $outPng
    $counts["ready"] = $ready
    $counts["screenshot_length"] = (Get-Item $outPng).Length
    if (-not $counts.measuretext_worked) {
      throw "canvas measureText probe did not observe distinct bar widths"
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
