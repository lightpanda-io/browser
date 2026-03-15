$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8180
$pageUrl = "http://127.0.0.1:$port/selector-forgiving.html"
$outPng = Join-Path $root "selector-forgiving.png"
$browserOut = Join-Path $root "selector-forgiving.browser.stdout.txt"
$browserErr = Join-Path $root "selector-forgiving.browser.stderr.txt"
$serverOut = Join-Path $root "selector-forgiving.server.stdout.txt"
$serverErr = Join-Path $root "selector-forgiving.server.stderr.txt"
$profileRoot = Join-Path $root "profile-selector-forgiving"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","520","--window_height","320","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "selector forgiving screenshot did not become ready" }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 90 -and $c.B -le 90 }
    $blueFound = $true
    try {
      $null = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 90 -and $c.G -le 150 }
    } catch {
      $blueFound = $false
    }

    $result = [ordered]@{
      red = $red
      red_visible = $red.width -ge 160
      duplicate_hidden = -not $blueFound
    }
    $result.selector_forgiving_worked = $result.red_visible -and $result.duplicate_hidden
    if (-not $result.selector_forgiving_worked) {
      throw "selector forgiving probe did not preserve the valid branch while hiding the duplicate"
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
