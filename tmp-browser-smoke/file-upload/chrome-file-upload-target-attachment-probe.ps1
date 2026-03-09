$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-target-attachment'
$port = 8168
$browserOut = Join-Path $root 'upload-target-attachment.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-target-attachment.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-target-attachment.server.stdout.txt'
$serverErr = Join-Path $root 'upload-target-attachment.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$samplePath = (Resolve-Path (Join-Path $root 'sample-upload.txt')).Path
$server = $null
$browser = $null
$ready = $false
$selectedWorked = $false
$downloadWorked = $false
$downloadsPageWorked = $false
$originPreserved = $false
$serverSawUpload = $false
$failure = $null
$titleBefore = $null
$titleDownloads = $null
$titleOrigin = $null

try {
  $profile = Reset-FileUploadProfile $profileRoot
  $downloadPath = Join-Path $profile.DownloadsDir 'uploaded-sample-upload.txt'

  $server = Start-FileUploadServer $port $serverOut $serverErr
  $ready = Wait-FileUploadServer $port
  if (-not $ready) { throw 'file upload target attachment server did not become ready' }

  $browser = Start-FileUploadBrowser "http://127.0.0.1:$port/upload-target-attachment.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw 'file upload target attachment browser window handle not found' }

  $titleBefore = Wait-FileUploadTitle $browser.Id 'File Upload Target Attachment Smoke' 40
  if (-not $titleBefore) { throw 'file upload target attachment page did not load' }

  Invoke-FileUploadChoosePath $hwnd $browser.Id $samplePath
  $selectedWorked = $true

  Invoke-FileUploadSubmit $hwnd
  $serverSawUpload = Wait-FileUploadLogNeedle $serverErr 'UPLOAD_TARGET_ATTACHMENT files=1' 40 200
  if (-not $serverSawUpload) { throw 'target attachment upload server did not receive the selected file' }
  if (-not (Wait-FileUploadFileExists $downloadPath 40 200)) {
    throw 'target attachment upload did not create the expected downloaded file'
  }
  $downloadWorked = $true

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlJ
  $titleDownloads = Wait-FileUploadTitle $browser.Id 'Downloads' 20
  if (-not $titleDownloads) {
    throw 'downloads page did not open after target attachment upload'
  }
  $downloadsPageWorked = $true

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlDigit 1
  $titleOrigin = Wait-FileUploadTitle $browser.Id 'File Upload Target Attachment Smoke' 20
  if (-not $titleOrigin) {
    throw 'source upload tab was not preserved after target attachment upload'
  }
  $originPreserved = $true
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Stop-OwnedProbeProcess $server } else { $null }
  $browserMeta = if ($browser) { Stop-OwnedProbeProcess $browser } else { $null }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    title_before = $titleBefore
    title_downloads = $titleDownloads
    title_origin = $titleOrigin
    selected_worked = $selectedWorked
    download_worked = $downloadWorked
    downloads_page_worked = $downloadsPageWorked
    origin_preserved = $originPreserved
    server_saw_upload = $serverSawUpload
    error = $failure
    server_meta = $serverMeta
    browser_meta = $browserMeta
    browser_gone = $browserGone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) {
  exit 1
}
