. "$PSScriptRoot\..\common\Win32Input.ps1"

function Get-TabProbeEnvironment([string]$ProfileRoot) {
  return @{
    APPDATA = $ProfileRoot
    LOCALAPPDATA = $ProfileRoot
  }
}

function Wait-TabWindowHandle([int]$ProcessId, [int]$Attempts = 60) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    $hwnd = Get-TabWindowHandle $ProcessId
    if ($hwnd -ne [IntPtr]::Zero) {
      return $hwnd
    }
  }
  return [IntPtr]::Zero
}

function Get-TabWindowHandle([int]$ProcessId) {
  $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($proc -and $proc.MainWindowHandle -ne 0) {
    return [IntPtr]$proc.MainWindowHandle
  }
  return [IntPtr]::Zero
}

function Wait-TabTitle([int]$ProcessId, [string]$Needle, [int]$Attempts = 40) {
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

function Get-TabClientPoint([int]$TabIndex, [int]$TabCount = 2, [switch]$Close, [switch]$New) {
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

  $gaps = ([Math]::Max($TabCount, 1) - 1) * $tabGap
  $availableRight = $tabNewLeft - $tabGap
  $availableWidth = [Math]::Max(1, $availableRight - $presentationMargin - $gaps)
  $tabWidth = [Math]::Max(1, [Math]::Min($tabMaxWidth, [int][Math]::Truncate($availableWidth / [Math]::Max($TabCount, 1))))
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

function Stop-OwnedProbeProcess([System.Diagnostics.Process]$Process) {
  if (-not $Process) { return $null }
  $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$($Process.Id)" | Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($meta -and $meta.CommandLine -and $meta.CommandLine -notmatch "codex\.js|@openai/codex") {
    Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  }
  return $meta
}
