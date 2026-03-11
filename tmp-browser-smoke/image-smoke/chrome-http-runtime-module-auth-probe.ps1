$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\image-smoke"
$profileRoot = Join-Path $root "profile-http-runtime-module-auth"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8162
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "http_runtime_server.py"
$outPng = Join-Path $root "http-runtime-module-auth.png"
$browserOut = Join-Path $root "http-runtime-module-auth.browser.stdout.txt"
$browserErr = Join-Path $root "http-runtime-module-auth.browser.stderr.txt"
$serverOut = Join-Path $root "http-runtime-module-auth.server.stdout.txt"
$serverErr = Join-Path $root "http-runtime-module-auth.server.stderr.txt"
$requestLog = Join-Path $root "http-runtime.requests.jsonl"
$pageUrl = "http://img%20user:p%40ss@127.0.0.1:$port/auth-module-page.html"

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
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/auth-module-page.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) { throw "localhost module auth server did not become ready" }

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--screenshot_png",$outPng -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
$pngReady = $false
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  if ((Test-Path $outPng) -and ((Get-Item $outPng).Length -gt 0)) { $pngReady = $true; break }
}

$entries = @()
if (Test-Path $requestLog) {
  $entries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
}
$rootEntries = @($entries | Where-Object { $_.path -eq "/auth-module-root.js" })
$childEntries = @($entries | Where-Object { $_.path -eq "/auth-module-child.js" })
$beaconEntries = @($entries | Where-Object { $_.path -eq "/module-auth-beacon.png" })
$lastRoot = if ($rootEntries.Count -gt 0) { $rootEntries[-1] } else { $null }
$lastChild = if ($childEntries.Count -gt 0) { $childEntries[-1] } else { $null }
$lastBeacon = if ($beaconEntries.Count -gt 0) { $beaconEntries[-1] } else { $null }

$serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
$browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force }
if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force }
for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
$browserGone = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
$serverGone = -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)

[ordered]@{
  server_pid = $server.Id
  browser_pid = $browser.Id
  ready = $ready
  screenshot_ready = $pngReady
  root_request_count = $rootEntries.Count
  root_request_allowed = if ($lastRoot) { [bool]$lastRoot.allowed } else { $false }
  root_cookie = if ($lastRoot) { [string]$lastRoot.cookie } else { "" }
  root_referer = if ($lastRoot) { [string]$lastRoot.referer } else { "" }
  root_authorization = if ($lastRoot) { [string]$lastRoot.authorization } else { "" }
  child_request_count = $childEntries.Count
  child_request_allowed = if ($lastChild) { [bool]$lastChild.allowed } else { $false }
  child_cookie = if ($lastChild) { [string]$lastChild.cookie } else { "" }
  child_referer = if ($lastChild) { [string]$lastChild.referer } else { "" }
  child_authorization = if ($lastChild) { [string]$lastChild.authorization } else { "" }
  beacon_request_count = $beaconEntries.Count
  beacon_request_allowed = if ($lastBeacon) { [bool]$lastBeacon.allowed } else { $false }
  browser_meta = $browserMeta
  server_meta = $serverMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
