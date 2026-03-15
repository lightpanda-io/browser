$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8180
$pageUrl = "http://127.0.0.1:$port/float-dock.html"
$outPng = Join-Path $root "float-dock.png"
$browserOut = Join-Path $root "float-dock.browser.stdout.txt"
$browserErr = Join-Path $root "float-dock.browser.stderr.txt"
$serverOut = Join-Path $root "float-dock.server.stdout.txt"
$serverErr = Join-Path $root "float-dock.server.stderr.txt"
$profileRoot = Join-Path $root "profile-float-dock"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","760","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "float dock screenshot did not become ready" }

    $redBounds = Find-ColorBounds $outPng { param($c) ($c.R -ge 190 -and $c.R -le 235) -and ($c.G -ge 50 -and $c.G -le 110) -and ($c.B -ge 50 -and $c.B -le 110) }
    $blueBounds = Find-ColorBounds $outPng { param($c) ($c.R -ge 30 -and $c.R -le 80) -and ($c.G -ge 90 -and $c.G -le 140) -and ($c.B -ge 170 -and $c.B -le 230) }
    $greenBounds = Find-ColorBounds $outPng { param($c) ($c.R -ge 70 -and $c.R -le 120) -and ($c.G -ge 140 -and $c.G -le 190) -and ($c.B -ge 70 -and $c.B -le 120) }

    $result = [ordered]@{
      red = $redBounds
      blue = $blueBounds
      green = $greenBounds
      left_docked = $redBounds.left -lt 100
      right_docked = $blueBounds.right -gt 690
      body_below = ($greenBounds.top -ge $redBounds.bottom) -and ($greenBounds.top -ge $blueBounds.bottom)
    }
    $result.float_dock_worked = $result.left_docked -and $result.right_docked -and $result.body_below
    if (-not $result.float_dock_worked) {
      throw "float dock probe did not observe left/right floated chips with body flow below them"
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
