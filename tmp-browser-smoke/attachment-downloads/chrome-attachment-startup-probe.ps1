. "$PSScriptRoot\AttachmentProbeCommon.ps1"

$port = 8167
$serverOut = Join-Path $script:Root 'chrome-attachment-startup.server.stdout.txt'
$serverErr = Join-Path $script:Root 'chrome-attachment-startup.server.stderr.txt'
$browserOut = Join-Path $script:Root 'chrome-attachment-startup.browser.stdout.txt'
$browserErr = Join-Path $script:Root 'chrome-attachment-startup.browser.stderr.txt'
$profileRoot = Join-Path $script:Root 'profile-startup'

$ownedServer = $null
$ownedBrowser = $null
try {
  $profile = Reset-AttachmentProfile $profileRoot
  $downloadsDir = $profile.DownloadsDir
  $ownedServer = Start-AttachmentServer $port $serverOut $serverErr
  if (-not (Wait-AttachmentServer $port)) { throw 'server not ready' }

  $ownedBrowser = Start-AttachmentBrowser "http://127.0.0.1:$port/attachment-named" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $ownedBrowser.Id 60
  if ($hwnd -eq [IntPtr]::Zero) { throw 'window not ready' }

  $downloadPath = Join-Path $downloadsDir 'server-report.txt'
  $downloaded = Wait-DownloadedFile $downloadPath 80
  $downloadsTitle = Wait-TabTitle $ownedBrowser.Id 'Downloads (1)' 60
  $downloadsData = Get-Content (Join-Path $profile.AppDataRoot 'downloads-v1.txt') -Raw

  [pscustomobject]@{
    download_worked = $downloaded
    downloads_page_worked = [bool]$downloadsTitle
    named_entry_worked = $downloadsData -match 'server-report.txt'
  } | ConvertTo-Json -Compress
}
finally {
  $browserMeta = Stop-OwnedProbeProcess $ownedBrowser
  $serverMeta = Stop-OwnedProbeProcess $ownedServer
  if ($ownedBrowser) { Get-Process -Id $ownedBrowser.Id -ErrorAction SilentlyContinue | Out-Null }
  if ($ownedServer) { Get-Process -Id $ownedServer.Id -ErrorAction SilentlyContinue | Out-Null }
}