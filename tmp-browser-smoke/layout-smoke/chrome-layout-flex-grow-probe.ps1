$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8180
$pageUrl = "http://127.0.0.1:$port/flex-grow.html"
$outPng = Join-Path $root "flex-grow.png"
$browserOut = Join-Path $root "flex-grow.browser.stdout.txt"
$browserErr = Join-Path $root "flex-grow.browser.stderr.txt"
$serverOut = Join-Path $root "flex-grow.server.stdout.txt"
$serverErr = Join-Path $root "flex-grow.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-grow"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","760","--window_height","360","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex grow screenshot did not become ready" }
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($outPng)
    try {
      $red = Read-Pixel $bmp 100 170
      $grayMid = Read-Pixel $bmp 330 176
      $grayFar = Read-Pixel $bmp 430 176
      $blue = Read-Pixel $bmp 555 170

      $result = [ordered]@{
        red = $red
        gray_mid = $grayMid
        gray_far = $grayFar
        blue = $blue
        red_visible = Test-ApproxColor $red 220 50 50 25
        gray_expanded = (Test-ApproxColor $grayMid 160 160 160 25) -and (Test-ApproxColor $grayFar 160 160 160 25)
        blue_visible = Test-ApproxColor $blue 40 110 220 30
      }
      $result.flex_grow_worked = $result.red_visible -and $result.gray_expanded -and $result.blue_visible
      if (-not $result.flex_grow_worked) {
        throw "flex grow probe did not observe an expanded middle item with docked siblings"
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
