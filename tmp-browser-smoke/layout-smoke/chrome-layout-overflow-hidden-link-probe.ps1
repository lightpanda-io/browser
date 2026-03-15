$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$port = 8195
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$outPng = Join-Path $root "overflow-hidden-link.png"
$browserOut = Join-Path $root "overflow-hidden-link.browser.stdout.txt"
$browserErr = Join-Path $root "overflow-hidden-link.browser.stderr.txt"
$serverOut = Join-Path $root "overflow-hidden-link.server.stdout.txt"
$serverErr = Join-Path $root "overflow-hidden-link.server.stderr.txt"
Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot\LayoutProbeCommon.ps1"
. "$PSScriptRoot\..\common\Win32Input.ps1"

$profileRoot = Join-Path $root "profile-overflow-hidden-link"
Reset-ProfileRoot $profileRoot

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$hwnd = [IntPtr]::Zero
$titleBefore = $null
$titleAfterFooter = $null
$titleAfterBlue = $null
$footerBlocked = $false
$visibleNavigated = $false
$failure = $null
$blue = $null
$red = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList (Join-Path $root "layout_server.py"),$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  $pageUrl = "http://127.0.0.1:$port/overflow-hidden-link.html"
  if (-not (Wait-HttpReady $pageUrl)) { throw "overflow hidden link smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--window_width","420","--window_height","420","--screenshot_png",$outPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  if (-not (Wait-Screenshot $outPng)) { throw "overflow hidden link screenshot did not become ready" }

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "overflow hidden link window handle not found" }

  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $blue = Find-ColorBounds $outPng { param($c) $c.B -ge 180 -and $c.R -le 80 -and $c.G -ge 60 -and $c.G -le 150 }
    $red = Find-ColorBounds $outPng { param($c) $c.R -ge 180 -and $c.G -le 100 -and $c.B -le 100 }
  }
  finally {
    $bmp.Dispose()
  }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250
  $titleBefore = Get-SmokeWindowTitle $hwnd

  $footerX = [int][Math]::Floor(($red.left + $red.right) / 2)
  $footerY = [int][Math]::Floor(($red.top + $red.bottom) / 2)
  Invoke-SmokeClientClick $hwnd $footerX $footerY | Out-Null
  for ($i = 0; $i -lt 8; $i++) {
    Start-Sleep -Milliseconds 200
    $titleAfterFooter = Get-SmokeWindowTitle $hwnd
    if ($titleAfterFooter -like "Overflow Hidden Link Target*") { break }
  }
  $footerBlocked = -not ($titleAfterFooter -like "Overflow Hidden Link Target*")
  if (-not $footerBlocked) { throw "overflow hidden footer click still activated the hidden link region" }

  $blueX = [int][Math]::Floor(($blue.left + $blue.right) / 2)
  $blueY = [int][Math]::Floor(($blue.top + $blue.bottom) / 2)
  Invoke-SmokeClientClick $hwnd $blueX $blueY | Out-Null
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 250
    $titleAfterBlue = Get-SmokeWindowTitle $hwnd
    if ($titleAfterBlue -like "Overflow Hidden Link Target*") {
      $visibleNavigated = $true
      break
    }
  }
  if (-not $visibleNavigated) { throw "visible clipped link region did not navigate" }
}
catch {
  $failure = $_.Exception.Message
}
finally {
  if ($browser) { Stop-VerifiedProcess $browser.Id }
  if ($server) { Stop-VerifiedProcess $server.Id }
  Start-Sleep -Milliseconds 200
  [ordered]@{
    title_before = $titleBefore
    title_after_footer = $titleAfterFooter
    title_after_blue = $titleAfterBlue
    footer_blocked = $footerBlocked
    visible_navigated = $visibleNavigated
    blue = $blue
    red = $red
    error = $failure
    browser_gone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
    server_gone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
