$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8177
$pageUrl = "http://127.0.0.1:$port/flex-center.html"
$outPng = Join-Path $root "flex-center.png"
$browserOut = Join-Path $root "flex-center.browser.stdout.txt"
$browserErr = Join-Path $root "flex-center.browser.stderr.txt"
$serverOut = Join-Path $root "flex-center.server.stdout.txt"
$serverErr = Join-Path $root "flex-center.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-center"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","960","--window_height","720","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex center screenshot did not become ready" }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    $redCenterX = ($red.left + $red.right) / 2.0
    $blueCenterX = ($blue.left + $blue.right) / 2.0
    $redCenterY = ($red.top + $red.bottom) / 2.0
    $blueCenterY = ($blue.top + $blue.bottom) / 2.0
    $result = [ordered]@{
      red = $red
      blue = $blue
      red_center_x = $redCenterX
      blue_center_x = $blueCenterX
      red_center_y = $redCenterY
      blue_center_y = $blueCenterY
      flex_center_worked = ([math]::Abs($redCenterX - 480) -le 80) -and
                           ([math]::Abs($blueCenterX - 480) -le 80) -and
                           ($redCenterY -gt 120) -and
                           ($blueCenterY -gt ($redCenterY + 40))
    }
    if (-not $result.flex_center_worked) {
      throw "flex center probe did not observe centered hero blocks"
    }
    $result | ConvertTo-Json -Depth 6
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
