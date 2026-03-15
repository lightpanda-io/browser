$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8193
$pageUrl = "http://127.0.0.1:$port/flex-overflow-hidden.html"
$outPng = Join-Path $root "flex-overflow-hidden.png"
$browserOut = Join-Path $root "flex-overflow-hidden.browser.stdout.txt"
$browserErr = Join-Path $root "flex-overflow-hidden.browser.stderr.txt"
$serverOut = Join-Path $root "flex-overflow-hidden.server.stdout.txt"
$serverErr = Join-Path $root "flex-overflow-hidden.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-overflow-hidden"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "flex overflow hidden smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","460","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex overflow hidden screenshot did not become ready" }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 130 -and $c.R -le 90 -and $c.B -le 110 }
    $result = [ordered]@{
      blue = $blue
      green = $green
      blue_size_ok = ($blue.width -ge 140 -and $blue.width -le 142 -and $blue.height -ge 80 -and $blue.height -le 82)
      green_size_ok = ($green.width -ge 120 -and $green.width -le 122 -and $green.height -ge 24 -and $green.height -le 26)
      flow_ok = ($green.top -ge $blue.bottom + 14)
    }
    $result.flex_overflow_hidden_worked = $result.blue_size_ok -and $result.green_size_ok -and $result.flow_ok
    if (-not $result.flex_overflow_hidden_worked) { throw "flex overflow hidden probe did not observe clipped flex descendants and preserved later flow" }
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
