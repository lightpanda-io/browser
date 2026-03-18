$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
$tabCommon = Join-Path $repo "tmp-browser-smoke\tabs\TabProbeCommon.ps1"
. $common
. $tabCommon

function Find-ColorBoundsBelowY($Path, [int]$MinY, [scriptblock]$Predicate) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width
        $minYFound = $bmp.Height
        $maxX = -1
        $maxY = -1
        for ($y = $MinY; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if (& $Predicate $c) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minYFound) { $minYFound = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
        if ($maxX -lt 0 -or $maxY -lt 0) {
          throw "target color not found in $Path"
        }
        return [ordered]@{
          left = $minX
          top = $minYFound
          right = $maxX
          bottom = $maxY
          width = $maxX - $minX + 1
          height = $maxY - $minY + 1
        }
      }
      finally {
        $bmp.Dispose()
      }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}

$port = 8204
$pageUrl = "http://127.0.0.1:$port/flex-align-self.html"
$outPng = Join-Path $root "flex-align-self.png"
$browserOut = Join-Path $root "flex-align-self.browser.stdout.txt"
$browserErr = Join-Path $root "flex-align-self.browser.stderr.txt"
$serverOut = Join-Path $root "flex-align-self.server.stdout.txt"
$serverErr = Join-Path $root "flex-align-self.server.stderr.txt"
$profileRoot = Join-Path $root "profile-flex-align-self"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "flex align-self smoke server did not become ready" }
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","540","--window_height","300","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  try {
    if (-not (Wait-Screenshot $outPng)) { throw "flex align-self screenshot did not become ready" }
    $title = Wait-TabTitle $browser.Id "Flex Align Self" 20
    if (-not $title) { throw "flex align-self title did not stabilize" }
    if ($title -notmatch 'Flex Align Self\s+(\d+)\s+(\d+)\s+(\d+)') { throw "flex align-self title did not include measured tops" }
    $redTop = [int]$Matches[1]
    $grayTop = [int]$Matches[2]
    $blueTop = [int]$Matches[3]
    $result = [ordered]@{
      title = $title
      red_top = $redTop
      gray_top = $grayTop
      blue_top = $blueTop
      aligned = ($redTop -lt $grayTop) -and ($grayTop -lt $blueTop)
      gray_centered = ($grayTop -gt ($redTop + 6)) -and ($blueTop -gt ($grayTop + 6))
    }
    $result.flex_align_self_worked = $result.aligned -and $result.gray_centered
    if (-not $result.flex_align_self_worked) { throw "flex align-self probe did not observe per-item vertical alignment" }
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
