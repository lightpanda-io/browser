$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\font-smoke"
$profileRoot = Join-Path $root "profile-font-anonymous"
$appDataRoot = Join-Path $profileRoot "lightpanda"
$port = 8162
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "font_server.py"
$browserOut = Join-Path $root "font-anonymous.browser.stdout.txt"
$browserErr = Join-Path $root "font-anonymous.browser.stderr.txt"
$serverOut = Join-Path $root "font-anonymous.server.stdout.txt"
$serverErr = Join-Path $root "font-anonymous.server.stderr.txt"
$requestLog = Join-Path $root "font.requests.jsonl"
$pageUrl = "http://127.0.0.1:$port/auth-font-anonymous-page.html"

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
    $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/auth-font-anonymous-page.html" -TimeoutSec 2
    if ($resp.StatusCode -eq 200) { $ready = $true; break }
  } catch {}
}
if (-not $ready) { throw "localhost font anonymous server did not become ready" }

$browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

$fontEntry = $null
$loadedEntry = $null
for ($i = 0; $i -lt 80; $i++) {
  Start-Sleep -Milliseconds 250
  if (Test-Path $requestLog) {
    $entries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
    $fontEntries = @($entries | Where-Object { $_.path -eq "/private-font-anonymous.woff2" })
    $loadedEntries = @($entries | Where-Object { $_.path -eq "/loaded-anon" })
    if ($fontEntries.Count -gt 0) { $fontEntry = $fontEntries[-1] }
    if ($loadedEntries.Count -gt 0) { $loadedEntry = $loadedEntries[-1] }
    if ($fontEntry -and $loadedEntry) { break }
  }
}

$serverMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
$browserMeta = Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force }
if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\.js|@openai/codex") { Stop-Process -Id $server.Id -Force }
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
  font_allowed = if ($fontEntry) { [bool]$fontEntry.allowed } else { $false }
  font_user_agent = if ($fontEntry) { [string]$fontEntry.user_agent } else { "" }
  font_cookie = if ($fontEntry) { [string]$fontEntry.cookie } else { "" }
  font_referer = if ($fontEntry) { [string]$fontEntry.referer } else { "" }
  font_authorization = if ($fontEntry) { [string]$fontEntry.authorization } else { "" }
  font_accept = if ($fontEntry) { [string]$fontEntry.accept } else { "" }
  loaded_allowed = if ($loadedEntry) { [bool]$loadedEntry.allowed } else { $false }
  loaded_size = if ($loadedEntry) { [string]$loadedEntry.size } else { "" }
  loaded_status = if ($loadedEntry) { [string]$loadedEntry.status } else { "" }
  loaded_check = if ($loadedEntry) { [string]$loadedEntry.check } else { "" }
  loaded_count = if ($loadedEntry) { [string]$loadedEntry.loadCount } else { "" }
  loaded_family = if ($loadedEntry) { [string]$loadedEntry.family } else { "" }
  loaded_sheet = if ($loadedEntry) { [string]$loadedEntry.sheet } else { "" }
  loaded_rules = if ($loadedEntry) { [string]$loadedEntry.rules } else { "" }
  browser_meta = $browserMeta
  server_meta = $serverMeta
  browser_gone = $browserGone
  server_gone = $serverGone
} | ConvertTo-Json -Depth 6
