$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8187
$pageUrl = "http://127.0.0.1:$port/border-radius.html"
$outPng = Join-Path $root "border-radius.png"
$browserOut = Join-Path $root "border-radius.browser.stdout.txt"
$browserErr = Join-Path $root "border-radius.browser.stderr.txt"
$serverOut = Join-Path $root "border-radius.server.stdout.txt"
$serverErr = Join-Path $root "border-radius.server.stderr.txt"
$profileRoot = Join-Path $root "profile-border-radius"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","640","--window_height","340","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "border radius screenshot did not become ready" }

    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -ge 80 -and $c.G -le 140 }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $blueCorner = Read-Pixel $bmp ($blue.left + 1) ($blue.top + 1)
      $blueInner = Read-Pixel $bmp ($blue.left + 16) ($blue.top + 16)
      $redCorner = Read-Pixel $bmp ($red.left + 1) ($red.top + 1)
      $blueCornerCleared = (Test-ApproxColor $blueCorner 255 255 255 20)
      $blueInnerFilled = (Test-ApproxColor $blueInner 61 115 230 40)
      $redCornerFilled = (Test-ApproxColor $redCorner 216 59 59 40)

      $result = [ordered]@{
        blue = $blue
        red = $red
        blue_corner = $blueCorner
        blue_inner = $blueInner
        red_corner = $redCorner
        blue_corner_cleared = $blueCornerCleared
        blue_inner_filled = $blueInnerFilled
        red_corner_filled = $redCornerFilled
      }
      $result.border_radius_worked = $result.blue_corner_cleared -and $result.blue_inner_filled -and $result.red_corner_filled
      if (-not $result.border_radius_worked) {
        throw "border radius probe did not observe rounded-vs-square corner behavior"
      }
      $result | ConvertTo-Json -Depth 6
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
