$script:Repo = 'C:\Users\adyba\src\lightpanda-browser'
$script:Root = Join-Path $script:Repo 'tmp-browser-smoke\file-upload'
$script:BrowserExe = Join-Path $script:Repo 'zig-out\bin\lightpanda.exe'

. "$script:Repo\tmp-browser-smoke\common\Win32Input.ps1"
. "$script:Repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

if (-not ('SmokeProbeWindowEnum' -as [type])) {
  Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class SmokeProbeWindowEnum {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    public static IntPtr FindDialogWindow(uint processId, string titlePrefix) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate (IntPtr hWnd, IntPtr lParam) {
            if (!IsWindowVisible(hWnd)) {
                return true;
            }
            uint candidatePid;
            GetWindowThreadProcessId(hWnd, out candidatePid);
            if (candidatePid != processId) {
                return true;
            }
            var classBuilder = new StringBuilder(128);
            GetClassNameW(hWnd, classBuilder, classBuilder.Capacity);
            if (!String.Equals(classBuilder.ToString(), "#32770", StringComparison.Ordinal)) {
                return true;
            }
            var titleBuilder = new StringBuilder(512);
            GetWindowTextW(hWnd, titleBuilder, titleBuilder.Capacity);
            if (!String.IsNullOrEmpty(titlePrefix) && !titleBuilder.ToString().StartsWith(titlePrefix, StringComparison.OrdinalIgnoreCase)) {
                return true;
            }
            found = hWnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
"@
}

function Reset-FileUploadProfile([string]$ProfileRoot) {
  $appDataRoot = Join-Path $ProfileRoot 'lightpanda'
  $downloadsDir = Join-Path $appDataRoot 'downloads'
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $ProfileRoot
  $env:LOCALAPPDATA = $ProfileRoot
  return @{
    AppDataRoot = $appDataRoot
    DownloadsDir = $downloadsDir
  }
}

function Start-FileUploadServer([int]$Port, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath 'python' -ArgumentList (Join-Path $script:Root 'upload_server.py'),$Port -WorkingDirectory $script:Root -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Wait-FileUploadServer([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/ping" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Start-FileUploadBrowser([string]$StartupUrl, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath $script:BrowserExe -ArgumentList 'browse',$StartupUrl,'--window_width','960','--window_height','640' -WorkingDirectory $script:Repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Wait-UploadDialogWindow([int]$ProcessId, [int]$Attempts = 40, [int]$SleepMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    $hwnd = [SmokeProbeWindowEnum]::FindDialogWindow([uint32]$ProcessId, 'Select file')
    if ($hwnd -ne [IntPtr]::Zero) {
      return $hwnd
    }
  }
  return [IntPtr]::Zero
}

function Wait-UploadDialogClosed([int]$ProcessId, [int]$Attempts = 40, [int]$SleepMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    $hwnd = [SmokeProbeWindowEnum]::FindDialogWindow([uint32]$ProcessId, 'Select file')
    if ($hwnd -eq [IntPtr]::Zero) {
      return $true
    }
  }
  return $false
}

function Wait-FileUploadTitle([int]$ProcessId, [string]$Needle, [int]$Attempts = 40) {
  return Wait-TabTitle $ProcessId $Needle $Attempts
}

function Wait-FileUploadLogNeedle([string]$LogPath, [string]$Needle, [int]$Attempts = 40, [int]$SleepMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    if ((Test-Path $LogPath) -and ((Get-Content $LogPath -Raw) -like "*$Needle*")) {
      return $true
    }
  }
  return $false
}

function Wait-FileUploadFileExists([string]$Path, [int]$Attempts = 40, [int]$SleepMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $SleepMs
    if (Test-Path -LiteralPath $Path) {
      return $true
    }
  }
  return $false
}

function Invoke-FileUploadOpenDialog([IntPtr]$BrowserHwnd, [int]$BrowserPid) {
  Show-SmokeWindow $BrowserHwnd
  Start-Sleep -Milliseconds 150
  [void](Invoke-SmokeClientClick $BrowserHwnd 180 222)
  Start-Sleep -Milliseconds 120
  $dialog = Wait-UploadDialogWindow $BrowserPid 10 150
  if ($dialog -ne [IntPtr]::Zero) {
    return $dialog
  }

  Show-SmokeWindow $BrowserHwnd
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  $dialog = Wait-UploadDialogWindow $BrowserPid 20 150
  return $dialog
}

function Invoke-FileUploadChoosePath([IntPtr]$BrowserHwnd, [int]$BrowserPid, [string]$Path) {
  $dialog = Invoke-FileUploadOpenDialog $BrowserHwnd $BrowserPid
  if ($dialog -eq [IntPtr]::Zero) {
    throw 'file chooser dialog did not appear'
  }
  Show-SmokeWindow $dialog
  Start-Sleep -Milliseconds 180
  Send-SmokeText $Path
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
  if (-not (Wait-UploadDialogClosed $BrowserPid 40 150)) {
    throw 'file chooser dialog did not close after selection'
  }
}

function Invoke-FileUploadCancel([IntPtr]$BrowserHwnd, [int]$BrowserPid) {
  $dialog = Invoke-FileUploadOpenDialog $BrowserHwnd $BrowserPid
  if ($dialog -eq [IntPtr]::Zero) {
    throw 'file chooser dialog did not appear'
  }
  Show-SmokeWindow $dialog
  Start-Sleep -Milliseconds 180
  Send-SmokeEscape
  if (-not (Wait-UploadDialogClosed $BrowserPid 40 150)) {
    throw 'file chooser dialog did not close after cancel'
  }
}

function Invoke-FileUploadSubmit([IntPtr]$BrowserHwnd) {
  Show-SmokeWindow $BrowserHwnd
  Start-Sleep -Milliseconds 150
  [void](Invoke-SmokeClientClick $BrowserHwnd 120 256)
  Start-Sleep -Milliseconds 120
}
