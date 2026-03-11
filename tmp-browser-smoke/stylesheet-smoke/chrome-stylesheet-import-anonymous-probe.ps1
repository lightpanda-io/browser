$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\stylesheet-smoke"
$profileRoot = Join-Path $root "profile-stylesheet-import-anonymous"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8160
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "stylesheet_server.py"
$browserOut = Join-Path $root "stylesheet-import-anonymous.browser.stdout.txt"
$browserErr = Join-Path $root "stylesheet-import-anonymous.browser.stderr.txt"
$serverOut = Join-Path $root "stylesheet-import-anonymous.server.stdout.txt"
$serverErr = Join-Path $root "stylesheet-import-anonymous.server.stderr.txt"
$requestLog = Join-Path $root "stylesheet.requests.jsonl"
$pageUrl = "http://css%20user:p%40ss@127.0.0.1:$port/auth-stylesheet-import-anonymous-page.html"

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$requestLog -Force -ErrorAction SilentlyContinue
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
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/auth-stylesheet-import-anonymous-page.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) { throw "localhost stylesheet import anonymous server did not become ready" }

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

$loaded = $false
$rootEntry = $null
$childEntry = $null
$loadedEntry = $null
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  if (Test-Path $requestLog) {
    $entries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
    $rootEntries = @($entries | Where-Object { $_.path -eq "/private-import-anonymous-root.css" })
    $childEntries = @($entries | Where-Object { $_.path -eq "/private-import-anonymous-child.css" })
    $loadedEntries = @($entries | Where-Object { $_.path -eq "/loaded-import-anon" })
    if ($rootEntries.Count -gt 0) { $rootEntry = $rootEntries[-1] }
    if ($childEntries.Count -gt 0) { $childEntry = $childEntries[-1] }
    if ($loadedEntries.Count -gt 0) { $loadedEntry = $loadedEntries[-1] }
    if ($rootEntry -and $childEntry -and $loadedEntry) {
      $loaded = $true
      break
    }
  }
}

$serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
$browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force }
if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $server.Id -Force }
for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
for ($i = 0; $i -lt 20; $i++) { if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Milliseconds 100 }
$browserGone = -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
$serverGone = -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)

[ordered]@{
  server_pid = $server.Id
  browser_pid = $browser.Id
  ready = $ready
  loaded = $loaded
  root_allowed = if ($rootEntry) { [bool]$rootEntry.allowed } else { $false }
  root_cookie = if ($rootEntry) { [string]$rootEntry.cookie } else { "" }
  root_referer = if ($rootEntry) { [string]$rootEntry.referer } else { "" }
  root_authorization = if ($rootEntry) { [string]$rootEntry.authorization } else { "" }
  child_allowed = if ($childEntry) { [bool]$childEntry.allowed } else { $false }
  child_cookie = if ($childEntry) { [string]$childEntry.cookie } else { "" }
  child_referer = if ($childEntry) { [string]$childEntry.referer } else { "" }
  child_authorization = if ($childEntry) { [string]$childEntry.authorization } else { "" }
  loaded_applied = if ($loadedEntry) { [string]$loadedEntry.applied } else { "" }
  loaded_bg = if ($loadedEntry) { [string]$loadedEntry.bg } else { "" }
  loaded_allowed = if ($loadedEntry) { [bool]$loadedEntry.allowed } else { $false }
  browser_meta = $browserMeta
  server_meta = $serverMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
