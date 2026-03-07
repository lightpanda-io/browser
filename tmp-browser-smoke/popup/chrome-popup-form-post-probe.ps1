$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\popup"
$profileRoot = Join-Path $root "profile-form-post-official"
$port = 8167
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "popup_form_server.py"
$browserOut = Join-Path $root "chrome-popup-form-post.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-popup-form-post.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-popup-form-post.server.stdout.txt"
$serverErr = Join-Path $root "chrome-popup-form-post.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

$server = $null
$browser = $null
$ready = $false
$formWorked = $false
$serverSawPost = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/form-post-index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "popup form post probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/form-post-index.html","--window_width","960","--window_height","640" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "popup form post probe window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Popup Form Post Start"
  if (-not $titles.initial) { throw "popup form post probe initial title missing" }

  Send-SmokeSpace
  $titles.result = Wait-TabTitle $browser.Id "Popup Form Post Result popup-post"
  $formWorked = [bool]$titles.result
  if (-not $formWorked) { throw "popup form post probe did not open result tab" }

  if (Test-Path $serverErr) {
    $serverSawPost = Select-String -Path $serverErr -Pattern "POPUP_POST_BODY q=popup-post" -Quiet
  }
  if (-not $serverSawPost) { throw "popup form post probe server did not record POST body" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta = Stop-OwnedProbeProcess $browser
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    form_worked = $formWorked
    server_saw_post = $serverSawPost
    titles = $titles
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
