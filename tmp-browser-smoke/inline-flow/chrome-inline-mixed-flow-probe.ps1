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

$server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
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
  try {
    $pngReady = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
    }
    if (-not $pngReady) { throw "inline flow screenshot did not become ready" }

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $red = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      function Add-Pixel($o, $x, $y) {
        if ($null -eq $o.min_x -or $x -lt $o.min_x) { $o.min_x = $x }
        if ($null -eq $o.min_y -or $y -lt $o.min_y) { $o.min_y = $y }
        if ($null -eq $o.max_x -or $x -gt $o.max_x) { $o.max_x = $x }
        if ($null -eq $o.max_y -or $y -gt $o.max_y) { $o.max_y = $y }
        $o.count++
      }
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          if ($c.R -ge 170 -and $c.G -le 90 -and $c.B -le 90) {
            Add-Pixel $red $x $y
          }
        }
      }
      if ($null -eq $red.min_y) { throw "red chip not found" }

      $sameLineBlack = 0
      $aboveBlack = 0
      $bandMin = [Math]::Max(0, $red.min_y - 8)
      $bandMax = [Math]::Min($bmp.Height - 1, $red.max_y + 4)
      $aboveMin = [Math]::Max(0, $red.min_y - 28)
      $aboveMax = [Math]::Max(0, $red.min_y - 8)
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $red.min_x; $x++) {
          $c = $bmp.GetPixel($x, $y)
          $isBlack = ($c.R -le 70 -and $c.G -le 70 -and $c.B -le 70)
          if (-not $isBlack) { continue }
          if ($y -ge $bandMin -and $y -le $bandMax) { $sameLineBlack++ }
          if ($y -ge $aboveMin -and $y -le $aboveMax) { $aboveBlack++ }
        }
      }

      $sameLineWorked = $sameLineBlack -ge 20
      $noDuplicateAbove = $aboveBlack -le 10
      if (-not $sameLineWorked) { throw "mixed inline probe did not observe left-side text on the chip row" }
      if (-not $noDuplicateAbove) { throw "mixed inline probe still observed a duplicate text band above the chips" }

      [ordered]@{
        ready = $true
        red = $red
        same_line_black = $sameLineBlack
        above_black = $aboveBlack
        same_line_worked = $sameLineWorked
        no_duplicate_above = $noDuplicateAbove
      } | ConvertTo-Json -Depth 5
    }
    finally {
      $bmp.Dispose()
    }
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
