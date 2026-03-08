$repo = "C:\Users\adyba\src\lightpanda-browser"
. "$repo\tmp-browser-smoke\browser-pages\BrowserPagesProbeCommon.ps1"

$profileRoot = Join-Path $Root "profile-title-fidelity"
$app = Reset-BrowserPagesProfile $profileRoot
$port = 8192
$browserOut1 = Join-Path $Root "chrome-browser-pages-title-fidelity.run1.browser.stdout.txt"
$browserErr1 = Join-Path $Root "chrome-browser-pages-title-fidelity.run1.browser.stderr.txt"
$browserOut2 = Join-Path $Root "chrome-browser-pages-title-fidelity.run2.browser.stdout.txt"
$browserErr2 = Join-Path $Root "chrome-browser-pages-title-fidelity.run2.browser.stderr.txt"
$serverOut = Join-Path $Root "chrome-browser-pages-title-fidelity.server.stdout.txt"
$serverErr = Join-Path $Root "chrome-browser-pages-title-fidelity.server.stderr.txt"
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
$tabsTitleWorked = $false
$bookmarkRestoreWorked = $false
$titles = [ordered]@{}
$failure = $null

try {
  $server = Start-BrowserPagesServer -Port $port -Stdout $serverOut -Stderr $serverErr
  $ready = Wait-BrowserPagesServer -Port $port
  if (-not $ready) { throw "title fidelity server did not become ready" }

  $browser1 = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut1 -Stderr $browserErr1
  $hwnd1 = Wait-TabWindowHandle $browser1.Id
  if ($hwnd1 -eq [IntPtr]::Zero) { throw "title fidelity first window handle not found" }
  Show-SmokeWindow $hwnd1

  $titles.initial = Wait-TabTitle $browser1.Id "Browser Pages One" 40
  if (-not $titles.initial) { throw "title fidelity initial page did not load" }

  Focus-BrowserPagesDocument $hwnd1
  Send-SmokeAltHome
  $titles.home = Wait-TabTitle $browser1.Id "Browser Bookmarks (2)" 40
  $homeWorked = [bool]$titles.home
  if (-not $homeWorked) { throw "Alt+Home did not open the internal homepage" }

  $firstBrowserMeta = Stop-OwnedProbeProcess $browser1
  $browser1 = $null
  Start-Sleep -Milliseconds 400

  $browser2 = Start-BrowserPagesBrowser -StartupUrl "http://127.0.0.1:$port/index.html" -Stdout $browserOut2 -Stderr $browserErr2
  $hwnd2 = Wait-TabWindowHandle $browser2.Id
  if ($hwnd2 -eq [IntPtr]::Zero) { throw "title fidelity second window handle not found" }
  Show-SmokeWindow $hwnd2

  $titles.restore_initial = Wait-TabTitle $browser2.Id "Browser Pages One" 40
  if (-not $titles.restore_initial) { throw "title fidelity restart did not load the startup page" }

  $titles.tabs = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://tabs" "Browser Tabs (2)"
  $tabsTitleWorked = [bool]$titles.tabs
  if (-not $tabsTitleWorked) { throw "browser://tabs did not show the generated tabs title" }

  $titles.restore = Invoke-BrowserPagesAddressNavigate $hwnd2 $browser2.Id "browser://tabs/activate/0" "Browser Bookmarks (2)"
  $bookmarkRestoreWorked = [bool]$titles.restore
  if (-not $bookmarkRestoreWorked) { throw "restored internal bookmarks tab did not show the generated title" }
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
    tabs_title_worked = $tabsTitleWorked
    bookmark_restore_worked = $bookmarkRestoreWorked
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
