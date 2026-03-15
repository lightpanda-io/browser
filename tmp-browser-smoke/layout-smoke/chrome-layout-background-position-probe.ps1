$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

function Find-ColorBoundsInRegion($Path, [scriptblock]$Predicate, [int]$MinX, [int]$MinY, [int]$MaxX, [int]$MaxY) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($Path)
  try {
    $minFoundX = $bmp.Width
    $minFoundY = $bmp.Height
    $maxFoundX = -1
    $maxFoundY = -1
    $endX = [Math]::Min($MaxX, $bmp.Width - 1)
    $endY = [Math]::Min($MaxY, $bmp.Height - 1)
    for ($y = [Math]::Max(0, $MinY); $y -le $endY; $y++) {
      for ($x = [Math]::Max(0, $MinX); $x -le $endX; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if (& $Predicate $c) {
          if ($x -lt $minFoundX) { $minFoundX = $x }
          if ($y -lt $minFoundY) { $minFoundY = $y }
          if ($x -gt $maxFoundX) { $maxFoundX = $x }
          if ($y -gt $maxFoundY) { $maxFoundY = $y }
        }
      }
    }
    if ($maxFoundX -lt 0 -or $maxFoundY -lt 0) {
      throw "target color not found in region for $Path"
    }
    return [ordered]@{ left=$minFoundX; top=$minFoundY; right=$maxFoundX; bottom=$maxFoundY; width=$maxFoundX-$minFoundX+1; height=$maxFoundY-$minFoundY+1 }
  }
  finally { $bmp.Dispose() }
}

$port = 8189
$pageUrl = "http://127.0.0.1:$port/background-position.html"
$outPng = Join-Path $root "background-position.png"
$browserOut = Join-Path $root "background-position.browser.stdout.txt"
$browserErr = Join-Path $root "background-position.browser.stderr.txt"
$serverOut = Join-Path $root "background-position.server.stdout.txt"
$serverErr = Join-Path $root "background-position.server.stderr.txt"
$profileRoot = Join-Path $root "profile-background-position"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","640","--window_height","700","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "background position screenshot did not become ready" }
    $predicate = { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $percent = Find-ColorBoundsInRegion $outPng $predicate 160 120 360 280
    $center = Find-ColorBoundsInRegion $outPng $predicate 220 280 420 460
    $end = Find-ColorBoundsInRegion $outPng $predicate 320 460 520 660
    $result = [ordered]@{
      percent = $percent
      center = $center
      end = $end
      widths_ok = ($percent.width -ge 40 -and $percent.width -le 42 -and $center.width -ge 40 -and $center.width -le 42 -and $end.width -ge 40 -and $end.width -le 42)
      heights_ok = ($percent.height -ge 80 -and $percent.height -le 82 -and $center.height -ge 80 -and $center.height -le 82 -and $end.height -ge 80 -and $end.height -le 82)
      x_order_ok = ($percent.left + 30 -le $center.left) -and ($center.left + 50 -le $end.left)
      y_order_ok = ($center.top -ge $percent.top + 120) -and ($end.top -ge $center.top + 120)
    }
    $result.background_position_worked = $result.widths_ok -and $result.heights_ok -and $result.x_order_ok -and $result.y_order_ok
    if (-not $result.background_position_worked) { throw "background position probe did not observe percent, center, and end alignment differences" }
    $result | ConvertTo-Json -Depth 6
  }
  finally {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
  }
}
finally {
  Stop-VerifiedProcess $server.Id
  for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
}
