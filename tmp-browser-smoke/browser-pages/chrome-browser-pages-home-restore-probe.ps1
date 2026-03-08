$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-home-restore"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8188
$browserOut1 = Join-Path $Root "chrome-browser-pages-home-restore.run1.browser.stdout.txt"
$browserErr1 = Join-Path $Root "chrome-browser-pages-home-restore.run1.browser.stderr.txt"
$browserOut2 = Join-Path $Root "chrome-browser-pages-home-restore.run2.browser.stdout.txt"
$browserErr2 = Join-Path $Root "chrome-browser-pages-home-restore.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-home-restore.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-home-restore.server.stderr.txt"
Remove-Item $browserOut1,$browserErr1,$browserOut2,$browserErr2,$serverOut,$serverErr -Force -ErrorAction SilentlyContinue
$bookmarks = @(
  "http://127.0.0.1:$port/index.html",
  "http://127.0.0.1:$port/page-two.html"
)
Seed-BrowserPagesProfile -AppDataRoot $app.AppDataRoot -DownloadsDir $app.DownloadsDir -Port $port -HomepageUrl "browser://bookmarks" -Bookmarks $bookmarks

$server = $null
$browser1 = $null
$browser2 = $null
$ready = $false
$homeWorked = $false
$restoreWorked = $false
$restoreViaTabSwitch = $false
$titles = [ordered]@{}
$failure = $null

function Wait-RestoreBookmarkTitle([int]$BrowserId, [int]$Attempts = 20) {
  $pretty = Wait-TabTitle $BrowserId "Browser Bookmarks (2)" $Attempts
  if ($pretty) { return $pretty }
  return Wait-TabTitle $BrowserId "browser://bookmarks" $Attempts
}

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "home/restore server did not become ready" }

  $browser1 = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut1 -Stderr $browserErr1
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) { throw "home/restore first window handle not found" }
  Show-SmokeWindow $hwnd1

  $titles.initial = Wait-TabTitle $browser1.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "home/restore initial page did not load" }

  Focus-BrowserPagesDocument $hwnd1
  Send-SmokeAltHome
  $titles.home = Wait-TabTitle $browser1.Id "Browser Bookmarks (2)" 20
  if (-not $titles.home) {
    Focus-BrowserPagesDocument $hwnd1
    Send-SmokeAltHome
    $titles.home = Wait-TabTitle $browser1.Id "Browser Bookmarks (2)" 20
  }
  $homeWorked = [bool]$titles.home
  if (-not $homeWorked) { throw "Alt+Home did not open the internal homepage" }

  $firstBrowserMeta = Stop-OwnedProbeProcess $browser1
  $browser1 = $null
  Start-Sleep -Milliseconds 400

  $browser2 = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut2 -Stderr $browserErr2
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) { throw "home/restore second window handle not found" }
  Show-SmokeWindow $hwnd2

  $titles.restore_initial = Get-SmokeWindowTitle $hwnd2
  if ($titles.restore_initial -like "*Browser Bookmarks (2)*" -or $titles.restore_initial -like "*browser://bookmarks*") {
    $titles.restore = $titles.restore_initial
    $restoreWorked = $true
  } else {
    Send-SmokeCtrlDigit 1
    $titles.restore = Wait-RestoreBookmarkTitle $browser2.Id 20
    if (-not $titles.restore) {
      $tabPoint = Get-TabClientPoint -TabIndex 0 -TabCount 2
      [void](Invoke-SmokeClientClick $hwnd2 $tabPoint.X $tabPoint.Y)
      $titles.restore = Wait-RestoreBookmarkTitle $browser2.Id 20
    }
    if (-not $titles.restore) {
      $titles.restore = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://tabs/activate/0" "browser://bookmarks"
    }
    $restoreWorked = [bool]$titles.restore
    $restoreViaTabSwitch = $restoreWorked
  }
  if (-not $restoreWorked) { throw "session restore did not reopen the internal browser page" }
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = Stop-OwnedProbeProcess $server
  $browserMeta1 = if ($browser1) { Stop-OwnedProbeProcess $browser1 } else { $null }
  $browserMeta2 = Stop-OwnedProbeProcess $browser2
  Start-Sleep -Milliseconds 200
  $browser1Gone = if ($browser1) { -not (Get-Process -Id $browser1.Id -ErrorAction SilentlyContinue) } else { $true }
  $browser2Gone = if ($browser2) { -not (Get-Process -Id $browser2.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser1_pid = if ($browser1) { $browser1.Id } else { 0 }
    browser2_pid = if ($browser2) { $browser2.Id } else { 0 }
    ready = $ready
    home_worked = $homeWorked
    restore_worked = $restoreWorked
    restore_via_tab_switch = $restoreViaTabSwitch
    titles = $titles
    error = $failure
    server_meta = $serverMeta
    browser1_meta = $browserMeta1
    browser2_meta = $browserMeta2
    browser1_gone = $browser1Gone
    browser2_gone = $browser2Gone
    server_gone = $serverGone
  } | ConvertTo-Json -Depth 7
}

if ($failure) { exit 1 }
