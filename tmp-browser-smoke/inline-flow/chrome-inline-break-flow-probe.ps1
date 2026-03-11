$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\inline-flow"
$port = 8140
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$outPng = Join-Path $root "break-flow.png"
$browserOut = Join-Path $root "break.browser.stdout.txt"
$browserErr = Join-Path $root "break.browser.stderr.txt"
$serverOut = Join-Path $root "break.server.stdout.txt"
$serverErr = Join-Path $root "break.server.stderr.txt"
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

function Add-Pixel($o, $x, $y) {
  if ($null -eq $o.min_x -or $x -lt $o.min_x) { $o.min_x = $x }
  if ($null -eq $o.min_y -or $y -lt $o.min_y) { $o.min_y = $y }
  if ($null -eq $o.max_x -or $x -gt $o.max_x) { $o.max_x = $x }
  if ($null -eq $o.max_y -or $y -gt $o.max_y) { $o.max_y = $y }
  $o.count++
}

function Count-BlackInBand($bmp, $maxX, $minY, $maxY) {
  $count = 0
  for ($y = $minY; $y -le $maxY; $y++) {
    for ($x = 0; $x -lt $maxX; $x++) {
      $c = $bmp.GetPixel($x, $y)
      if ($c.R -le 70 -and $c.G -le 70 -and $c.B -le 70) { $count++ }
    }
  }
  return $count
}

$server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/break.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "break inline probe server did not become ready" }

  $profileRoot = Join-Path $root "profile-inline-break"
  $appDataRoot = Join-Path $profileRoot "lightpanda"
  cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/break.html","--window_width","760","--window_height","460","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $pngReady = $false
    for ($i = 0; $i -lt 60; $i++) {
      Start-Sleep -Milliseconds 250
      if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
    }
    if (-not $pngReady) { throw "break inline screenshot did not become ready" }

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $red = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      $green = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      $blue = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
      for ($y = 0; $y -lt $bmp.Height; $y++) {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
          $c = $bmp.GetPixel($x, $y)
          if ($c.R -ge 170 -and $c.G -le 90 -and $c.B -le 90) { Add-Pixel $red $x $y }
          if ($c.G -ge 120 -and $c.R -le 90 -and $c.B -le 110) { Add-Pixel $green $x $y }
          if ($c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120) { Add-Pixel $blue $x $y }
        }
      }
      if ($null -eq $red.min_y -or $null -eq $green.min_y) { throw "break inline probe did not find the red and green chips" }

      $firstRowBlack = Count-BlackInBand $bmp $red.min_x ([Math]::Max(0, $red.min_y - 8)) ([Math]::Min($bmp.Height - 1, $red.max_y + 4))
      $secondRowBlack = Count-BlackInBand $bmp $green.min_x ([Math]::Max(0, $green.min_y - 8)) ([Math]::Min($bmp.Height - 1, $green.max_y + 4))
      $belowBlack = Count-BlackInBand $bmp $bmp.Width ([Math]::Min($bmp.Height - 1, $green.max_y + 22)) ([Math]::Min($bmp.Height - 1, $green.max_y + 54))

      $breakWorked = $green.min_y -gt ($red.min_y + 24)
      $firstRowWorked = $firstRowBlack -ge 20
      $secondRowWorked = $secondRowBlack -ge 20
      $belowWorked = $belowBlack -ge 20
      if (-not $breakWorked) { throw "break inline probe did not observe a lower row after br" }
      if (-not $firstRowWorked) { throw "break inline probe did not observe direct text on the first row" }
      if (-not $secondRowWorked) { throw "break inline probe did not observe direct text on the second row" }
      if (-not $belowWorked) { throw "break inline probe did not observe the following paragraph below the break content" }

      [ordered]@{
        ready = $true
        red = $red
        green = $green
        break_worked = $breakWorked
        first_row_black = $firstRowBlack
        second_row_black = $secondRowBlack
        below_black = $belowBlack
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
