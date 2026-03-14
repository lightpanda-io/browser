$ErrorActionPreference = 'Stop'

$root = 'C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\canvas-smoke'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$browserExe = Join-Path $repo 'zig-out\bin\lightpanda.exe'
$serverScript = Join-Path $root 'canvas_server.py'
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try { $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port } finally { $listener.Stop() }
$pageUrl = "http://127.0.0.1:$port/webgl-indexed.html"
$outPng = Join-Path $root 'canvas-webgl-indexed.png'
$browserOut = Join-Path $root 'canvas-webgl-indexed.browser.stdout.txt'
$browserErr = Join-Path $root 'canvas-webgl-indexed.browser.stderr.txt'
$serverOut = Join-Path $root 'canvas-webgl-indexed.server.stdout.txt'
$serverErr = Join-Path $root 'canvas-webgl-indexed.server.stderr.txt'
$profileRoot = Join-Path $root 'profile-canvas-webgl-indexed'
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

$server = Start-Process -FilePath 'python' -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 250; try { $resp = Invoke-WebRequest -UseBasicParsing -Uri $pageUrl -TimeoutSec 2; if ($resp.StatusCode -eq 200) { $ready = $true; break } } catch {} }
  if (-not $ready) { throw 'canvas webgl indexed server did not become ready' }
  $env:APPDATA = $profileRoot; $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList 'browse',$pageUrl,'--window_width','420','--window_height','360','--screenshot_png',$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $titleReady = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 250
      $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
      if ($proc -and $proc.MainWindowHandle -ne 0) {
        $title = $proc.MainWindowTitle
        if ($title -like '*Canvas WebGL Indexed Ready*') { $titleReady = $true; break }
      }
    }
    if (-not $titleReady) { throw 'webgl indexed page did not reach the ready title' }

    $pngReady = $false
    for ($i = 0; $i -lt 80; $i++) { Start-Sleep -Milliseconds 250; if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break } }
    if (-not $pngReady) { throw 'canvas webgl indexed screenshot did not become ready' }

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $blueCount = 0
      $whiteCount = 0
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          if (($c.R -le 40) -and ($c.G -le 40) -and ([math]::Abs($c.B - 255) -le 20)) { $blueCount++ }
          if (([math]::Abs($c.R - 255) -le 20) -and ([math]::Abs($c.G - 255) -le 20) -and ([math]::Abs($c.B - 255) -le 20)) { $whiteCount++ }
        }
      }
      $result = [ordered]@{
        blue_count = $blueCount
        white_count = $whiteCount
        title_ready = $titleReady
        indexed_worked = $titleReady -and ($blueCount -gt 200) -and ($whiteCount -gt 2000)
      }
      if (-not $result.indexed_worked) { throw 'webgl indexed pixels were not observed in screenshot' }
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
