$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-named-anchor"
$port = 8168
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-popup-named-anchor.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-named-anchor.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-named-anchor.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-named-anchor.server.stderr.txt"
$screenshotPath = Join-Path $root "chrome-popup-named-anchor.png"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$screenshotPath -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

Add-Type -AssemblyName System.Drawing

function Get-ColorBounds(
  [string]$Path,
  [scriptblock]$Predicate,
  [int]$MinX = 0,
  [int]$MinY = 0,
  [int]$MaxX = -1,
  [int]$MaxY = -1
) {
  $bitmap = [System.Drawing.Bitmap]::FromFile($Path)
  try {
    $foundMinX = 99999
    $foundMinY = 99999
    $foundMaxX = -1
    $foundMaxY = -1
    $scanMaxX = if ($MaxX -ge 0) { [Math]::Min($MaxX, $bitmap.Width - 1) } else { $bitmap.Width - 1 }
    $scanMaxY = if ($MaxY -ge 0) { [Math]::Min($MaxY, $bitmap.Height - 1) } else { $bitmap.Height - 1 }
    for ($y = [Math]::Max(0, $MinY); $y -le $scanMaxY; $y++) {
      for ($x = [Math]::Max(0, $MinX); $x -le $scanMaxX; $x++) {
        $color = $bitmap.GetPixel($x, $y)
        if (& $Predicate $color) {
          if ($x -lt $foundMinX) { $foundMinX = $x }
          if ($y -lt $foundMinY) { $foundMinY = $y }
          if ($x -gt $foundMaxX) { $foundMaxX = $x }
          if ($y -gt $foundMaxY) { $foundMaxY = $y }
        }
      }
    }
    if ($foundMaxX -lt $foundMinX -or $foundMaxY -lt $foundMinY) { return $null }
    return [ordered]@{
      min_x = $foundMinX
      min_y = $foundMinY
      max_x = $foundMaxX
      max_y = $foundMaxY
      click_x = [int][Math]::Floor(($foundMinX + $foundMaxX) / 2)
      click_y = [int][Math]::Floor(($foundMinY + $foundMaxY) / 2)
    }
  } finally {
    $bitmap.Dispose()
  }
}

$server = $null
$browser = $null
$ready = $false
$firstWorked = $false
$secondWorked = $false
$reusedTargetWorked = $false
$failure = $null
$titles = [ordered]@{}
$firstTargetBounds = $null
$secondTargetBounds = $null
$serverSawOne = $false
$serverSawTwo = $false

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/named-target-index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "named target anchor server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/named-target-index.html","--window_width","960","--window_height","640","--screenshot_png",$screenshotPath -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "named target anchor window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Named Anchor Start"
  if (-not $titles.initial) { throw "named target anchor initial title missing" }

  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $screenshotPath) { break }
  }
  if (-not (Test-Path $screenshotPath)) { throw "named target anchor screenshot missing" }

  $firstTargetBounds = Get-ColorBounds $screenshotPath { param($c) $c.R -gt 180 -and $c.B -gt 80 -and $c.G -lt 100 } 20 100
  if (-not $firstTargetBounds) { throw "named target anchor first target bounds missing" }
  $secondTargetBounds = Get-ColorBounds $screenshotPath { param($c) $c.R -gt 180 -and $c.G -gt 100 -and $c.B -lt 80 } 20 180
  if (-not $secondTargetBounds) { throw "named target anchor second target bounds missing" }

  [void](Invoke-SmokeClientClick $hwnd $firstTargetBounds.click_x $firstTargetBounds.click_y)
  $titles.first = Wait-TabTitle $browser.Id "Popup Named Anchor Result One"
  $firstWorked = [bool]$titles.first
  if (-not $firstWorked) { throw "first named target anchor click did not open result one" }

  $sourceTabPoint = Get-TabClientPoint -TabIndex 0 -TabCount 2
  [void](Invoke-SmokeClientClick $hwnd $sourceTabPoint.X $sourceTabPoint.Y)
  $titles.returned = Wait-TabTitle $browser.Id "Popup Named Anchor Start"
  if (-not $titles.returned) { throw "named target probe did not return to launcher tab" }

  [void](Invoke-SmokeClientClick $hwnd $secondTargetBounds.click_x $secondTargetBounds.click_y)
  $titles.second = Wait-TabTitle $browser.Id "Popup Named Anchor Result Two"
  $secondWorked = [bool]$titles.second
  if (-not $secondWorked) { throw "second named target anchor click did not open result two" }

  [void](Invoke-SmokeClientClick $hwnd $sourceTabPoint.X $sourceTabPoint.Y)
  $titles.returned_again = Wait-TabTitle $browser.Id "Popup Named Anchor Start"
  if (-not $titles.returned_again) { throw "named target probe did not return to launcher tab after second click" }

  Send-SmokeCtrlTab
  $titles.reused = Wait-TabTitle $browser.Id "Popup Named Anchor Result Two"
  $reusedTargetWorked = [bool]$titles.reused
  if (-not $reusedTargetWorked) { throw "named target popup tab was not reused on second click" }

} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  if (Test-Path $serverErr) {
    $serverLog = Get-Content $serverErr -Raw
    $serverSawOne = $serverLog -match 'GET /named-target-one\.html'
    $serverSawTwo = $serverLog -match 'GET /named-target-two\.html'
  }
  if (-not $failure) {
    if (-not $serverSawOne) {
      $failure = "server did not observe named-target-one request"
    } elseif (-not $serverSawTwo) {
      $failure = "server did not observe named-target-two request"
    }
  }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    first_worked = $firstWorked
    second_worked = $secondWorked
    reused_target_worked = $reusedTargetWorked
    server_saw_one = $serverSawOne
    server_saw_two = $serverSawTwo
    first_target_bounds = $firstTargetBounds
    second_target_bounds = $secondTargetBounds
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
