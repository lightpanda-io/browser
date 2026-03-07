$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\inline-flow"
$port = 8138
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "inline-flow.png"
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
    function New-Bounds {
      [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    }
    function Add-Pixel($o, $x, $y) {
      if ($null -eq $o.min_x -or $x -lt $o.min_x) { $o.min_x = $x }
      if ($null -eq $o.min_y -or $y -lt $o.min_y) { $o.min_y = $y }
      if ($null -eq $o.max_x -or $x -gt $o.max_x) { $o.max_x = $x }
      if ($null -eq $o.max_y -or $y -gt $o.max_y) { $o.max_y = $y }
      $o.count++
    }

    $colors = [ordered]@{
      red = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      green = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      blue = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
    }
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 170 -and $c.G -le 90 -and $c.B -le 90) {
          Add-Pixel $colors.red $x $y
        }
        if ($c.G -ge 120 -and $c.R -le 80 -and $c.B -le 110) {
          Add-Pixel $colors.green $x $y
        }
        if ($c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120) {
          Add-Pixel $colors.blue $x $y
        }
      }
    }

    $chipColors = [ordered]@{
      red = $colors.red
      green = $colors.green
      blue = New-Bounds
    }
    if ($null -ne $colors.red.min_y) {
      $bandMin = [Math]::Max(0, $colors.red.min_y - 8)
      $bandMax = [Math]::Min($bmp.Height - 1, $colors.red.max_y + 8)
      for ($y = $bandMin; $y -le $bandMax; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          if ($c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120) {
            Add-Pixel $chipColors.blue $x $y
          }
        }
      }
    }

    $analysis = [ordered]@{
      width = $bmp.Width
      height = $bmp.Height
      colors = $colors
      chip_colors = $chipColors
      same_line = if ($null -ne $chipColors.red.min_y -and $null -ne $chipColors.green.min_y -and $null -ne $chipColors.blue.min_y) {
        ([math]::Abs($chipColors.red.min_y - $chipColors.green.min_y) -le 4) -and ([math]::Abs($chipColors.red.min_y - $chipColors.blue.min_y) -le 4)
      } else { $false }
      ordered_left_to_right = if ($null -ne $chipColors.red.max_x -and $null -ne $chipColors.green.min_x -and $null -ne $chipColors.green.max_x -and $null -ne $chipColors.blue.min_x) {
        ($chipColors.red.max_x -lt $chipColors.green.min_x) -and ($chipColors.green.max_x -lt $chipColors.blue.min_x)
      } else { $false }
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
} | ConvertTo-Json -Depth 7
