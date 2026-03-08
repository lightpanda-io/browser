. "$PSScriptRoot\AttachmentProbeCommon.ps1"

$port = 8166
$serverOut = Join-Path $script:Root 'chrome-attachment-link.server.stdout.txt'
$serverErr = Join-Path $script:Root 'chrome-attachment-link.server.stderr.txt'
$browserOut = Join-Path $script:Root 'chrome-attachment-link.browser.stdout.txt'
$browserErr = Join-Path $script:Root 'chrome-attachment-link.browser.stderr.txt'
$profileRoot = Join-Path $script:Root 'profile-link'

$ownedServer = $null
$ownedBrowser = $null
try {
  $profile = Reset-AttachmentProfile $profileRoot
  $downloadsDir = $profile.DownloadsDir
  $ownedServer = Start-AttachmentServer $port $serverOut $serverErr
  if (-not (Wait-AttachmentServer $port)) { throw 'server not ready' }

  $ownedBrowser = Start-AttachmentBrowser "http://127.0.0.1:$port/index.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $ownedBrowser.Id 60
  if ($hwnd -eq [IntPtr]::Zero) { throw 'window not ready' }
  $initialTitle = Wait-TabTitle $ownedBrowser.Id 'Attachment Download Home' 60
  if (-not $initialTitle) { throw 'initial title missing' }

  Focus-AttachmentDocument $hwnd
  Send-SmokeTab
  Start-Sleep -Milliseconds 150
  Send-SmokeEnter

  $downloadPath = Join-Path $downloadsDir 'attachment-basic'
  $downloaded = Wait-DownloadedFile $downloadPath 80
  $restoredTitle = Wait-TabTitle $ownedBrowser.Id 'Attachment Download Home' 40
  Start-Sleep -Milliseconds 200
  $requestCount = Get-AttachmentRequestCount $serverErr '/attachment-basic'

  [pscustomobject]@{
    download_worked = $downloaded
    restored_title_worked = [bool]$restoredTitle
    request_count = $requestCount
    single_request_worked = ($requestCount -eq 1)
  } | ConvertTo-Json -Compress
}
finally {
  $browserMeta = Stop-OwnedProbeProcess $ownedBrowser
  $serverMeta = Stop-OwnedProbeProcess $ownedServer
  if ($ownedBrowser) { Get-Process -Id $ownedBrowser.Id -ErrorAction SilentlyContinue | Out-Null }
  if ($ownedServer) { Get-Process -Id $ownedServer.Id -ErrorAction SilentlyContinue | Out-Null }
}
