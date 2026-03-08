$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$port = 8193
$serverOut = Join-Path $Root "chrome-browser-pages-start-recent.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-start-recent.server.stderr.txt"
Remove-Item $serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$ready = $false
$phases = @()
$failure = $null

function Invoke-StartRecentPhase {
  param(
    [string]$Name,
    [int]$ActionTabCount,
    [string]$ExpectedTitleNeedle,
    [scriptblock]$Validate,
    [switch]$NoNavigate
  )

  $profileRoot = Join-Path $Root ("profile-start-recent-" + $Name)
  $app = Reset-BrowserPagesProfile $profileRoot
  $bookmarks = @(
    "http://127.0.0.1:$port/index.html",
    "http://127.0.0.1:$port/page-two.html"
  )
  Seed-BrowserPagesProfile `
    -AppDataRoot $app.AppDataRoot `
    -DownloadsDir $app.DownloadsDir `
    -Port $port `
    -HomepageUrl "" `
    -Bookmarks $bookmarks `
    -SeedDownload

  $browserOut = Join-Path $Root ("chrome-browser-pages-start-recent." + $Name + ".browser.stdout.txt")
  $browserErr = Join-Path $Root ("chrome-browser-pages-start-recent." + $Name + ".browser.stderr.txt")
  Remove-Item $browserOut,$browserErr -Force -ErrorAction SilentlyContinue

  $browser = $null
  $phaseFailure = $null
  $phaseTitles = [ordered]@{}
  $phaseResult = [pscustomobject][ordered]@{
    phase = $Name
    start_opened = $false
    action_worked = $false
    validation = $false
    details = [ordered]@{}
    titles = [ordered]@{}
    error = $null
    browser_pid = 0
    browser_meta = $null
    browser_gone = $true
  }

  try {
    $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut -Stderr $browserErr
    $hwnd = Wait-TabWindowHandle $browser.Id
    if ($hwnd -eq [IntPtr]::Zero) { throw "phase $Name window handle not found" }
    Show-SmokeWindow $hwnd

    $phaseTitles.initial = Wait-TabTitle $browser.Id "Browser Pages One" 40
    if (-not $phaseTitles.initial) { throw "phase $Name initial page did not load" }

    $phaseTitles.page_two = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "http://127.0.0.1:$port/page-two.html" "Browser Pages Two"
    if (-not $phaseTitles.page_two) { throw "phase $Name seed navigation to page two failed" }

    Focus-BrowserPagesDocument $hwnd
    Send-SmokeAltHome
    $phaseTitles.start = Wait-TabTitle $browser.Id "Browser Start" 40
    $phaseResult.start_opened = [bool]$phaseTitles.start
    if (-not $phaseResult.start_opened) { throw "phase $Name did not open Browser Start" }

    if ($NoNavigate) {
      Invoke-BrowserPagesDocumentActionNoNavigate $hwnd $ActionTabCount 650
      $phaseTitles.result = Get-SmokeWindowTitle $hwnd
      $phaseResult.action_worked = $true
    } else {
      $phaseTitles.result = Invoke-BrowserPagesDocumentAction $hwnd $ActionTabCount $browser.Id $ExpectedTitleNeedle
      $phaseResult.action_worked = [bool]$phaseTitles.result
      if (-not $phaseResult.action_worked) { throw "phase $Name action did not reach $ExpectedTitleNeedle" }
    }

    $validation = & $Validate $browserErr $serverErr
    $validationWorked = if ($validation -is [System.Collections.IDictionary]) {
      [bool]$validation["Worked"]
    } else {
      [bool]$validation.Worked
    }
    $phaseResult.validation = $validationWorked
    $phaseResult.details = $validation
    if (-not $phaseResult.validation) { throw "phase $Name validation failed" }
  } catch {
    $phaseFailure = $_.Exception.Message
  } finally {
    $browserMeta = Stop-OwnedProbeProcess $browser
    Start-Sleep -Milliseconds 200
    $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }

    $phaseResult.titles = $phaseTitles
    $phaseResult.error = $phaseFailure
    $phaseResult.browser_pid = if ($browser) { $browser.Id } else { 0 }
    $phaseResult.browser_meta = $browserMeta
    $phaseResult.browser_gone = $browserGone
  }

  if ($phaseFailure) {
    throw $phaseFailure
  }

  return $phaseResult
}

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "start recent server did not become ready" }

  $phases += Invoke-StartRecentPhase "history-open-page-one" 22 "Browser Pages One" {
    param($BrowserErrPath, $ServerErrPath)
    [pscustomobject][ordered]@{
      Worked = $true
    }
  }

  $phases += Invoke-StartRecentPhase "bookmark-open-page-two" 25 "Browser Pages Two" {
    param($BrowserErrPath, $ServerErrPath)
    [pscustomobject][ordered]@{
      Worked = $true
    }
  }

  $phases += Invoke-StartRecentPhase "download-source" 31 "" {
    param($BrowserErrPath, $ServerErrPath)
    Start-Sleep -Milliseconds 500
    $sourceRequests = @((Get-Content $ServerErrPath -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'GET /download\.txt' }).Count
    $browserNavigated = @((Get-Content $BrowserErrPath -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'url = http://127\.0\.0\.1:8193/download\.txt' }).Count -ge 1
    [pscustomobject][ordered]@{
      Worked = ($sourceRequests -ge 1 -or $browserNavigated)
      source_requests = $sourceRequests
      browser_navigated = $browserNavigated
    }
  } -NoNavigate
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  Start-Sleep -Milliseconds 200
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }
  $allWorked = ($ready -and -not $failure -and ($phases.Count -gt 0) -and (@($phases | Where-Object { -not $_.validation -or -not $_.action_worked -or -not $_.start_opened }).Count -eq 0))

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    ready = $ready
    all_worked = $allWorked
    phases = $phases
    error = $failure
    server_meta = $serverMeta
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 8
}

if ($failure) { exit 1 }
if (@($phases | Where-Object { -not $_.validation -or -not $_.action_worked -or -not $_.start_opened }).Count -gt 0) { exit 1 }
