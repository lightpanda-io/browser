$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
$tabCommon = Join-Path $repo "tmp-browser-smoke\tabs\TabProbeCommon.ps1"
. $common
. $tabCommon

function Find-ColorBoundsBelowY($Path, [int]$MinY, [scriptblock]$Predicate) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width
        $minYFound = $bmp.Height
        $maxX = -1
        $maxY = -1
        for ($y = $MinY; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if (& $Predicate $c) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minYFound) { $minYFound = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
        if ($maxX -lt 0 -or $maxY -lt 0) {
          throw "target color not found in $Path"
        }
        return [ordered]@{
          left = $minX
          top = $minYFound
          right = $maxX
          bottom = $maxY
          width = $maxX - $minX + 1
          height = $maxY - $minY + 1
        }
      }
      finally {
        $bmp.Dispose()
      }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}

$port = 8202
$pageUrl = "http://127.0.0.1:$port/flex-shrink.html"
$outPng = Join-Path $root "flex-shrink.png"
$browserOut = Join-Path $root "flex-shrink.browser.stdout.txt"
$browserErr = Join-Path $root "flex-shrink.browser.stderr.txt"
$serverOut = Join-Path $root "flex-shrink.server.stdout.txt"
$serverErr = Join-Path $root "flex-shrink.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-shrink"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "flex shrink smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","480","--window_height","240","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex shrink screenshot did not become ready" }
    $red = Find-ColorBoundsBelowY $outPng 120 { param($c) $c.R -ge 180 -and $c.G -le 100 -and $c.B -le 100 }
    $gray = Find-ColorBoundsBelowY $outPng 120 { param($c) $c.R -ge 130 -and $c.R -le 190 -and $c.G -ge 130 -and $c.G -le 190 -and $c.B -ge 130 -and $c.B -le 190 }
    $blue = Find-ColorBoundsBelowY $outPng 120 { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    $result = [ordered]@{
      red = $red
      gray = $gray
      blue = $blue
      red_width = $red.width
      gray_width = $gray.width
      blue_width = $blue.width
      red_visible = ($red.width -eq 120)
      shrink_visible = ($gray.width -eq 90) -and ($blue.width -eq 90)
    }
    $result.flex_shrink_worked = $result.red_visible -and $result.shrink_visible
    if (-not $result.flex_shrink_worked) { throw "flex shrink probe did not observe the expected width reduction" }
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
