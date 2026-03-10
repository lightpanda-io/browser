$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\image-smoke"
$profileRoot = Join-Path $root "profile-http-runtime-script-auth-anonymous"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8161
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "http_runtime_server.py"
$outPng = Join-Path $root "http-runtime-script-auth-anonymous.png"
$browserOut = Join-Path $root "http-runtime-script-auth-anonymous.browser.stdout.txt"
$browserErr = Join-Path $root "http-runtime-script-auth-anonymous.browser.stderr.txt"
$serverOut = Join-Path $root "http-runtime-script-auth-anonymous.server.stdout.txt"
$serverErr = Join-Path $root "http-runtime-script-auth-anonymous.server.stderr.txt"
$requestLog = Join-Path $root "http-runtime.requests.jsonl"
$pageUrl = "http://img%20user:p%40ss@127.0.0.1:$port/auth-script-anonymous-page.html"

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
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/auth-script-anonymous-page.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) {
  throw "localhost anonymous script auth server did not become ready"
}

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--screenshot_png",$outPng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
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
    $blueCount = 0
    for ($y = 0; $y -lt $bmp.Height; $y++) {
      for ($x = 0; $x -lt $bmp.Width; $x++) {
        $c = $bmp.GetPixel($x, $y)
        if ($c.B -ge 160 -and $c.G -ge 80 -and $c.R -le 80) {
          $blueCount++
        }
      }
    }
    $analysis = [ordered]@{
      width = $bmp.Width
      height = $bmp.Height
      blue_count = $blueCount
    }
  } finally {
    $bmp.Dispose()
  }
}

$requestEntries = @()
if (Test-Path $requestLog) {
  $requestEntries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
}
$scriptEntries = @($requestEntries | Where-Object { $_.path -eq "/auth-anon-script.js" })
$lastScript = if ($scriptEntries.Count -gt 0) { $scriptEntries[-1] } else { $null }
$beaconEntries = @($requestEntries | Where-Object { $_.path -eq "/script-anon-beacon.png" })
$lastBeacon = if ($beaconEntries.Count -gt 0) { $beaconEntries[-1] } else { $null }

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
  script_request_count = $scriptEntries.Count
  script_request_allowed = if ($lastScript) { [bool]$lastScript.allowed } else { $false }
  script_user_agent = if ($lastScript) { [string]$lastScript.user_agent } else { "" }
  script_cookie = if ($lastScript) { [string]$lastScript.cookie } else { "" }
  script_referer = if ($lastScript) { [string]$lastScript.referer } else { "" }
  script_authorization = if ($lastScript) { [string]$lastScript.authorization } else { "" }
  script_accept = if ($lastScript) { [string]$lastScript.accept } else { "" }
  beacon_request_count = $beaconEntries.Count
  beacon_request_allowed = if ($lastBeacon) { [bool]$lastBeacon.allowed } else { $false }
  beacon_cookie = if ($lastBeacon) { [string]$lastBeacon.cookie } else { "" }
  beacon_referer = if ($lastBeacon) { [string]$lastBeacon.referer } else { "" }
  beacon_authorization = if ($lastBeacon) { [string]$lastBeacon.authorization } else { "" }
  browser_meta = $browserMeta
  server_meta = $serverMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
