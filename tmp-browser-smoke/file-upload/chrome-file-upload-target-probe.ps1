$ErrorActionPreference = 'Stop'
$repo = 'C:\Users\adyba\src\lightpanda-browser'
$root = Join-Path $repo 'tmp-browser-smoke\file-upload'
$profileRoot = Join-Path $root 'profile-upload-target'
$port = 8166
$browserOut = Join-Path $root 'upload-target.browser.stdout.txt'
$browserErr = Join-Path $root 'upload-target.browser.stderr.txt'
$serverOut = Join-Path $root 'upload-target.server.stdout.txt'
$serverErr = Join-Path $root 'upload-target.server.stderr.txt'

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
. "$PSScriptRoot\FileUploadProbeCommon.ps1"

$samplePath = (Resolve-Path (Join-Path $root 'sample-upload.txt')).Path
$server = $null
$browser = $null
$ready = $false
$selectedWorked = $false
$targetWorked = $false
$originPreserved = $false
$failure = $null
$titleBefore = $null
$titleTarget = $null
$titleOrigin = $null
$serverSawUpload = $false

try {
  Reset-FileUploadProfile $profileRoot | Out-Null
  $server = Start-FileUploadServer $port $serverOut $serverErr
  $ready = Wait-FileUploadServer $port
  if (-not $ready) { throw 'file upload target server did not become ready' }

  $browser = Start-FileUploadBrowser "http://127.0.0.1:$port/upload-target.html" $browserOut $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw 'file upload target browser window handle not found' }

  $titleBefore = Wait-FileUploadTitle $browser.Id 'File Upload Target Smoke' 40
  if (-not $titleBefore) { throw 'file upload target page did not load' }

  Invoke-FileUploadChoosePath $hwnd $browser.Id $samplePath
  $selectedWorked = $true

  Invoke-FileUploadSubmit $hwnd
  $titleTarget = Wait-FileUploadTitle $browser.Id 'Upload Target Submitted sample-upload.txt' 40
  $serverSawUpload = Wait-FileUploadLogNeedle $serverErr 'UPLOAD_TARGET filename=sample-upload.txt' 40 200
  if ((-not $titleTarget) -or (-not $serverSawUpload)) {
    throw 'named target upload did not open the expected result tab'
  }
  $targetWorked = $true

  Show-SmokeWindow $hwnd
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlDigit 1
  $titleOrigin = Wait-FileUploadTitle $browser.Id 'File Upload Target Smoke' 20
  if (-not $titleOrigin) {
    throw 'original upload tab was not preserved after target upload'
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
    title_target = $titleTarget
    title_origin = $titleOrigin
    selected_worked = $selectedWorked
    target_worked = $targetWorked
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
