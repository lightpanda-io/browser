$repo = "C:\Users\adyba\src\lightpanda-browser"
$root = Join-Path $repo "tmp-browser-smoke\tabs"
$port = 8151
$browserExe = Join-Path $repo "zig-out\bin\lightpanda.exe"
$initialPng = Join-Path $root "tabs-initial.png"
$browserOut = Join-Path $root "chrome-tabs.browser.stdout.txt"
$browserErr = Join-Path $root "chrome-tabs.browser.stderr.txt"
$serverOut = Join-Path $root "chrome-tabs.server.stdout.txt"
$serverErr = Join-Path $root "chrome-tabs.server.stderr.txt"
Remove-Item $initialPng,$browserOut,$browserErr,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue

. "$PSScriptRoot\..\common\Win32Input.ps1"

function Wait-ForTitle([int]$ProcessId, [string]$Needle, [int]$Attempts = 40) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.MainWindowHandle -eq 0) { continue }
    $title = Get-SmokeWindowTitle ([IntPtr]$proc.MainWindowHandle)
    if ($title -like "*$Needle*") {
      return $title
    }
  }
  return $null
}

function Get-ClientPoint([int]$TabIndex, [switch]$Close, [switch]$New) {
  $clientWidth = 960
  $presentationMargin = 12
  $findWidth = 300
  $tabGap = 4
  $tabNewWidth = 22
  $tabMaxWidth = 180
  $findLeft = [Math]::Max($presentationMargin + 120, ($clientWidth - $presentationMargin) - $findWidth)
  $tabNewRight = $findLeft - $tabGap
  $tabNewLeft = [Math]::Max($presentationMargin, $tabNewRight - $tabNewWidth)
  if ($New) {
    return @{
      X = $tabNewLeft + 10
      Y = 14
    }
  }
  $availableRight = $tabNewLeft - $tabGap
  $tabCount = 2
  $gaps = ($tabCount - 1) * $tabGap
  $availableWidth = [Math]::Max(1, $availableRight - $presentationMargin - $gaps)
  $tabWidth = [Math]::Max(1, [Math]::Min($tabMaxWidth, [int][Math]::Truncate($availableWidth / $tabCount)))
  $left = $presentationMargin + ($TabIndex * ($tabWidth + $tabGap))
  if ($Close) {
    return @{
      X = $left + $tabWidth - 13
      Y = 14
    }
  }
  return @{
    X = $left + [int][Math]::Max(8, [Math]::Min(36, [Math]::Floor($tabWidth / 2)))
    Y = 14
  }
}

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$newTabWorked = $false
$addressNavigateWorked = $false
$keyboardBackWorked = $false
$keyboardForwardWorked = $false
$clickSwitchWorked = $false
$closeWorked = $false
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
  if (-not $ready) { throw "tab probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","960","--window_height","640","--screenshot_png",$initialPng -WorkingDirectory $repo -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $initialPng) -and ((Get-Item $initialPng).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "tab probe initial screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "tab probe window handle not found" }

  Show-SmokeWindow $hwnd
  $titles.initial = Wait-ForTitle $browser.Id "Tab One"
  if (-not $titles.initial) { throw "initial tab title did not appear" }

  $newTabPoint = Get-ClientPoint 0 -New
  [void](Invoke-SmokeClientClick $hwnd $newTabPoint.X $newTabPoint.Y)
  $titles.new_tab = Wait-ForTitle $browser.Id "New Tab"
  if (-not $titles.new_tab) {
    Start-Sleep -Milliseconds 400
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $titles.new_tab_current = Get-SmokeWindowTitle ([IntPtr]$proc.MainWindowHandle)
    }
  }
  $newTabWorked = [bool]$titles.new_tab
  if (-not $newTabWorked) { throw "new tab button did not open a blank tab" }

  [void](Invoke-SmokeClientClick $hwnd 160 40)
  Start-Sleep -Milliseconds 150
  Send-SmokeText "http://127.0.0.1:$port/two.html"
  Start-Sleep -Milliseconds 100
  Send-SmokeEnter
  $titles.second = Wait-ForTitle $browser.Id "Tab Two"
  $addressNavigateWorked = [bool]$titles.second
  if (-not $addressNavigateWorked) { throw "new tab address bar navigation did not reach tab two" }

  Send-SmokeCtrlShiftTab
  $titles.back = Wait-ForTitle $browser.Id "Tab One"
  $keyboardBackWorked = [bool]$titles.back
  if (-not $keyboardBackWorked) { throw "Ctrl+Shift+Tab did not return to tab one" }

  Send-SmokeCtrlTab
  $titles.forward = Wait-ForTitle $browser.Id "Tab Two"
  $keyboardForwardWorked = [bool]$titles.forward
  if (-not $keyboardForwardWorked) { throw "Ctrl+Tab did not return to tab two" }

  $firstTabPoint = Get-ClientPoint 0
  [void](Invoke-SmokeClientClick $hwnd $firstTabPoint.X $firstTabPoint.Y)
  $titles.click_switch = Wait-ForTitle $browser.Id "Tab One"
  $clickSwitchWorked = [bool]$titles.click_switch
  if (-not $clickSwitchWorked) { throw "tab strip click did not activate the first tab" }

  $secondTabPoint = Get-ClientPoint 1
  [void](Invoke-SmokeClientClick $hwnd $secondTabPoint.X $secondTabPoint.Y)
  $titles.reopen_second = Wait-ForTitle $browser.Id "Tab Two"
  if (-not $titles.reopen_second) { throw "second tab click did not reactivate tab two before close" }

  $closePoint = Get-ClientPoint 1 -Close
  [void](Invoke-SmokeClientClick $hwnd $closePoint.X $closePoint.Y)
  $titles.after_close = Wait-ForTitle $browser.Id "Tab One"
  $closeWorked = [bool]$titles.after_close
  if (-not $closeWorked) { throw "tab close button did not return to tab one" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 200
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    new_tab_worked = $newTabWorked
    address_navigate_worked = $addressNavigateWorked
    keyboard_back_worked = $keyboardBackWorked
    keyboard_forward_worked = $keyboardForwardWorked
    click_switch_worked = $clickSwitchWorked
    close_worked = $closeWorked
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
