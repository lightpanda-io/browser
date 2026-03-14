$script:Repo = "C:\Users\adyba\src\lightpanda-browser"
$script:Root = Join-Path $script:Repo "tmp-browser-smoke\indexeddb-persistence"
$script:BrowserExe = Join-Path $script:Repo "zig-out\bin\lightpanda.exe"

. "$script:Repo\tmp-browser-smoke\common\Win32Input.ps1"
. "$script:Repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

function Reset-IndexedDbProfile([string]$ProfileRoot) {
  $appDataRoot = Join-Path $ProfileRoot "lightpanda"
  $downloadsDir = Join-Path $appDataRoot "downloads"
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $ProfileRoot
  $env:LOCALAPPDATA = $ProfileRoot
  return @{
    AppDataRoot = $appDataRoot
    DownloadsDir = $downloadsDir
    IndexedDbFile = Join-Path $appDataRoot "indexed-db-v1.txt"
    SettingsFile = Join-Path $appDataRoot "browse-settings-v1.txt"
  }
}

function Seed-IndexedDbProfile([string]$AppDataRoot) {
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $AppDataRoot "browse-settings-v1.txt") -NoNewline
}

function Get-FreeIndexedDbPort() {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  try {
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  } finally {
    $listener.Stop()
  }
}

function Wait-IndexedDbServer([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/seed.html" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Start-IndexedDbServer([int]$Port, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath "python" -ArgumentList (Join-Path $script:Root "indexeddb_server.py"),"$Port" -WorkingDirectory $script:Root -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Start-IndexedDbBrowser([string]$StartupUrl, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath $script:BrowserExe -ArgumentList "browse",$StartupUrl,"--window_width","960","--window_height","640" -WorkingDirectory $script:Repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Invoke-IndexedDbAddressCommit([IntPtr]$Hwnd, [string]$Url) {
  Show-SmokeWindow $Hwnd
  Start-Sleep -Milliseconds 120
  Send-SmokeCtrlL
  Start-Sleep -Milliseconds 150
  Send-SmokeCtrlA
  Start-Sleep -Milliseconds 120
  Send-SmokeText $Url
  Start-Sleep -Milliseconds 120
  Send-SmokeEnter
}

function Invoke-IndexedDbAddressNavigate([IntPtr]$Hwnd, [int]$BrowserId, [string]$Url, [string]$Needle) {
  Invoke-IndexedDbAddressCommit $Hwnd $Url
  return Wait-TabTitle $BrowserId $Needle 40
}

function Read-IndexedDbFileData([string]$IndexedDbFile) {
  if (-not (Test-Path $IndexedDbFile)) {
    return ""
  }
  return Get-Content $IndexedDbFile -Raw
}

function ConvertTo-IndexedDbEntryPattern([string]$Origin, [string]$DatabaseName, [string]$StoreName, [string]$Key, [string]$Json) {
  $originField = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Origin))
  $dbField = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($DatabaseName))
  $storeField = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($StoreName))
  $keyField = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Key))
  $valueField = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
  return [regex]::Escape("entry`t$originField`t$dbField`t$storeField`t$keyField`t$valueField")
}

function Wait-IndexedDbFileMatch([string]$IndexedDbFile, [string]$Pattern, [int]$Attempts = 40) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    $data = Read-IndexedDbFileData $IndexedDbFile
    if ($data -match $Pattern) {
      return $data
    }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

function Wait-IndexedDbFileNoMatch([string]$IndexedDbFile, [string]$Pattern, [int]$Attempts = 40) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    $data = Read-IndexedDbFileData $IndexedDbFile
    if ($data -notmatch $Pattern) {
      return $data
    }
    Start-Sleep -Milliseconds 150
  }
  return $null
}

function Wait-OwnedIndexedDbProbeProcessGone([int]$ProcessId, [int]$Attempts = 40) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
      return $true
    }
    Start-Sleep -Milliseconds 150
  }
  return $false
}

function Format-IndexedDbProbeProcessMeta($Meta) {
  if (-not $Meta) {
    return $null
  }

  return [ordered]@{
    name = [string]$Meta.Name
    pid = [int]$Meta.ProcessId
    command_line = [string]$Meta.CommandLine
    created = [string]$Meta.CreationDate
  }
}

function Write-IndexedDbProbeResult($Result, [string]$Prefix = "") {
  foreach ($entry in $Result.GetEnumerator()) {
    $key = if ($Prefix) { "$Prefix$($entry.Key)" } else { [string]$entry.Key }
    $value = $entry.Value

    if ($value -is [System.Collections.IDictionary]) {
      Write-IndexedDbProbeResult $value "$key."
      continue
    }

    if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
      $joined = ($value | ForEach-Object { [string]$_ }) -join ","
      Write-Output ("{0}={1}" -f $key, $joined)
      continue
    }

    $text = if ($null -eq $value) { "" } else { [string]$value }
    $text = $text -replace "`r", "\\r"
    $text = $text -replace "`n", "\\n"
    Write-Output ("{0}={1}" -f $key, $text)
  }
}
