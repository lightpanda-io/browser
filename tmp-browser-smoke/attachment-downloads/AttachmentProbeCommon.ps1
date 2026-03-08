$script:Repo = "C:\Users\adyba\src\lightpanda-browser"
$script:Root = Join-Path $script:Repo "tmp-browser-smoke\attachment-downloads"
$script:BrowserExe = Join-Path $script:Repo "zig-out\bin\lightpanda.exe"

. "$script:Repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

function Reset-AttachmentProfile([string]$ProfileRoot) {
  $appDataRoot = Join-Path $ProfileRoot "lightpanda"
  $downloadsDir = Join-Path $appDataRoot "downloads"
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $ProfileRoot
  $env:LOCALAPPDATA = $ProfileRoot
  return @{
    AppDataRoot = $appDataRoot
    DownloadsDir = $downloadsDir
  }
}

function Wait-AttachmentServer([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Start-AttachmentServer([int]$Port, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath "python" -ArgumentList (Join-Path $script:Root "attachment_server.py"),$Port -WorkingDirectory $script:Root -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Start-AttachmentBrowser([string]$StartupUrl, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath $script:BrowserExe -ArgumentList "browse",$StartupUrl,"--window_width","960","--window_height","640" -WorkingDirectory $script:Repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Invoke-AttachmentAddressCommit([IntPtr]$Hwnd, [string]$Url) {
  Show-SmokeWindow $Hwnd
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlL
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText $Url
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
}

function Focus-AttachmentDocument([IntPtr]$Hwnd) {
  Show-SmokeWindow $Hwnd
  Start-Sleep -Milliseconds 150
  [void](Invoke-SmokeClientClick $Hwnd 120 120)
  Start-Sleep -Milliseconds 120
}

function Wait-DownloadedFile([string]$Path, [int]$Attempts = 60) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $Path) { return $true }
  }
  return $false
}

function Get-AttachmentRequestCount([string]$LogPath, [string]$Path) {
  if (-not (Test-Path $LogPath)) { return 0 }
  $last = 0
  $pattern = "^GET " + [regex]::Escape($Path) + " (\d+)$"
  foreach ($line in (Get-Content $LogPath)) {
    if ($line -match $pattern) {
      $value = [int]$Matches[1]
      if ($value -gt $last) { $last = $value }
    }
  }
  return $last
}
