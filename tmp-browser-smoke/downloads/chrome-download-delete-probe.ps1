$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\downloads"
$profileRoot = Join-Path $root "profile-download-delete"
$port = 8155
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$initialPng = Join-Path $root "chrome-download-delete.initial.png"
$browserOut = Join-Path $root "chrome-download-delete.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-download-delete.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-download-delete.server.stdout.txt"
$serverErr = Join-Path $root "chrome-download-delete.server.stderr.txt"

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

function Get-ColorBoundsInRegion([System.Drawing.Bitmap]$Bitmap, [int]$MinX, [int]$MinY, [int]$MaxX, [int]$MaxY, [scriptblock]$Matcher) {
  $bounds = [ordered]@{min_x=$null; min_y=$null; max_x=$null; max_y=$null; count=0}
  for ($y = [Math]::Max(0, $MinY); $y -le [Math]::Min($MaxY, $Bitmap.Height - 1); $y++) {
    for ($x = [Math]::Max(0, $MinX); $x -le [Math]::Min($MaxX, $Bitmap.Width - 1); $x++) {
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

function Wait-FileMissing([string]$Path, [int]$Attempts = 60, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    if (-not (Test-Path $Path)) {
      return $true
    }
  }
  return $false
}

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot
$env:LIGHTPANDA_BARE_METAL_INPUT = Join-Path $profileRoot "lightpanda\bare-metal-input-v1.txt"
$downloadsDir = Join-Path $profileRoot "lightpanda\downloads"
$downloadsFile = Join-Path $profileRoot "lightpanda\downloads-v1.txt"
$downloadedFile = Join-Path $downloadsDir "example-download.txt"

New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null
[System.IO.File]::WriteAllText($downloadedFile, "download smoke payload`n", [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText(
  $downloadsFile,
  "2`t23`t23`t1`texample-download.txt`t$downloadedFile`thttp://127.0.0.1:$port/artifact.txt`t`n",
  [System.Text.UTF8Encoding]::new($false)
)

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$downloadWorked = $false
$metadataWorked = $false
$deleteWorked = $false
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
  if (-not $ready) { throw "download delete probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","browser://downloads","--window_width","960","--window_height","640","--screenshot_png",$initialPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "download delete probe window handle not found" }
  $null = Wait-TabTitle $browser.Id "Browser Downloads"

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "download delete probe screenshot did not become ready" }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 750

  $downloadWorked = (Test-Path $downloadedFile) -and ((Get-Item $downloadedFile).Length -gt 0)
  $metadataWorked = (Test-Path $downloadsFile) -and ((Get-Item $downloadsFile).Length -gt 0)
  if (-not $downloadWorked) { throw "download delete probe did not seed the file" }
  if (-not $metadataWorked) { throw "download delete probe did not seed the metadata file" }

  [void](Write-BareMetalInputLine "command|download_remove|0")
  [void](Invoke-SmokeClientClick $hwnd 500 300)
  $deleteWorked = Wait-FileMissing $downloadedFile 30 100
  if (-not $deleteWorked) { throw "download delete probe did not remove the file" }

  if ((Test-Path $downloadsFile) -and ((Get-Content $downloadsFile -Raw) -match "example-download\.txt")) {
    throw "download delete probe still found saved metadata"
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
    delete_worked = $deleteWorked
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
