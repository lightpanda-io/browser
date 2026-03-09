. "$PSScriptRoot\AttachmentProbeCommon.ps1"

$port = 8165
$serverOut = Join-Path $script:Root 'chrome-attachment-address.server.stdout.txt'
$serverErr = Join-Path $script:Root 'chrome-attachment-address.server.stderr.txt'
$browserOut = Join-Path $script:Root 'chrome-attachment-address.browser.stdout.txt'
$browserErr = Join-Path $script:Root 'chrome-attachment-address.browser.stderr.txt'
$profileRoot = Join-Path $script:Root 'profile-address'

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

  Invoke-AttachmentAddressCommit $hwnd "http://127.0.0.1:$port/attachment-named"

  $downloadPath = Join-Path $downloadsDir 'server-report.txt'
  $downloaded = Wait-DownloadedFile $downloadPath 80
  $restoredTitle = Wait-TabTitle $ownedBrowser.Id 'Attachment Download Home' 40
  Start-Sleep -Milliseconds 200

  Invoke-AttachmentAddressCommit $hwnd 'browser://downloads'
  $downloadsTitle = Wait-TabTitle $ownedBrowser.Id 'Downloads (1)' 40
  $downloadsData = Get-Content (Join-Path $profile.AppDataRoot 'downloads-v1.txt') -Raw
  $requestCount = Get-AttachmentRequestCount $serverErr '/attachment-named'

  [pscustomobject]@{
    download_worked = $downloaded
    restored_title_worked = [bool]$restoredTitle
    downloads_page_worked = [bool]$downloadsTitle
    named_entry_worked = $downloadsData -match 'server-report.txt'
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
