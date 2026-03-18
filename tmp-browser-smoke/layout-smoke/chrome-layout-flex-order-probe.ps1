$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
$tabCommon = Join-Path $repo "tmp-browser-smoke\tabs\TabProbeCommon.ps1"
. $common
. $tabCommon

$port = 8201
$pageUrl = "http://127.0.0.1:$port/flex-order.html"
$outPng = Join-Path $root "flex-order.png"
$browserOut = Join-Path $root "flex-order.browser.stdout.txt"
$browserErr = Join-Path $root "flex-order.browser.stderr.txt"
$serverOut = Join-Path $root "flex-order.server.stdout.txt"
$serverErr = Join-Path $root "flex-order.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-order"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "flex order smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","480","--window_height","240","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    $hwnd = Wait-TabWindowHandle $browser.Id
    if ($hwnd -eq [IntPtr]::Zero) { throw "browser window handle was not ready" }
    Show-SmokeWindow $hwnd
    if (-not (Wait-TabTitle $browser.Id "Flex Order - Lightpanda Browser" 20)) { throw "flex order initial title did not stabilize" }
    if (-not (Wait-Screenshot $outPng)) { throw "flex order screenshot did not become ready" }
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    $green = Find-ColorBounds $outPng { param($c) $c.G -ge 140 -and $c.R -le 100 -and $c.B -le 140 }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $clickX = [int][Math]::Floor(($blue.left + $blue.right) / 2)
    $clickY = [int][Math]::Floor(($blue.top + $blue.bottom) / 2)
    Invoke-SmokeClientClick $hwnd $clickX $clickY | Out-Null
    $afterTitle = Wait-TabTitle $browser.Id "Flex Order Blue Target - Lightpanda Browser" 30
    if (-not $afterTitle) { throw "flex order click did not navigate to blue target" }
    $result = [ordered]@{
      title_before = "Flex Order - Lightpanda Browser"
      title_after = $afterTitle
      blue = $blue
      green = $green
      red = $red
      blue_first = ($blue.left -lt $green.left) -and ($green.left -lt $red.left)
      click_point = [ordered]@{ x = $clickX; y = $clickY }
      order_worked = [bool]$afterTitle -and ($blue.left -lt $green.left) -and ($green.left -lt $red.left)
    }
    if (-not $result.order_worked) { throw "flex order probe did not observe ordered chips and click navigation" }
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
