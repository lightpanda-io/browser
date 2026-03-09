$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-submit'
$port = 8162
$browserOut = Join-Path $root 'upload-submit.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-submit.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-submit.server.stdout.txt'
$serverErr = Join-Path $root 'upload-submit.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$samplePath = (Resolve-Path (Join-Path $root 'sample-upload.txt')).Path
$server = $null
$browser = $null
$ready = $false
$selectedWorked = $false
$submittedWorked = $false
$serverSawUpload = $false
$failure = $null
$titleBefore = $null
$titleAfterSubmit = $null

try {
  Reset-FileUploadProfile $profileRoot | Out-Null
  $server = Start-FileUploadServer $port $serverOut $serverErr
  $ready = Wait-FileUploadServer $port
  if (-not $ready) { throw 'file upload server did not become ready' }

  $browser = Start-FileUploadBrowser "http://127.0.0.1:$port/upload.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw 'file upload browser window handle not found' }

  $titleBefore = Wait-FileUploadTitle $browser.Id 'File Upload Smoke' 40
  if (-not $titleBefore) { throw 'file upload page did not load' }

  Invoke-FileUploadChoosePath $hwnd $browser.Id $samplePath
  $selectedWorked = $true

  Invoke-FileUploadSubmit $hwnd
  $titleAfterSubmit = Wait-FileUploadTitle $browser.Id 'Upload Submitted sample-upload.txt' 40
  $serverSawUpload = Wait-FileUploadLogNeedle $serverErr 'UPLOAD files=1' 40 200
  if ((-not $titleAfterSubmit) -or (-not $serverSawUpload)) {
    throw 'multipart upload did not complete with the selected file'
  }
  $submittedWorked = $true

  $log = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { '' }
  if ($log -notmatch 'sample-upload\.txt:38:primary upload payload from sample one') {
    throw 'upload server did not receive the expected file payload'
  }
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
    selected_worked = $selectedWorked
    submitted_worked = $submittedWorked
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
