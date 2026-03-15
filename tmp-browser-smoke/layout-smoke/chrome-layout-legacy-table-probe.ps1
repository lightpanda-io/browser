$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

function Find-ColorBoundsInRegion($Path, [scriptblock]$Predicate, [int]$MinX, [int]$MinY, [int]$MaxX, [int]$MaxY) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($Path)
  try {
    $minFoundX = $bmp.Width
    $minFoundY = $bmp.Height
    $maxFoundX = -1
    $maxFoundY = -1
    $endX = [Math]::Min($MaxX, $bmp.Width - 1)
    $endY = [Math]::Min($MaxY, $bmp.Height - 1)
    for ($y = [Math]::Max(0, $MinY); $y -le $endY; $y++) {
      for ($x = [Math]::Max(0, $MinX); $x -le $endX; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if (& $Predicate $c) {
          if ($x -lt $minFoundX) { $minFoundX = $x }
          if ($y -lt $minFoundY) { $minFoundY = $y }
          if ($x -gt $maxFoundX) { $maxFoundX = $x }
          if ($y -gt $maxFoundY) { $maxFoundY = $y }
        }
      }
    }
    if ($maxFoundX -lt 0 -or $maxFoundY -lt 0) {
      throw "target color not found in region for $Path"
    }
    return [ordered]@{
      left = $minFoundX
      top = $minFoundY
      right = $maxFoundX
      bottom = $maxFoundY
      width = $maxFoundX - $minFoundX + 1
      height = $maxFoundY - $minFoundY + 1
    }
  }
  finally {
    $bmp.Dispose()
  }
}

$port = 8180
$pageUrl = "http://127.0.0.1:$port/legacy-table.html"
$outPng = Join-Path $root "legacy-table.png"
$browserOut = Join-Path $root "legacy-table.browser.stdout.txt"
$browserErr = Join-Path $root "legacy-table.browser.stderr.txt"
$serverOut = Join-Path $root "legacy-table.server.stdout.txt"
$serverErr = Join-Path $root "legacy-table.server.stderr.txt"
$profileRoot = Join-Path $root "profile-legacy-table"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","960","--window_height","540","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    if (-not (Wait-Screenshot $outPng)) { throw "legacy table screenshot did not become ready" }

    $logoBounds = Find-ColorBoundsInRegion $outPng { param($c) ($c.R -ge 60 -and $c.R -le 110) -and ($c.G -ge 120 -and $c.G -le 160) -and ($c.B -ge 220 -and $c.B -le 255) } 220 80 760 240
    $shellBounds = Find-ColorBoundsInRegion $outPng { param($c) ($c.R -ge 195 -and $c.R -le 215) -and ($c.G -ge 195 -and $c.G -le 215) -and ($c.B -ge 195 -and $c.B -le 215) } 180 220 780 340
    $sideBounds = Find-ColorBoundsInRegion $outPng { param($c) ($c.R -ge 20 -and $c.R -le 60) -and ($c.G -ge 140 -and $c.G -le 180) -and ($c.B -ge 70 -and $c.B -le 120) } 650 220 900 340

    $result = [ordered]@{
      logo = $logoBounds
      shell = $shellBounds
      side = $sideBounds
      logo_centered = ($logoBounds.left -ge 320) -and ($logoBounds.left -le 380)
      shell_centered = ($shellBounds.left -ge 240) -and ($shellBounds.left -le 300) -and ($shellBounds.width -ge 430)
      side_right = $sideBounds.left -ge ($shellBounds.right - 4)
    }
    $result.legacy_table_worked = $result.logo_centered -and $result.shell_centered -and $result.side_right
    if (-not $result.legacy_table_worked) {
      throw "legacy table probe did not observe centered table layout with a right-side cell"
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
