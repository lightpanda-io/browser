$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\flow-layout"
$port = 8137
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "flow-layout.png"
$browserOut = Join-Path $root "browser.stdout.txt"
$browserErr = Join-Path $root "browser.stderr.txt"
$serverOut = Join-Path $root "server.stdout.txt"
$serverErr = Join-Path $root "server.stderr.txt"
Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
  Start-Sleep -Milliseconds 250
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) { throw "localhost probe server did not become ready" }
$browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--screenshot_png",$outPng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
$pngReady = $false
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Milliseconds 250
  if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
}
$analysis = $null
if ($pngReady) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $red = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    $green = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90) {
          if ($null -eq $red.min_x -or $x -lt $red.min_x) { $red.min_x = $x }
          if ($null -eq $red.min_y -or $y -lt $red.min_y) { $red.min_y = $y }
          if ($null -eq $red.max_x -or $x -gt $red.max_x) { $red.max_x = $x }
          if ($null -eq $red.max_y -or $y -gt $red.max_y) { $red.max_y = $y }
          $red.count++
        }
        if ($c.G -ge 100 -and $c.R -le 120 -and $c.B -le 120) {
          if ($null -eq $green.min_x -or $x -lt $green.min_x) { $green.min_x = $x }
          if ($null -eq $green.min_y -or $y -lt $green.min_y) { $green.min_y = $y }
          if ($null -eq $green.max_x -or $x -gt $green.max_x) { $green.max_x = $x }
          if ($null -eq $green.max_y -or $y -gt $green.max_y) { $green.max_y = $y }
          $green.count++
        }
      }
    }
    $analysis = [ordered]@{
      width = $bmp.Width
      height = $bmp.Height
      red = $red
      green = $green
      vertical_gap = if ($null -ne $red.max_y -and $null -ne $green.min_y) { $green.min_y - $red.max_y - 1 } else { $null }
      green_below_red = if ($null -ne $red.max_y -and $null -ne $green.min_y) { $green.min_y -gt $red.max_y } else { $false }
    }
  } finally {
    $bmp.Dispose()
  }
}
$serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
$browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force }
if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force }
$browserGone = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
$serverGone = -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)
[ordered]@{
  server_pid = $server.Id
  browser_pid = $browser.Id
  ready = $ready
  screenshot_ready = $pngReady
  screenshot_path = $outPng
  screenshot_length = if (Test-Path $outPng) { (Get-Item $outPng).Length } else { 0 }
  analysis = $analysis
  server_meta = $serverMeta
  browser_meta = $browserMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
