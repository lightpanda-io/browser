$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$port = 8192
$serverOut = Join-Path $Root "chrome-browser-pages-start-actions.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-start-actions.server.stderr.txt"
Remove-Item $serverOut,$serverErr -Force -ErrorAction SilentlyContinue

$server = $null
$ready = $false
$phases = @()
$failure = $null

function Get-SettingsRaw([string]$AppDataRoot) {
  $settingsFile = Join-Path $AppDataRoot "browse-settings-v1.txt"
  if (Test-Path $settingsFile) {
    return [string](Get-Content $settingsFile -Raw)
  }
  return ""
}

function Get-NonEmptyLines([string]$Path) {
  if (-not (Test-Path $Path)) { return @() }
  return ,([string[]]@(Get-Content $Path | Where-Object { $_ -ne "" } | ForEach-Object { [string]$_ }))
}

function Invoke-StartActionsPhase {
  param(
    [string]$Name,
    [int]$ActionTabCount,
    [string]$ExpectedTitleNeedle,
    [scriptblock]$Validate
  )

  $profileRoot = Join-Path $Root ("profile-start-actions-" + $Name)
  $app = Reset-BrowserPagesProfile $profileRoot
  Seed-BrowserPagesProfile `
    -AppDataRoot $app.AppDataRoot `
    -DownloadsDir $app.DownloadsDir `
    -Port $port `
    -RestorePreviousSession $true `
    -AllowScriptPopups $false `
    -DefaultZoomPercent 120 `
    -HomepageUrl "http://127.0.0.1:$port/index.html" `
    -Bookmarks @() `
    -SeedDownload

  $browserOut = Join-Path $Root ("chrome-browser-pages-start-actions." + $Name + ".browser.stdout.txt")
  $browserErr = Join-Path $Root ("chrome-browser-pages-start-actions." + $Name + ".browser.stderr.txt")
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
    $browser = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/page-two.html" -Stdout $browserOut -Stderr $browserErr
    $hwnd = Wait-TabWindowHandle $browser.Id
    if ($hwnd -eq [IntPtr]::Zero) { throw "phase $Name window handle not found" }
    Show-SmokeWindow $hwnd

    $phaseTitles.initial = Wait-TabTitle $browser.Id "Browser Pages Two" 40
    if (-not $phaseTitles.initial) { throw "phase $Name initial page two did not load" }

    $phaseTitles.start = Invoke-BrowserPagesAddressNavigate $hwnd $browser.Id "browser://start" "Browser Start"
    $phaseResult.start_opened = [bool]$phaseTitles.start
    if (-not $phaseResult.start_opened) { throw "phase $Name did not open Browser Start" }

    $phaseTitles.result = Invoke-BrowserPagesDocumentAction $hwnd $ActionTabCount $browser.Id $ExpectedTitleNeedle
    $phaseResult.action_worked = [bool]$phaseTitles.result
    if (-not $phaseResult.action_worked) { throw "phase $Name action did not reach $ExpectedTitleNeedle" }

    Start-Sleep -Milliseconds 300
    $validation = & $Validate $app.AppDataRoot $app.DownloadsDir $browserErr
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
  if (-not $ready) { throw "start actions server did not become ready" }

  $phases += Invoke-StartActionsPhase "add-current" 7 "Browser Bookmarks (1)" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $bookmarks = Get-NonEmptyLines (Join-Path $AppDataRoot "bookmarks.txt")
    [pscustomobject][ordered]@{
      Worked = ($bookmarks.Count -eq 1 -and $bookmarks[0] -eq "http://127.0.0.1:$port/page-two.html")
      bookmarks = $bookmarks
    }
  }

  $phases += Invoke-StartActionsPhase "clear-downloads" 9 "Browser Downloads (0)" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $seedPath = Join-Path $DownloadsDir "seed.txt"
    $downloadsRaw = if (Test-Path (Join-Path $AppDataRoot "downloads-v1.txt")) { Get-Content (Join-Path $AppDataRoot "downloads-v1.txt") -Raw } else { "" }
    [pscustomobject][ordered]@{
      Worked = (-not (Test-Path $seedPath) -and [string]::IsNullOrWhiteSpace([string]$downloadsRaw))
      seed_deleted = (-not (Test-Path $seedPath))
      metadata_cleared = [string]::IsNullOrWhiteSpace([string]$downloadsRaw)
    }
  }

  $phases += Invoke-StartActionsPhase "toggle-restore" 10 "Browser Settings" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $settingsRaw = Get-SettingsRaw $AppDataRoot
    [pscustomobject][ordered]@{
      Worked = ($settingsRaw -match "restore_previous_session\t0")
      restore_saved = ($settingsRaw -match "restore_previous_session\t0")
    }
  }

  $phases += Invoke-StartActionsPhase "toggle-popups" 11 "Browser Settings" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $settingsRaw = Get-SettingsRaw $AppDataRoot
    [pscustomobject][ordered]@{
      Worked = ($settingsRaw -match "allow_script_popups\t1")
      popups_saved = ($settingsRaw -match "allow_script_popups\t1")
    }
  }

  $phases += Invoke-StartActionsPhase "zoom-in" 14 "Browser Settings" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $settingsRaw = Get-SettingsRaw $AppDataRoot
    [pscustomobject][ordered]@{
      Worked = ($settingsRaw -match "default_zoom_percent\t130")
      zoom_saved = ($settingsRaw -match "default_zoom_percent\t130")
    }
  }

  $phases += Invoke-StartActionsPhase "set-homepage-current" 15 "Browser Settings" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $settingsRaw = Get-SettingsRaw $AppDataRoot
    [pscustomobject][ordered]@{
      Worked = ($settingsRaw -match [regex]::Escape("homepage_url`thttp://127.0.0.1:$port/page-two.html"))
      homepage_saved = ($settingsRaw -match [regex]::Escape("homepage_url`thttp://127.0.0.1:$port/page-two.html"))
    }
  }

  $phases += Invoke-StartActionsPhase "clear-homepage" 16 "Browser Settings" {
    param($AppDataRoot, $DownloadsDir, $BrowserErrPath)
    $settingsRaw = Get-SettingsRaw $AppDataRoot
    [pscustomobject][ordered]@{
      Worked = ($settingsRaw -match "(?m)^homepage_url\t\s*$")
      homepage_cleared = ($settingsRaw -match "(?m)^homepage_url\t\s*$")
    }
  }
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
