$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8180
$pageUrl = "http://127.0.0.1:$port/delayed-screenshot.html"
$outPng = Join-Path $root "delayed-screenshot.png"
$browserOut = Join-Path $root "delayed-screenshot.browser.stdout.txt"
$browserErr = Join-Path $root "delayed-screenshot.browser.stderr.txt"
$serverOut = Join-Path $root "delayed-screenshot.server.stdout.txt"
$serverErr = Join-Path $root "delayed-screenshot.server.stderr.txt"
$profileRoot = Join-Path $root "profile-delayed-screenshot"

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
    if (-not (Wait-Screenshot $outPng)) { throw "delayed screenshot did not become ready" }
    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $result = [ordered]@{
      red = $red
      elapsed_ms = $elapsedMs
      delayed_content_visible = ($red.width -ge 160) -and ($red.height -ge 24)
      capture_waited = ($elapsedMs -ge 500)
    }
    $result.delayed_screenshot_worked = $result.delayed_content_visible -and $result.capture_waited
    if (-not $result.delayed_screenshot_worked) {
      throw "delayed screenshot probe captured before delayed content was painted"
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
