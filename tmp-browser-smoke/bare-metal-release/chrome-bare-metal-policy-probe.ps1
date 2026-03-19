$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-policy-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-policy-probe.stderr.txt"
$serverOut = Join-Path $root "chrome-bare-metal-policy.server.stdout.txt"
$serverErr = Join-Path $root "chrome-bare-metal-policy.server.stderr.txt"
$policyScreenshot = Join-Path $root "chrome-bare-metal-policy.png"
$policyProfile = Join-Path $root "profile-policy"
$policyProfileAppData = Join-Path $policyProfile "lightpanda"
$browserOut = Join-Path $root "chrome-bare-metal-policy.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-bare-metal-policy.browser.stderr.txt"
$requestLog = Join-Path $repo "tmp-browser-smoke\image-smoke\http-runtime.requests.jsonl"
$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$manifestPath = Join-Path $packageRoot "manifest.json"
$bootBinary = Join-Path $packageRoot "boot\lightpanda.exe"
$browserExe = $bootBinary
$archivePath = Join-Path (Split-Path -Parent (Split-Path -Parent $packageRoot)) "bare-metal-release.zip"
$serverRoot = Join-Path $repo "tmp-browser-smoke\image-smoke"
$serverScript = Join-Path $serverRoot "http_runtime_server.py"
$port = 8155

Remove-Item $stdout, $stderr, $browserOut, $browserErr, $serverOut, $serverErr, $policyScreenshot -Force -ErrorAction SilentlyContinue
Remove-Item $requestLog -Force -ErrorAction SilentlyContinue
Remove-Item $policyProfile -Recurse -Force -ErrorAction SilentlyContinue

$failure = $null
$result = $null
$server = $null
$browser = $null

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

  $server = Start-Process -FilePath "python" -ArgumentList $serverScript, $port -WorkingDirectory $serverRoot -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/policy-page.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) {
        $ready = $true
        break
      }
    } catch {
    }
  }
  if (-not $ready) {
    throw "bare metal release policy server did not become ready"
  }

  New-Item -ItemType Directory -Force -Path $policyProfileAppData | Out-Null
  $browseSettings = @(
    "lightpanda-browse-settings-v1"
    "restore_previous_session`t0"
    "allow_script_popups`t0"
    "default_zoom_percent`t100"
    "homepage_url"
    ""
  ) -join "`n"
  $browseSettings | Set-Content -Path (Join-Path $policyProfileAppData "browse-settings-v1.txt") -NoNewline

  $env:APPDATA = $policyProfile
  $env:LOCALAPPDATA = $policyProfile

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse", "http://127.0.0.1:$port/policy-page.html", "--screenshot_png", $policyScreenshot -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $screenshotReady = $false
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $policyScreenshot) -and ((Get-Item $policyScreenshot).Length -gt 0)) {
      $screenshotReady = $true
      break
    }
  }

  if (-not $browser.HasExited) {
    Start-Sleep -Milliseconds 500
    if (-not $browser.HasExited) {
      Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue
    }
  }

  if (-not (Test-Path $requestLog)) {
    throw "request log missing: $requestLog"
  }

  $requestEntries = Get-Content $requestLog | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_ | ConvertFrom-Json }
  $policyEntries = @($requestEntries | Where-Object { $_.path -eq "/policy-red.png" })
  if ($policyEntries.Count -eq 0) {
    throw "policy image request was not observed"
  }

  $lastPolicy = $policyEntries[-1]
  if (-not $lastPolicy.allowed) {
    throw "policy image request was blocked"
  }

  if ($lastPolicy.referer -ne "http://127.0.0.1:$port/policy-page.html") {
    throw "policy request referer was wrong"
  }

  if ($lastPolicy.cookie -notlike "*lpimg=ok*") {
    throw "policy request cookie was wrong"
  }

  if ($lastPolicy.user_agent -notlike "*Lightpanda/*") {
    throw "policy request user agent was wrong"
  }

  $result = [ordered]@{
    browser_pid = $browser.Id
    server_pid = $server.Id
    ready = $ready
    screenshot_ready = $screenshotReady
    screenshot_path = $policyScreenshot
    screenshot_length = if (Test-Path $policyScreenshot) { (Get-Item $policyScreenshot).Length } else { 0 }
    image_request_count = $policyEntries.Count
    image_request_allowed = [bool]$lastPolicy.allowed
    image_user_agent = [string]$lastPolicy.user_agent
    image_cookie = [string]$lastPolicy.cookie
    image_referer = [string]$lastPolicy.referer
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  if ($server) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  }
  if ($browser) {
    Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue
  }

  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  if (-not $failure) {
    Remove-Item $requestLog -Force -ErrorAction SilentlyContinue
  }

  $resultMeta = [ordered]@{
    package_root = $packageRoot
    manifest_path = $manifestPath
    boot_binary = $bootBinary
    archive_path = $archivePath
    browser_exe = $browserExe
    browser_pid = if ($result) { $result.browser_pid } else { if ($browser) { $browser.Id } else { $null } }
    server_pid = if ($result) { $result.server_pid } else { if ($server) { $server.Id } else { $null } }
    ready = if ($result) { $result.ready } else { $ready }
    screenshot_ready = if ($result) { $result.screenshot_ready } else { $false }
    screenshot_path = if ($result) { $result.screenshot_path } else { $policyScreenshot }
    screenshot_length = if ($result) { $result.screenshot_length } else { if (Test-Path $policyScreenshot) { (Get-Item $policyScreenshot).Length } else { 0 } }
    image_request_count = if ($result) { $result.image_request_count } else { 0 }
    image_request_allowed = if ($result) { $result.image_request_allowed } else { $false }
    image_user_agent = if ($result) { $result.image_user_agent } else { "" }
    image_cookie = if ($result) { $result.image_cookie } else { "" }
    image_referer = if ($result) { $result.image_referer } else { "" }
    browser_gone = $browserGone
    server_gone = $serverGone
    policy_screenshot = $policyScreenshot
    failure = $failure
    stdout_log = $stdout
    stderr_log = $stderr
    browser_stdout = $browserOut
    browser_stderr = $browserErr
    policy_server_stdout = $serverOut
    policy_server_stderr = $serverErr
  }

  $resultMeta | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
