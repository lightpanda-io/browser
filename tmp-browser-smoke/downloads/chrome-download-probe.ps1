$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\downloads"
$profileRoot = Join-Path $root "profile-download"
$port = 8154
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$initialPng = Join-Path $root "chrome-download.initial.png"
$browserOut = Join-Path $root "chrome-download.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-download.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-download.server.stdout.txt"
$serverErr = Join-Path $root "chrome-download.server.stderr.txt"

Remove-Item $initialPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Remove-Item $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null

Add-Type -AssemblyName System.Drawing
. "$PSScriptRoot\..\common\Win32Input.ps1"
. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

function Get-ColorBounds([System.Drawing.Bitmap]$Bitmap, [scriptblock]$Matcher) {
  $bounds = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
  for ($y = 0; $y -lt $Bitmap.Height; $y++) {
    for ($x = 0; $x -lt $Bitmap.Width; $x++) {
      $c = $Bitmap.GetPixel($x, $y)
      if (& $Matcher $c) {
        if ($null -eq $bounds.min_x -or $x -lt $bounds.min_x) { $bounds.min_x = $x }
        if ($null -eq $bounds.min_y -or $y -lt $bounds.min_y) { $bounds.min_y = $y }
        if ($null -eq $bounds.max_x -or $x -gt $bounds.max_x) { $bounds.max_x = $x }
        if ($null -eq $bounds.max_y -or $y -gt $bounds.max_y) { $bounds.max_y = $y }
        $bounds.count++
      }
    }
  }
  return $bounds
}

function Wait-FileExists([string]$Path, [int]$Attempts = 60, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
      return $true
    }
  }
  return $false
}

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot
$downloadsDir = Join-Path $profileRoot "lightpanda\downloads"
$downloadsFile = Join-Path $profileRoot "lightpanda\downloads-v1.txt"
$downloadedFile = Join-Path $downloadsDir "example-download.txt"

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$downloadWorked = $false
$metadataWorked = $false
$failure = $null

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "download probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$initialPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "download probe window handle not found" }
  $null = Wait-TabTitle $browser.Id "Download Smoke"

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "download probe screenshot did not become ready" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250

  $bmp = [System.Drawing.Bitmap]::new($initialPng)
  try {
    $blue = Get-ColorBounds $bmp { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bmp.Dispose()
  }
  if ($null -eq $blue.min_x) { throw "download probe could not find link bounds" }

  $linkX = [int][Math]::Floor(($blue.min_x + $blue.max_x) / 2)
  $linkY = [int][Math]::Floor(($blue.min_y + $blue.max_y) / 2)
  [void](Invoke-SmokeClientClick $hwnd $linkX $linkY)

  $downloadWorked = Wait-FileExists $downloadedFile
  if (-not $downloadWorked) { throw "downloaded file was not created" }

  $metadataWorked = Wait-FileExists $downloadsFile
  if (-not $metadataWorked) { throw "downloads state file was not created" }

  $content = Get-Content $downloadedFile -Raw
  if ($content -ne "download smoke payload`n" -and $content -ne "download smoke payload") {
    throw "downloaded file content mismatch"
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Stop-OwnedProbeProcess $server } else { $null }
  $browserMeta = if ($browser) { Stop-OwnedProbeProcess $browser } else { $null }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    download_worked = $downloadWorked
    metadata_worked = $metadataWorked
    downloaded_file = $downloadedFile
    downloads_file = $downloadsFile
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
