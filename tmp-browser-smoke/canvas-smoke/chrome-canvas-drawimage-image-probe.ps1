$ErrorActionPreference = 'Stop'

$root = 'C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\canvas-smoke'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$browserExe = Join-Path $repo 'zig-out\bin\lightpanda.exe'
$serverScript = Join-Path $root 'canvas_server.py'
$port = 8168
$pageUrl = "http://127.0.0.1:$port/drawimage-image.html"
$outPng = Join-Path $root 'canvas-drawimage-image.png'
$browserOut = Join-Path $root 'canvas-drawimage-image.browser.stdout.txt'
$browserErr = Join-Path $root 'canvas-drawimage-image.browser.stderr.txt'
$serverOut = Join-Path $root 'canvas-drawimage-image.server.stdout.txt'
$serverErr = Join-Path $root 'canvas-drawimage-image.server.stderr.txt'
$profileRoot = Join-Path $root 'profile-canvas-drawimage-image'
$appDataRoot = Join-Path $profileRoot 'lightpanda'

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot 'browse-settings-v1.txt') -NoNewline

function Get-ProcessCommandLine($TargetPid) {
  $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue | Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($meta) { return [string]$meta.CommandLine }
  return ''
}
function Stop-VerifiedProcess($TargetPid) {
  $cmd = Get-ProcessCommandLine $TargetPid
  if ($cmd -and $cmd -notmatch 'codex\.js|@openai/codex') {
    try { Stop-Process -Id $TargetPid -Force -ErrorAction Stop } catch { if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) { throw } }
  }
}
function Read-Pixel($Bitmap, [int]$X, [int]$Y) {
  $c = $Bitmap.GetPixel($X, $Y)
  return [ordered]@{ r=[int]$c.R; g=[int]$c.G; b=[int]$c.B; a=[int]$c.A }
}
function Test-ApproxColor($Pixel, [int]$R, [int]$G, [int]$B, [int]$Tolerance) {
  return ([math]::Abs($Pixel.r - $R) -le $Tolerance) -and ([math]::Abs($Pixel.g - $G) -le $Tolerance) -and ([math]::Abs($Pixel.b - $B) -le $Tolerance)
}
function Find-MagentaBounds($Path) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1
        for ($y = 0; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -ge 220 -and $c.G -le 40 -and $c.B -ge 220) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minY) { $minY = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
        if ($maxX -lt 0 -or $maxY -lt 0) { throw 'magenta border not found' }
        return [ordered]@{ left=$minX; top=$minY; width=$maxX-$minX+1; height=$maxY-$minY+1 }
      } finally { $bmp.Dispose() }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}

$server = Start-Process -FilePath 'python' -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -TimeoutSec 2; if ($resp.StatusCode -eq 200) { $ready = $true; break } } catch {}
  }
  if (-not $ready) { throw 'drawImage(image) smoke server did not become ready' }
  $env:APPDATA = $profileRoot; $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList 'browse',$pageUrl,'--window_width','420','--window_height','360','--screenshot_png',$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
    }
    if (-not $pngReady) { throw 'drawImage(image) screenshot did not become ready' }
    Add-Type -AssemblyName System.Drawing
    $bounds = Find-MagentaBounds $outPng
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $red = Read-Pixel $bmp ($bounds.left + 12) ($bounds.top + 12)
      $blue = Read-Pixel $bmp ($bounds.left + 75) ($bounds.top + 25)
      $result = [ordered]@{
        width = $bounds.width; height = $bounds.height; red = $red; blue = $blue;
        size_worked = ($bounds.width -eq 120) -and ($bounds.height -eq 80);
        red_worked = Test-ApproxColor $red 255 0 0 24;
        blue_worked = Test-ApproxColor $blue 0 0 255 24;
      }
      $result.drawimage_image_worked = $result.size_worked -and $result.red_worked -and $result.blue_worked
      if (-not $result.drawimage_image_worked) { throw 'drawImage(image) pixels not observed on headed surface' }
      $result | ConvertTo-Json -Depth 5
    } finally { $bmp.Dispose() }
  } finally {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
  }
} finally {
  Stop-VerifiedProcess $server.Id
  for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
}
