$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
$tabCommon = Join-Path $repo "tmp-browser-smoke\tabs\TabProbeCommon.ps1"
. $common
. $tabCommon

$port = 8182
$pageUrl = "http://127.0.0.1:$port/absolute-zindex.html"
$outPng = Join-Path $root "absolute-zindex.png"
$browserOut = Join-Path $root "absolute-zindex.browser.stdout.txt"
$browserErr = Join-Path $root "absolute-zindex.browser.stderr.txt"
$serverOut = Join-Path $root "absolute-zindex.server.stdout.txt"
$serverErr = Join-Path $root "absolute-zindex.server.stderr.txt"
$profileRoot = Join-Path $root "profile-absolute-zindex"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","520","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    $hwnd = Wait-TabWindowHandle $browser.Id
    if ($hwnd -eq [IntPtr]::Zero) { throw "browser window handle was not ready" }
    Show-SmokeWindow $hwnd
    $initialTitle = Wait-TabTitle $browser.Id "Absolute Z Index Layout" 40
    if (-not $initialTitle) { throw "initial title did not stabilize" }
    if (-not (Wait-Screenshot $outPng)) { throw "absolute z-index screenshot did not become ready" }

    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 130 }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 100 -and $c.B -le 100 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 140 -and $c.R -le 100 -and $c.B -le 140 }

    $anchoredTop = ($red.top -lt 190) -and ($blue.top -lt 190)
    $flowBelow = ($green.top -ge ($red.bottom + 40))

    $clickX = [int][Math]::Floor(($red.left + $red.right) / 2)
    $clickY = [int][Math]::Floor(($red.top + $red.bottom) / 2)
    $clickPoint = Invoke-SmokeClientClick $hwnd $clickX $clickY
    $afterTitle = Wait-TabTitle $browser.Id "Z Index High Target" 40
    if (-not $afterTitle) { throw "overlap click did not navigate to high target" }

    $result = [ordered]@{
      title_before = $initialTitle
      title_after = $afterTitle
      blue = $blue
      red = $red
      green = $green
      click_point = $clickPoint
      anchored_top = $anchoredTop
      flow_below = $flowBelow
      overlap_click_worked = [bool]$afterTitle
    }
    $result.absolute_zindex_worked = $result.anchored_top -and $result.flow_below -and $result.overlap_click_worked
    if (-not $result.absolute_zindex_worked) {
      throw "absolute z-index probe did not observe correct positioning and overlap behavior"
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
