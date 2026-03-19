$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-download-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-download-probe.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-download.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-download.server.stderr.txt"
$browserOut = Join-Path $root "chrome-bare-metal-download.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-bare-metal-download.browser.stderr.txt"
$initialPng = Join-Path $root "chrome-bare-metal-download.initial.png"
$profileRoot = Join-Path $root "profile-download"
$profileAppData = Join-Path $profileRoot "lightpanda"
$downloadsDir = Join-Path $profileAppData "downloads"
$downloadsFile = Join-Path $profileAppData "downloads-v1.txt"
$downloadedFile = Join-Path $downloadsDir "example-download.txt"
$requestLog = Join-Path $repo "tmp-browser-smoke\downloads\download-smoke.requests.jsonl"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$bootBinary = Join-Path $packageRoot "boot\lightpanda.exe"
$manifestPath = Join-Path $packageRoot "manifest.json"
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"
$serverRoot = Join-Path $repo "tmp-browser-smoke\downloads"
$port = 8154

Remove-Item $stdout, $stderr, $browserOut, $browserErr, $serverOut, $serverErr, $initialPng -Force -ErrorAction SilentlyContinue
Remove-Item $requestLog -Force -ErrorAction SilentlyContinue
Remove-Item $profileRoot -Recurse -Force -ErrorAction SilentlyContinue

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

$failure = $null
$result = $null
$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$downloadWorked = $false
$metadataWorked = $false

try {
  if (-not (Test-Path $manifestPath) -or -not (Test-Path $bootBinary) -or -not (Test-Path $archivePath)) {
    & $packageScript -PackageRoot $packageRoot -Url "https://example.com/" | Tee-Object -FilePath $stdout | ConvertFrom-Json | Out-Null
  }

  if (-not (Test-Path $manifestPath)) {
    throw "manifest missing: $manifestPath"
  }

  if (-not (Test-Path $bootBinary)) {
    throw "boot binary missing: $bootBinary"
  }

  if (-not (Test-Path $archivePath)) {
    throw "archive missing: $archivePath"
  }

  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $env:LIGHTPANDA_BARE_METAL_INPUT = Join-Path $profileAppData "bare-metal-input-v1.txt"

  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $serverRoot -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) {
        $ready = $true
        break
      }
    } catch {
    }
  }
  if (-not $ready) {
    throw "bare metal release download server did not become ready"
  }

  $browser = Start-Process -FilePath $bootBinary -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$initialPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) {
    throw "bare metal release download window handle not found"
  }
  $null = Wait-TabTitle $browser.Id "Download Smoke"

  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) {
      $pngReady = $true
      break
    }
  }
  if (-not $pngReady) {
    throw "bare metal release download screenshot did not become ready"
  }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 250

  $bitmap = [System.Drawing.Bitmap]::new($initialPng)
  try {
    $blue = Get-ColorBounds $bitmap { param($c) $c.B -ge 150 -and $c.R -le 90 -and $c.G -le 120 }
  } finally {
    $bitmap.Dispose()
  }

  if ($null -eq $blue.min_x) {
    throw "bare metal release download link bounds not found"
  }

  $linkX = [int][Math]::Floor(($blue.min_x + $blue.max_x) / 2)
  $linkY = [int][Math]::Floor(($blue.min_y + $blue.max_y) / 2)
  [void](Invoke-SmokeClientClick $hwnd $linkX $linkY)

  $downloadWorked = Wait-FileExists $downloadedFile
  if (-not $downloadWorked) {
    throw "downloaded file was not created"
  }

  $metadataWorked = Wait-FileExists $downloadsFile
  if (-not $metadataWorked) {
    throw "downloads state file was not created"
  }

  $content = Get-Content $downloadedFile -Raw
  if ($content -ne "download smoke payload`n" -and $content -ne "download smoke payload") {
    throw "downloaded file content mismatch"
  }

  $result = [ordered]@{
    browser_pid = $browser.Id
    server_pid = $server.Id
    ready = $ready
    screenshot_ready = $pngReady
    screenshot_path = $initialPng
    screenshot_length = if (Test-Path $initialPng) { (Get-Item $initialPng).Length } else { 0 }
    download_worked = $downloadWorked
    metadata_worked = $metadataWorked
    downloaded_file = $downloadedFile
    downloads_file = $downloadsFile
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
    package_root = $packageRoot
    manifest_path = $manifestPath
    boot_binary = $bootBinary
    archive_path = $archivePath
    browser_pid = if ($result) { $result.browser_pid } else { if ($browser) { $browser.Id } else { 0 } }
    server_pid = if ($result) { $result.server_pid } else { if ($server) { $server.Id } else { 0 } }
    ready = if ($result) { $result.ready } else { $ready }
    screenshot_ready = if ($result) { $result.screenshot_ready } else { $pngReady }
    screenshot_path = if ($result) { $result.screenshot_path } else { $initialPng }
    screenshot_length = if ($result) { $result.screenshot_length } else { if (Test-Path $initialPng) { (Get-Item $initialPng).Length } else { 0 } }
    download_worked = if ($result) { $result.download_worked } else { $downloadWorked }
    metadata_worked = if ($result) { $result.metadata_worked } else { $metadataWorked }
    downloaded_file = if ($result) { $result.downloaded_file } else { $downloadedFile }
    downloads_file = if ($result) { $result.downloads_file } else { $downloadsFile }
    browser_gone = $browserGone
    server_gone = $serverGone
    server_meta = $serverMeta
    browser_meta = $browserMeta
    failure = $failure
    stdout_log = $stdout
    stderr_log = $stderr
    browser_stdout = $browserOut
    browser_stderr = $browserErr
    server_stdout = $serverOut
    server_stderr = $serverErr
  } | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
