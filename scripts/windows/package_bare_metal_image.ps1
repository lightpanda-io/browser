[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
  [string]$BrowserExe = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "zig-out\bin\lightpanda.exe"),
  [string]$PackageRoot = $(Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path "tmp-browser-smoke\bare-metal-release\image"),
  [string]$Url = "https://example.com/",
  [switch]$RunSmoke
)

$ErrorActionPreference = 'Stop'

function New-BareMetalLaunchScript {
  param(
    [string]$LaunchScriptPath,
    [string]$RepoRoot
  )

  $launchScript = @'
[CmdletBinding()]
param(
  [string]$Url = "https://example.com/",
  [string]$ScreenshotPath = $(Join-Path $PSScriptRoot "artifacts\launch.png"),
  [string]$ProfileRoot = $(Join-Path $PSScriptRoot "profile")
)

$ErrorActionPreference = 'Stop'

if (-not ("BareMetalImageUser32" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class BareMetalImageUser32 {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);
}
"@
}

$browserExe = Join-Path $PSScriptRoot "boot\lightpanda.exe"
if (-not (Test-Path $browserExe)) {
  throw "bare metal image executable missing: $browserExe"
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ScreenshotPath) | Out-Null
New-Item -ItemType Directory -Force -Path $ProfileRoot | Out-Null

$stdout = Join-Path $PSScriptRoot "artifacts\launch.stdout.txt"
$stderr = Join-Path $PSScriptRoot "artifacts\launch.stderr.txt"
$resultPath = Join-Path $PSScriptRoot "artifacts\launch-result.json"
if (Test-Path $ScreenshotPath) { Remove-Item $ScreenshotPath -Force }
if (Test-Path $stdout) { Remove-Item $stdout -Force }
if (Test-Path $stderr) { Remove-Item $stderr -Force }
if (Test-Path $resultPath) { Remove-Item $resultPath -Force }

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $browserExe
$psi.Arguments = "browse --headed --window_width 1280 --window_height 720 --screenshot_png `"$ScreenshotPath`" `"$Url`""
$psi.WorkingDirectory = $PSScriptRoot
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.EnvironmentVariables["APPDATA"] = $ProfileRoot
$psi.EnvironmentVariables["LOCALAPPDATA"] = $ProfileRoot

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $psi
$process.Start() | Out-Null

$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
$deadline = (Get-Date).AddSeconds(90)
$screenshotReady = $false
$windowTitle = ""

while ((Get-Date) -lt $deadline) {
  if (-not $process.HasExited -and $process.MainWindowHandle -ne 0) {
    $titleBuffer = New-Object System.Text.StringBuilder 512
    [void][BareMetalImageUser32]::GetWindowTextW($process.MainWindowHandle, $titleBuffer, $titleBuffer.Capacity)
    $windowTitle = $titleBuffer.ToString()
    if ($windowTitle -like "*Example Domain*") {
      $screenshotReady = $true
    }
  }

  if (Test-Path $ScreenshotPath) {
    $item = Get-Item $ScreenshotPath
    if ($item.Length -gt 0) {
      $screenshotReady = $true
      break
    }
  }

  if ($process.HasExited) {
    break
  }

  Start-Sleep -Milliseconds 250
}

if (-not $process.HasExited) {
  Start-Sleep -Milliseconds 500
  if (-not $process.HasExited) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
  }
}

$stdoutTask.Wait()
$stderrTask.Wait()
$stdoutTask.Result | Set-Content -Path $stdout -Encoding Ascii
$stderrTask.Result | Set-Content -Path $stderr -Encoding Ascii

$result = [ordered]@{
  pid = $process.Id
  exited = $process.HasExited
  exit_code = if ($process.HasExited) { $process.ExitCode } else { $null }
  success = $screenshotReady
  screenshot_ready = $screenshotReady
  screenshot_exists = (Test-Path $ScreenshotPath)
  screenshot_size = if (Test-Path $ScreenshotPath) { (Get-Item $ScreenshotPath).Length } else { 0 }
  window_title = $windowTitle
  stdout = $stdout
  stderr = $stderr
  screenshot_path = $ScreenshotPath
  profile_root = $ProfileRoot
  url = $Url
}

$result | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $resultPath -Encoding Ascii
Write-Output ($result | ConvertTo-Json -Depth 4 -Compress)

if (-not $screenshotReady) {
  throw "bare metal image launch did not reach a ready screenshot"
}
'@

  Set-Content -Path $LaunchScriptPath -Value $launchScript -Encoding Ascii
}

$browserExists = Test-Path $BrowserExe
if (-not $browserExists) {
  throw "bare metal browser binary not found: $BrowserExe"
}

if (Test-Path $PackageRoot) {
  Remove-Item $PackageRoot -Recurse -Force
}

$bootDir = Join-Path $PackageRoot "boot"
$artifactsDir = Join-Path $PackageRoot "artifacts"
New-Item -ItemType Directory -Force -Path $bootDir, $artifactsDir | Out-Null
Copy-Item -Force $BrowserExe (Join-Path $bootDir "lightpanda.exe")

$launchScriptPath = Join-Path $PackageRoot "launch.ps1"
New-BareMetalLaunchScript -LaunchScriptPath $launchScriptPath -RepoRoot $RepoRoot

$manifestPath = Join-Path $PackageRoot "manifest.json"
$gitCommit = $null
try {
  $gitCommit = (git -C $RepoRoot rev-parse HEAD).Trim()
} catch {
  $gitCommit = $null
}

$manifest = [ordered]@{
  package_root = $PackageRoot
  browser_exe = $BrowserExe
  launch_script = $launchScriptPath
  boot_binary = (Join-Path $bootDir "lightpanda.exe")
  created_utc = (Get-Date).ToUniversalTime().ToString("o")
  git_commit = $gitCommit
  url = $Url
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $manifestPath -Encoding Ascii

$launchResult = $null
if ($RunSmoke) {
  $launchResult = & $launchScriptPath -Url $Url | ConvertFrom-Json
}

$result = [ordered]@{
  package_root = $PackageRoot
  manifest_path = $manifestPath
  launch_script = $launchScriptPath
  boot_binary = (Join-Path $bootDir "lightpanda.exe")
  launch_result = $launchResult
}

$result | ConvertTo-Json -Depth 6 -Compress
