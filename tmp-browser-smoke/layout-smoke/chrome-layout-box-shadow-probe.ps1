$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8231
$pageUrl = "http://127.0.0.1:$port/box-shadow.html"
$outPng = Join-Path $root "box-shadow.png"
$browserOut = Join-Path $root "box-shadow.browser.stdout.txt"
$browserErr = Join-Path $root "box-shadow.browser.stderr.txt"
$serverOut = Join-Path $root "box-shadow.server.stdout.txt"
$serverErr = Join-Path $root "box-shadow.server.stderr.txt"
$profileRoot = Join-Path $root "profile-box-shadow"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "box shadow smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","320","--window_height","220","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "box shadow screenshot did not become ready" }

    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $shadowPixel = Read-Pixel $bmp 200 170
      $shadowEdgePixel = Read-Pixel $bmp 210 180

      $result = [ordered]@{
        shadow_pixel = $shadowPixel
        shadow_edge_pixel = $shadowEdgePixel
        shadow_pixel_dark = ($shadowPixel.r -lt 240 -and $shadowPixel.g -lt 240 -and $shadowPixel.b -lt 240)
        shadow_edge_dark = ($shadowEdgePixel.r -lt 240 -and $shadowEdgePixel.g -lt 240 -and $shadowEdgePixel.b -lt 240)
        shadow_visible = ($shadowPixel.r -lt 240 -and $shadowEdgePixel.r -lt 240)
      }
      $result.box_shadow_worked = $result.shadow_pixel_dark -and $result.shadow_visible
      if (-not $result.box_shadow_worked) {
        throw "box shadow probe did not observe the expected offset shadow"
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
