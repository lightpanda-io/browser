$ErrorActionPreference = 'Stop'

$repo = "C:\Users\adyba\src\lightpanda-browser"

$root = Join-Path $repo "tmp-browser-smoke\bare-metal-release"
$packageRoot = Join-Path $root "image"
$stdout = Join-Path $root "chrome-bare-metal-image-probe.stdout.txt"
$stderr = Join-Path $root "chrome-bare-metal-image-probe.stderr.txt"

Remove-Item $stdout, $stderr -Force -ErrorAction SilentlyContinue
if (Test-Path $packageRoot) {
  Remove-Item $packageRoot -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $root | Out-Null

$packageScript = Join-Path $repo "scripts\windows\package_bare_metal_image.ps1"
$failure = $null
$result = $null

try {
  $result = & $packageScript -PackageRoot $packageRoot -RunSmoke -Url "https://example.com/" | Tee-Object -FilePath $stdout | ConvertFrom-Json

  if (-not (Test-Path $result.package_root)) {
    throw "package root missing: $($result.package_root)"
  }

  if (-not (Test-Path $result.manifest_path)) {
    throw "manifest missing: $($result.manifest_path)"
  }

  if (-not (Test-Path $result.launch_script)) {
    throw "launch script missing: $($result.launch_script)"
  }

  if (-not (Test-Path $result.boot_binary)) {
    throw "boot binary missing: $($result.boot_binary)"
  }

  if (-not (Test-Path $result.archive_path)) {
    throw "archive missing: $($result.archive_path)"
  }

  if (-not $result.archive_exists -or $result.archive_size -le 0) {
    throw "archive was not created correctly"
  }

  if (-not $result.launch_result) {
    throw "launch result missing"
  }

  if (-not $result.launch_result.success) {
    throw "launch bundle did not report success"
  }

  if (-not $result.launch_result.screenshot_ready -or -not $result.launch_result.screenshot_exists) {
    throw "launch screenshot was not captured"
  }

  if ($result.launch_result.screenshot_size -le 0) {
    throw "launch screenshot was empty"
  }
} catch {
  $failure = $_.Exception.Message
} finally {
  $resultMeta = [ordered]@{
    package_root = if ($result) { $result.package_root } else { $packageRoot }
    manifest_path = if ($result) { $result.manifest_path } else { $null }
    launch_script = if ($result) { $result.launch_script } else { $null }
    boot_binary = if ($result) { $result.boot_binary } else { $null }
    launch_result = $result.launch_result
    failure = $failure
    stdout_log = $stdout
    stderr_log = $stderr
  }
  $resultMeta | ConvertTo-Json -Depth 8 -Compress
  if ($failure) {
    exit 1
  }
}
