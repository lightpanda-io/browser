$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-attachment'
$port = 8167
$browserOut = Join-Path $root 'upload-attachment.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-attachment.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-attachment.server.stdout.txt'
$serverErr = Join-Path $root 'upload-attachment.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$samplePath = (Resolve-Path (Join-Path $root 'sample-upload.txt')).Path
$server = $null
$browser = $null
$ready = $false
$selectedWorked = $false
$downloadWorked = $false
$downloadsPageWorked = $false
$serverSawUpload = $false
$failure = $null
$titleBefore = $null
$titleAfterSubmit = $null
$titleDownloads = $null

try {
  $profile = Reset-FileUploadProfile $profileRoot
  $downloadPath = Join-Path $profile.DownloadsDir 'uploaded-sample-upload.txt'

  $server = Start-FileUploadServer $port $serverOut $serverErr
  $ready = Wait-FileUploadServer $port
  if (-not $ready) { throw 'file upload attachment server did not become ready' }

  $browser = Start-FileUploadBrowser "http://127.0.0.1:$port/upload-attachment.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw 'file upload attachment browser window handle not found' }

  $titleBefore = Wait-FileUploadTitle $browser.Id 'File Upload Attachment Smoke' 40
  if (-not $titleBefore) { throw 'file upload attachment page did not load' }

  Invoke-FileUploadChoosePath $hwnd $browser.Id $samplePath
  $selectedWorked = $true

  Invoke-FileUploadSubmit $hwnd
  $serverSawUpload = Wait-FileUploadLogNeedle $serverErr 'UPLOAD_ATTACHMENT filename=sample-upload.txt' 40 200
  if (-not $serverSawUpload) { throw 'attachment upload server did not receive the selected file' }
  if (-not (Wait-FileUploadFileExists $downloadPath 40 200)) {
    throw 'attachment upload did not create the expected downloaded file'
  }
  $downloadWorked = $true

  $payload = Get-Content -LiteralPath $downloadPath -Raw
  if ($payload -notmatch 'primary upload payload from sample one') {
    throw 'attachment upload download payload was not preserved'
  }

  $titleAfterSubmit = Wait-FileUploadTitle $browser.Id 'File Upload Attachment Smoke' 20
  if (-not $titleAfterSubmit) {
    throw 'source page was not restored after attachment upload'
  }

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlJ
  $titleDownloads = Wait-FileUploadTitle $browser.Id 'Downloads' 20
  if (-not $titleDownloads) {
    throw 'downloads page did not open after attachment upload'
  }
  $downloadsPageWorked = $true
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
    title_after_submit = $titleAfterSubmit
    title_downloads = $titleDownloads
    selected_worked = $selectedWorked
    download_worked = $downloadWorked
    downloads_page_worked = $downloadsPageWorked
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
