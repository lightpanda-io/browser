$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8194
$pageUrl = "http://127.0.0.1:$port/min-max-height.html"
$outPng = Join-Path $root "min-max-height.png"
$browserOut = Join-Path $root "min-max-height.browser.stdout.txt"
$browserErr = Join-Path $root "min-max-height.browser.stderr.txt"
$serverOut = Join-Path $root "min-max-height.server.stdout.txt"
$serverErr = Join-Path $root "min-max-height.server.stderr.txt"
$profileRoot = Join-Path $root "profile-min-max-height"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "min max height smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","460","--window_height","560","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "min max height screenshot did not become ready" }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 100 -and $c.B -le 100 }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 130 -and $c.R -le 90 -and $c.B -le 110 }
    $result = [ordered]@{
      red = $red
      blue = $blue
      green = $green
      min_height_ok = ($red.width -ge 120 -and $red.width -le 122 -and $red.height -ge 90 -and $red.height -le 92)
      max_height_ok = ($blue.width -ge 120 -and $blue.width -le 122 -and $blue.height -ge 80 -and $blue.height -le 82)
      flow_ok = ($green.top -ge $blue.bottom + 14)
    }
    $result.min_max_height_worked = $result.min_height_ok -and $result.max_height_ok -and $result.flow_ok
    if (-not $result.min_max_height_worked) { throw "min max height probe did not observe generic block min-height and max-height behavior" }
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
