$ErrorActionPreference = 'Stop'

$root = 'C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\canvas-smoke'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$browserExe = Join-Path $repo 'zig-out\bin\lightpanda.exe'
$serverScript = Join-Path $root 'canvas_server.py'
$port = 8170
$pageUrl = "http://127.0.0.1:$port/webgl-clear.html"
$outPng = Join-Path $root 'canvas-webgl-clear.png'
$browserOut = Join-Path $root 'canvas-webgl-clear.browser.stdout.txt'
$browserErr = Join-Path $root 'canvas-webgl-clear.browser.stderr.txt'
$serverOut = Join-Path $root 'canvas-webgl-clear.server.stdout.txt'
$serverErr = Join-Path $root 'canvas-webgl-clear.server.stderr.txt'
$profileRoot = Join-Path $root 'profile-canvas-webgl-clear'
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

function Get-ProcessCommandLine($TargetPid) { $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue | Select-Object Name,ProcessId,CommandLine,CreationDate; if ($meta) { return [string]$meta.CommandLine }; return '' }
function Stop-VerifiedProcess($TargetPid) { $cmd = Get-ProcessCommandLine $TargetPid; if ($cmd -and $cmd -notmatch 'codex\.js|@openai/codex') { try { Stop-Process -Id $TargetPid -Force -ErrorAction Stop } catch { if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) { throw } } } }
function Test-ApproxColor($Pixel, [int]$R, [int]$G, [int]$B, [int]$Tolerance) { return ([math]::Abs($Pixel.R - $R) -le $Tolerance) -and ([math]::Abs($Pixel.G - $G) -le $Tolerance) -and ([math]::Abs($Pixel.B - $B) -le $Tolerance) }

$server = Start-Process -FilePath 'python' -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -TimeoutSec 2; if ($resp.StatusCode -eq 200) { $ready = $true; break } } catch {} }
  if (-not $ready) { throw 'canvas webgl smoke server did not become ready' }
  $env:APPDATA = $profileRoot; $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList 'browse',$pageUrl,'--window_width','420','--window_height','360','--screenshot_png',$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 250; if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break } }
    if (-not $pngReady) { throw 'canvas webgl screenshot did not become ready' }
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1; $count = 0
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          if (([math]::Abs($c.R - 64) -le 20) -and ([math]::Abs($c.G - 128) -le 20) -and ([math]::Abs($c.B - 191) -le 20)) {
            $count++
            if ($x -lt $minX) { $minX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -gt $maxY) { $maxY = $y }
          }
        }
      }
      if ($count -le 0) { throw 'webgl clear color not found in screenshot' }
      $width = $maxX - $minX + 1
      $height = $maxY - $minY + 1
      $result = [ordered]@{
        count = $count; left = $minX; top = $minY; width = $width; height = $height;
        size_worked = ($width -eq 120) -and ($height -eq 80);
        webgl_clear_worked = ($count -ge 8000) -and ($width -eq 120) -and ($height -eq 80)
      }
      if (-not $result.webgl_clear_worked) { throw 'webgl clear region not observed at expected size' }
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
