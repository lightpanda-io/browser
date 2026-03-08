$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-cancel'
$port = 8163
$browserOut = Join-Path $root 'upload-cancel.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-cancel.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-cancel.server.stdout.txt'
$serverErr = Join-Path $root 'upload-cancel.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$canceledWorked = $false
$serverSawNoUpload = $false
$failure = $null
$titleBefore = $null
$titleAfterCancel = $null

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

  Invoke-FileUploadCancel $hwnd $browser.Id
  Start-Sleep -Milliseconds 400
  $titleAfterCancel = Get-SmokeWindowTitle $hwnd
  $canceledWorked = $titleAfterCancel -like 'File Upload Smoke*'
  if (-not $canceledWorked) { throw 'canceling the chooser changed the page state' }

  Start-Sleep -Milliseconds 600
  $log = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { '' }
  $serverSawNoUpload = $log -notmatch 'POST /upload '
  if (-not $serverSawNoUpload) { throw 'chooser cancel still triggered an upload request' }
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
    title_after_cancel = $titleAfterCancel
    canceled_worked = $canceledWorked
    server_saw_no_upload = $serverSawNoUpload
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