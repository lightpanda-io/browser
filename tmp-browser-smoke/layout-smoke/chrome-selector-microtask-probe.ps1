$ErrorActionPreference = "Stop"

$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\layout-smoke"
$repo = "C:\Users\adyba\src\lightpanda-browser"
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$serverScript = Join-Path $root "layout_server.py"
$common = Join-Path $root "LayoutProbeCommon.ps1"
. $common

$port = 8177
$pageUrl = "http://127.0.0.1:$port/selector-microtask.html"
$browserOut = Join-Path $root "selector-microtask.browser.stdout.txt"
$browserErr = Join-Path $root "selector-microtask.browser.stderr.txt"
$serverOut = Join-Path $root "selector-microtask.server.stdout.txt"
$serverErr = Join-Path $root "selector-microtask.server.stderr.txt"
$profileRoot = Join-Path $root "profile-selector-microtask"

Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
Reset-ProfileRoot $profileRoot

$server = Start-Process -FilePath "python" -ArgumentList $serverScript,$port -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
  if (-not (Wait-HttpReady $pageUrl)) { throw "layout smoke server did not become ready" }

  $env:APPDATA = $profileRoot
  $env:LOCALAPPDATA = $profileRoot
  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse",$pageUrl,"--headed","--window_width","420","--window_height","320" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr

  try {
    Start-Sleep -Seconds 3
    $alive = $null -ne (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
    $stderr = Get-Content $browserErr -Raw
    $fatal = ($stderr -match "Fatal V8 Error") -or
             ($stderr -match "InvalidPseudoClass") -or
             ($stderr -match "HandleScope::CreateHandle")
    $result = [ordered]@{
      alive_after_3s = $alive
      fatal = $fatal
      selector_microtask_worked = $alive -and (-not $fatal)
    }
    if (-not $result.selector_microtask_worked) {
      throw "selector microtask probe observed browser death or fatal selector/v8 output"
    }
    $result | ConvertTo-Json -Depth 6
  }
  finally {
    Stop-VerifiedProcess $browser.Id
    for ($i = 0; $i -lt 20; $i++) {
      if (-not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 100
    }
  }
}
finally {
  Stop-VerifiedProcess $server.Id
  for ($i = 0; $i -lt 20; $i++) {
    if (-not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
}
