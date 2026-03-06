$ErrorActionPreference = "Stop"
$root = "C:\Users\adyba\src\lightpanda-browser\tmp-browser-smoke\wrapped-link"
$port = 8148
$browserExe = "C:\Users\adyba\src\lightpanda-browser\zig-out\bin\lightpanda.exe"
$browserOut = Join-Path $root "hover.browser.stdout.txt"
$browserErr = Join-Path $root "hover.browser.stderr.txt"
$serverOut = Join-Path $root "hover.server.stdout.txt"
$serverErr = Join-Path $root "hover.server.stderr.txt"
$png = Join-Path $root "hover.before.png"
Remove-Item $browserOut,$browserErr,$serverOut,$serverErr,$png -Force -ErrorAction SilentlyContinue

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class HoverProbeUser32 {
  [StructLayout(LayoutKind.Sequential)]
  public struct POINT {
    public int X;
    public int Y;
  }

  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int X, int Y);
}
"@

$server = $null
$browser = $null
$ready = $false
$pngReady = $false
$aliveAfterHover = $false
$failure = $null
$hoverClientX = 133
$hoverClientY = 186
$hoverPoint = New-Object HoverProbeUser32+POINT

try {
  $server = Start-Process -FilePath "python" -ArgumentList "-m","http.server",$port,"--bind","127.0.0.1" -WorkingDirectory $root -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr
  for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$port/index.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
  }
  if (-not $ready) { throw "hover probe server did not become ready" }

  $browser = Start-Process -FilePath $browserExe -ArgumentList "browse","http://127.0.0.1:$port/index.html","--window_width","240","--window_height","480","--screenshot_png",$png -PassThru -RedirectStandardOutput $browserOut -RedirectStandardError $browserErr
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    if ((Test-Path $png) -and ((Get-Item $png).Length -gt 0)) { $pngReady = $true; break }
  }
  if (-not $pngReady) { throw "hover screenshot did not become ready" }

  $hwnd = [IntPtr]::Zero
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 250
    $proc = Get-Process -Id $browser.Id -ErrorAction SilentlyContinue
    if ($proc -and $proc.MainWindowHandle -ne 0) {
      $hwnd = [IntPtr]$proc.MainWindowHandle
      break
    }
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "hover window handle not found" }

  [void][HoverProbeUser32]::ShowWindow($hwnd, 5)
  [void][HoverProbeUser32]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 250
  $hoverPoint.X = $hoverClientX
  $hoverPoint.Y = $hoverClientY
  [void][HoverProbeUser32]::ClientToScreen($hwnd, [ref]$hoverPoint)
  [void][HoverProbeUser32]::SetCursorPos($hoverPoint.X, $hoverPoint.Y)
  Start-Sleep -Milliseconds 1500
  $aliveAfterHover = [bool](Get-Process -Id $browser.Id -ErrorAction SilentlyContinue)
} catch {
  $failure = $_.Exception.Message
} finally {
  $serverMeta = if ($server) { Get-CimInstance Win32_Process -Filter "ProcessId=$($server.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  $browserMeta = if ($browser) { Get-CimInstance Win32_Process -Filter "ProcessId=$($browser.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate } else { $null }
  if ($browserMeta -and $browserMeta.CommandLine -and $browserMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $browser.Id -Force -ErrorAction SilentlyContinue }
  if ($serverMeta -and $serverMeta.CommandLine -and $serverMeta.CommandLine -notmatch "codex\\.js|@openai/codex") { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  $browserGone = if ($browser) { -not (Get-Process -Id $browser.Id -ErrorAction SilentlyContinue) } else { $true }
  $serverGone = if ($server) { -not (Get-Process -Id $server.Id -ErrorAction SilentlyContinue) } else { $true }

  [ordered]@{
    server_pid = if ($server) { $server.Id } else { 0 }
    browser_pid = if ($browser) { $browser.Id } else { 0 }
    ready = $ready
    screenshot_ready = $pngReady
    hover_client = [ordered]@{ x = $hoverClientX; y = $hoverClientY }
    hover_screen = [ordered]@{ x = $hoverPoint.X; y = $hoverPoint.Y }
    alive_after_hover = $aliveAfterHover
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
