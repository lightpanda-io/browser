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

$port = 8188
$pageUrl = "http://127.0.0.1:$port/intrinsic-image.html"
$outPng = Join-Path $root "intrinsic-image.png"
$browserOut = Join-Path $root "intrinsic-image.browser.stdout.txt"
$browserErr = Join-Path $root "intrinsic-image.browser.stderr.txt"
$serverOut = Join-Path $root "intrinsic-image.server.stdout.txt"
$serverErr = Join-Path $root "intrinsic-image.server.stderr.txt"
$profileRoot = Join-Path $root "profile-intrinsic-image"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","420","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "intrinsic image screenshot did not become ready" }
    $predicate = { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $natural = Find-ColorBoundsInRegion $outPng $predicate 40 120 140 240
    $widthOnly = Find-ColorBoundsInRegion $outPng $predicate 40 220 120 300
    $heightOnly = Find-ColorBoundsInRegion $outPng $predicate 40 290 120 360
    $result = [ordered]@{
      natural = $natural
      width_only = $widthOnly
      height_only = $heightOnly
      natural_size_ok = ($natural.width -ge 40 -and $natural.width -le 42 -and $natural.height -ge 80 -and $natural.height -le 82)
      width_only_size_ok = ($widthOnly.width -ge 20 -and $widthOnly.width -le 22 -and $widthOnly.height -ge 40 -and $widthOnly.height -le 42)
      height_only_size_ok = ($heightOnly.width -ge 20 -and $heightOnly.width -le 22 -and $heightOnly.height -ge 40 -and $heightOnly.height -le 42)
    }
    $result.intrinsic_image_worked = $result.natural_size_ok -and $result.width_only_size_ok -and $result.height_only_size_ok
    if (-not $result.intrinsic_image_worked) { throw "intrinsic image probe did not observe natural and aspect-ratio-scaled image boxes" }
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
