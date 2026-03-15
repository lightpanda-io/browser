$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8183
$pageUrl = "http://127.0.0.1:$port/tiny-placeholder-screenshot.html"
$outPng = Join-Path $root "tiny-placeholder-screenshot.png"
$browserOut = Join-Path $root "tiny-placeholder-screenshot.browser.stdout.txt"
$browserErr = Join-Path $root "tiny-placeholder-screenshot.browser.stderr.txt"
$serverOut = Join-Path $root "tiny-placeholder-screenshot.server.stdout.txt"
$serverErr = Join-Path $root "tiny-placeholder-screenshot.server.stderr.txt"
$profileRoot = Join-Path $root "profile-tiny-placeholder-screenshot"

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
    if (-not (Wait-Screenshot $outPng)) { throw "tiny placeholder screenshot did not become ready" }
    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 140 -and $c.R -le 100 -and $c.B -le 140 }
    $result = [ordered]@{
      green = $green
      elapsed_ms = $elapsedMs
      delayed_content_visible = ($green.width -ge 200) -and ($green.height -ge 32)
      capture_waited = ($elapsedMs -ge 550)
    }
    $result.tiny_placeholder_screenshot_worked = $result.delayed_content_visible -and $result.capture_waited
    if (-not $result.tiny_placeholder_screenshot_worked) {
      throw "tiny placeholder screenshot probe captured before substantive content was painted"
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
