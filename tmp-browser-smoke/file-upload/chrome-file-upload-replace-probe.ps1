$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-replace'
$port = 8164
$browserOut = Join-Path $root 'upload-replace.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-replace.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-replace.server.stdout.txt'
$serverErr = Join-Path $root 'upload-replace.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$firstPath = (Resolve-Path (Join-Path $root 'sample-upload.txt')).Path
$secondPath = (Resolve-Path (Join-Path $root 'sample-upload-second.txt')).Path
$server = $null
$browser = $null
$ready = $false
$firstWorked = $false
$replaceWorked = $false
$submittedWorked = $false
$failure = $null
$titleAfterSubmit = $null

try {
  Reset-FileUploadProfile $profileRoot | Out-Null
  $server = Start-FileUploadServer $port $serverOut $serverErr
  $ready = Wait-FileUploadServer $port
  if (-not $ready) { throw 'file upload server did not become ready' }

  $browser = Start-FileUploadBrowser "http://127.0.0.1:$port/upload.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw 'file upload browser window handle not found' }
  if (-not (Wait-FileUploadTitle $browser.Id 'File Upload Smoke' 40)) { throw 'file upload page did not load' }

  Invoke-FileUploadChoosePath $hwnd $browser.Id $firstPath
  $firstWorked = $true

  Invoke-FileUploadChoosePath $hwnd $browser.Id $secondPath
  $replaceWorked = $true

  Invoke-FileUploadSubmit $hwnd
  $titleAfterSubmit = Wait-FileUploadTitle $browser.Id 'Upload Submitted sample-upload-second.txt' 40
  if (-not $titleAfterSubmit) { throw 'replacement upload did not submit the second file' }

  $log = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { '' }
  if ($log -notmatch 'UPLOAD filename=sample-upload-second.txt') {
    throw 'upload server did not receive the replacement file name'
  }
  if ($log -notmatch 'payload=replacement upload payload from sample two') {
    throw 'upload server did not receive the replacement file payload'
  }
  $submittedWorked = $true
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
    title_after_submit = $titleAfterSubmit
    first_worked = $firstWorked
    replace_worked = $replaceWorked
    submitted_worked = $submittedWorked
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
