$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8180
$pageUrl = "http://127.0.0.1:$port/load-complete-screenshot.html"
$outPng = Join-Path $root "load-complete-screenshot.png"
$browserOut = Join-Path $root "load-complete-screenshot.browser.stdout.txt"
$browserErr = Join-Path $root "load-complete-screenshot.browser.stderr.txt"
$serverOut = Join-Path $root "load-complete-screenshot.server.stdout.txt"
$serverErr = Join-Path $root "load-complete-screenshot.server.stderr.txt"
$profileRoot = Join-Path $root "profile-load-complete-screenshot"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $started = Get-Date
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","420","--window_height","320","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "load-complete screenshot did not become ready" }
    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 140 -and $c.B -le 140 }
    $result = [ordered]@{
      red = $red
      elapsed_ms = $elapsedMs
      slow_image_visible = ($red.width -ge 70) -and ($red.height -ge 24)
      waited_for_load = ($elapsedMs -ge 900)
    }
    $result.load_complete_screenshot_worked = $result.slow_image_visible -and $result.waited_for_load
    if (-not $result.load_complete_screenshot_worked) {
      throw "load-complete screenshot probe captured before slow load finished"
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
