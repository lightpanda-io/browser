$script:Repo = "C:\Users\adyba\src\lightpanda-browser"
$script:Root = Join-Path $script:Repo "tmp-browser-smoke\browser-pages"
$script:BrowserExe = Join-Path $script:Repo "zig-out\bin\lightpanda.exe"

. "$script:Repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

function Reset-BrowserPagesProfile([string]$ProfileRoot) {
  $appDataRoot = Join-Path $ProfileRoot "lightpanda"
  $downloadsDir = Join-Path $appDataRoot "downloads"
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $ProfileRoot
  $env:LOCALAPPDATA = $ProfileRoot
  return @{
    AppDataRoot = $appDataRoot
    DownloadsDir = $downloadsDir
  }
}

function Seed-BrowserPagesProfile {
  param(
    [string]$AppDataRoot,
    [string]$DownloadsDir,
    [int]$Port,
    [bool]$RestorePreviousSession = $true,
    [bool]$AllowScriptPopups = $false,
    [int]$DefaultZoomPercent = 120,
    [string]$HomepageUrl = "http://127.0.0.1:$Port/index.html",
    [string[]]$Bookmarks = @(),
    [switch]$SeedDownload
  )

  @"
lightpanda-browse-settings-v1
restore_previous_session	$(if ($RestorePreviousSession) { 1 } else { 0 })
allow_script_popups	$(if ($AllowScriptPopups) { 1 } else { 0 })
default_zoom_percent	$DefaultZoomPercent
homepage_url	$HomepageUrl
"@ | Set-Content -Path (Join-Path $AppDataRoot "browse-settings-v1.txt") -NoNewline

  ($Bookmarks -join "`n") | Set-Content -Path (Join-Path $AppDataRoot "bookmarks.txt") -NoNewline

  if ($SeedDownload) {
    $seedDownloadPath = Join-Path $DownloadsDir "seed.txt"
    'seed file' | Set-Content -Path $seedDownloadPath -NoNewline
    @"
2	12	12	1	seed.txt	$seedDownloadPath	http://127.0.0.1:$Port/download.txt	
"@ | Set-Content -Path (Join-Path $AppDataRoot "downloads-v1.txt") -NoNewline
  } else {
    '' | Set-Content -Path (Join-Path $AppDataRoot "downloads-v1.txt") -NoNewline
  }
}

function Wait-BrowserPagesServer([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Start-BrowserPagesServer([int]$Port, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath "python" -ArgumentList "-m","http.server",$Port,"--bind","127.0.0.1" -WorkingDirectory $script:Root -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Start-BrowserPagesBrowser([string]$StartupUrl, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath $script:BrowserExe -ArgumentList "browse",$StartupUrl,"--window_width","960","--window_height","640" -WorkingDirectory $script:Repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Invoke-BrowserPagesAddressNavigate([IntPtr]$Hwnd, [int]$BrowserId, [string]$Url, [string]$Needle) {
  [void](Invoke-SmokeClientClick $Hwnd 160 40)
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText $Url
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  return Wait-TabTitle $BrowserId $Needle 40
}

function Focus-BrowserPagesDocument([IntPtr]$Hwnd) {
  [void](Invoke-SmokeClientClick $Hwnd 120 120)
  Start-Sleep -Milliseconds 120
}

function Invoke-BrowserPagesTabActivate([IntPtr]$Hwnd, [int]$TabCount) {
  Focus-BrowserPagesDocument $Hwnd
  for ($i = 0; $i -lt $TabCount; $i++) {
    Send-SmokeTab
    Start-Sleep -Milliseconds 120
  }
  Send-SmokeEnter
}
