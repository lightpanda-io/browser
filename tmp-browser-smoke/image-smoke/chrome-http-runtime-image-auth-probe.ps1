$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\image-smoke"
$profileRoot = Join-Path $root "profile-http-runtime-auth"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8155
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "http_runtime_server.py"
$outPng = Join-Path $root "http-runtime-auth.png"
$browserOut = Join-Path $root "http-runtime-auth.browser.stdout.txt"
$browserErr = Join-Path $root "http-runtime-auth.browser.stderr.txt"
$serverOut = Join-Path $root "http-runtime-auth.server.stdout.txt"
$serverErr = Join-Path $root "http-runtime-auth.server.stderr.txt"
$requestLog = Join-Path $root "http-runtime.requests.jsonl"

Remove-Item $outPng,$browserOut,$browserErr,$serverOut,$serverErr,$requestLog -Force -ErrorAction SilentlyContinue
cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Milliseconds 250
  try {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/auth-page.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) {
  throw "localhost image auth server did not become ready"
}

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/auth-page.html","--screenshot_png",$outPng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
$pngReady = $false
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) {
    $pngReady = $true
    break
  }
}

$analysis = $null
if ($pngReady) {
  Add-Type -AssemblyName System.Drawing
  $bmp = [System.Drawing.Bitmap]::new($outPng)
  try {
    $redCount = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.R -ge 180 -and $c.G -le 80 -and $c.B -le 80) {
          $redCount++
        }
      }
    }
    $analysis = [ordered]@{
      width = $bmp.Width
      height = $bmp.Height
      red_count = $redCount
    }
  } finally {
    $bmp.Dispose()
  }
}

$requestEntries = @()
if (Test-Path $requestLog) {
  $requestEntries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
}
$imageEntries = @($requestEntries | Where-Object { $_.path -eq "/auth-red.png" })
$lastImage = if ($imageEntries.Count -gt 0) { $imageEntries[-1] } else { $null }

$serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
$browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force }
if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force }
for ($i = 0; $i -lt 20; $i++) {
  if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 100
}
for ($i = 0; $i -lt 20; $i++) {
  if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 100
}
$browserGone = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
$serverGone = -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)

[ordered]@{
  server_pid = $server.Id
  browser_pid = $browser.Id
  ready = $ready
  screenshot_ready = $pngReady
  screenshot_path = $outPng
  screenshot_length = if (Test-Path $outPng) { (Get-Item $outPng).Length } else { 0 }
  analysis = $analysis
  image_request_count = $imageEntries.Count
  image_request_allowed = if ($lastImage) { [bool]$lastImage.allowed } else { $false }
  image_user_agent = if ($lastImage) { [string]$lastImage.user_agent } else { "" }
  image_cookie = if ($lastImage) { [string]$lastImage.cookie } else { "" }
  image_referer = if ($lastImage) { [string]$lastImage.referer } else { "" }
  image_authorization = if ($lastImage) { [string]$lastImage.authorization } else { "" }
  browser_meta = $browserMeta
  server_meta = $serverMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
