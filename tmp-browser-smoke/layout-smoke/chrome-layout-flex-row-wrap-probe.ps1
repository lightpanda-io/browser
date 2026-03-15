$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8179
$pageUrl = "http://127.0.0.1:$port/flex-row-wrap.html"
$outPng = Join-Path $root "flex-row-wrap.png"
$browserOut = Join-Path $root "flex-row-wrap.browser.stdout.txt"
$browserErr = Join-Path $root "flex-row-wrap.browser.stderr.txt"
$serverOut = Join-Path $root "flex-row-wrap.server.stdout.txt"
$serverErr = Join-Path $root "flex-row-wrap.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-row-wrap"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","420","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex row wrap screenshot did not become ready" }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 140 -and $c.R -le 100 -and $c.B -le 140 }
    $result = [ordered]@{
      red = $red
      blue = $blue
      green = $green
      same_row = ([math]::Abs($red.top - $blue.top) -le 6)
      wrapped = ($green.top -ge ($red.bottom + 8))
      centered = ($green.left -ge 120) -and ($green.left -le 220)
    }
    $result.flex_row_wrap_worked = $result.same_row -and $result.wrapped -and $result.centered
    if (-not $result.flex_row_wrap_worked) {
      throw "flex row wrap probe did not observe centered wrapped chips"
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
