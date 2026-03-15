$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8182
$pageUrl = "http://127.0.0.1:$port/fixed-position.html"
$outPng = Join-Path $root "fixed-position.png"
$browserOut = Join-Path $root "fixed-position.browser.stdout.txt"
$browserErr = Join-Path $root "fixed-position.browser.stderr.txt"
$serverOut = Join-Path $root "fixed-position.server.stdout.txt"
$serverErr = Join-Path $root "fixed-position.server.stderr.txt"
$profileRoot = Join-Path $root "profile-fixed-position"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","960","--window_height","720","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "fixed position screenshot did not become ready" }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 140 -and $c.R -le 100 -and $c.B -le 140 }
    $result = [ordered]@{
      red = $red
      blue = $blue
      green = $green
      fixed_position_worked = ($red.left -le 50) -and
                               ($red.top -le 180) -and
                               ($blue.right -ge 840) -and
                               ($blue.top -le 180) -and
                               ($green.top -ge 280)
    }
    if (-not $result.fixed_position_worked) {
      throw "fixed position probe did not observe viewport-anchored fixed controls and later flow content"
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
