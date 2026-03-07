$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\rendered-link-dom"
$profileRoot = Join-Path $root "profile"
$port = 8165
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "chrome-rendered-link-dom.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-rendered-link-dom.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-rendered-link-dom.server.stdout.txt"
$serverErr = Join-Path $root "chrome-rendered-link-dom.server.stderr.txt"

cmd /c "rmdir /s /q `"$profileRoot`"" | Out-Null
New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$env:APPDATA = $profileRoot
$env:LOCALAPPDATA = $profileRoot

. "$PSScriptRoot\..\tabs\TabProbeCommon.ps1"

function Invoke-ClientClicksUntilTitle([IntPtr]$Hwnd, [int]$ProcessId, [object[]]$Points, [string]$Needle) {
  foreach ($point in $Points) {
    [void](Invoke-SmokeClientClick $Hwnd $point.X $point.Y)
    $title = Wait-TabTitle $ProcessId $Needle 6
    if ($title) {
      return $title
    }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

$server = $null
$browser = $null
$ready = $false
$preventWorked = $false
$mutateWorked = $false
$serverSawMutated = $false
$serverSawOriginal = $false
$serverSawPrevent = $false
$failure = $null
$titles = [ordered]@{}

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "rendered link DOM probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","720" -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  $hwnd = Wait-TabWindowHandle $browser.Id
  if ($hwnd -eq [IntPtr]::Zero) { throw "rendered link DOM probe window handle not found" }
  Show-SmokeWindow $hwnd

  $titles.initial = Wait-TabTitle $browser.Id "Rendered Link DOM Start"
  if (-not $titles.initial) { throw "rendered link DOM initial title missing" }

  $titles.after_prevent = Invoke-ClientClicksUntilTitle $hwnd $browser.Id @(
    @{ X = 76; Y = 165 }
    @{ X = 76; Y = 188 }
    @{ X = 76; Y = 213 }
  ) "Rendered Prevented Click"
  $preventWorked = [bool]$titles.after_prevent
  if (-not $preventWorked) { throw "preventDefault rendered link click did not keep page and update title" }

  Start-Sleep -Milliseconds 500
  $titles.after_mutate = Invoke-ClientClicksUntilTitle $hwnd $browser.Id @(
    @{ X = 212; Y = 165 }
    @{ X = 212; Y = 188 }
    @{ X = 212; Y = 213 }
  ) "Rendered Mutated Result"
  $mutateWorked = [bool]$titles.after_mutate
  if (-not $mutateWorked) { throw "onclick href mutation did not navigate to mutated result" }

  Start-Sleep -Milliseconds 500
  $serverLog = if (Test-Path $serverErr) { Get-Content $serverErr -Raw } else { "" }
  $serverSawMutated = $serverLog -match 'GET /mutated-target\.html\?from=onclick'
  $serverSawOriginal = $serverLog -match 'GET /original-target\.html'
  $serverSawPrevent = $serverLog -match 'GET /prevent-default-should-not-load\.html'
  if (-not $serverSawMutated) { throw "server did not observe mutated-target request" }
  if ($serverSawOriginal) { throw "server observed original-target request; onclick href mutation was ignored" }
  if ($serverSawPrevent) { throw "server observed prevent-default target request" }
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
    prevent_worked = $preventWorked
    mutate_worked = $mutateWorked
    server_saw_mutated = $serverSawMutated
    server_saw_original = $serverSawOriginal
    server_saw_prevent = $serverSawPrevent
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
