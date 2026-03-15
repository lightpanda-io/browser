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

$port = 8191
$pageUrl = "http://127.0.0.1:$port/background-size.html"
$outPng = Join-Path $root "background-size.png"
$browserOut = Join-Path $root "background-size.browser.stdout.txt"
$browserErr = Join-Path $root "background-size.browser.stderr.txt"
$serverOut = Join-Path $root "background-size.server.stdout.txt"
$serverErr = Join-Path $root "background-size.server.stderr.txt"
$profileRoot = Join-Path $root "profile-background-size"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","640","--window_height","860","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "background size screenshot did not become ready" }
    $predicate = { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $contain = Find-ColorBoundsInRegion $outPng $predicate 220 120 420 280
    $cover = Find-ColorBoundsInRegion $outPng $predicate 160 280 500 460
    $explicit = Find-ColorBoundsInRegion $outPng $predicate 220 450 420 620
    $percent = Find-ColorBoundsInRegion $outPng $predicate 180 620 460 820
    $result = [ordered]@{
      contain = $contain
      cover = $cover
      explicit = $explicit
      percent = $percent
      contain_ok = ($contain.width -ge 59 -and $contain.width -le 61 -and $contain.height -ge 119 -and $contain.height -le 121)
      cover_ok = ($cover.width -ge 236 -and $cover.width -le 240 -and $cover.height -ge 119 -and $cover.height -le 121)
      explicit_ok = ($explicit.width -ge 79 -and $explicit.width -le 81 -and $explicit.height -ge 119 -and $explicit.height -le 121)
      percent_ok = ($percent.width -ge 176 -and $percent.width -le 179 -and $percent.height -ge 119 -and $percent.height -le 121)
    }
    $result.background_size_worked = $result.contain_ok -and $result.cover_ok -and $result.explicit_ok -and $result.percent_ok
    if (-not $result.background_size_worked) { throw "background size probe did not observe contain, cover, explicit, and percent sizing differences" }
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
