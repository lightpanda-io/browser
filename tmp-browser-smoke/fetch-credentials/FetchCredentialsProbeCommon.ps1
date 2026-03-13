$script:Repo = "C:\Users\adyba\src\lightpanda-browser"
$script:Root = Join-Path $script:Repo "tmp-browser-smoke\fetch-credentials"
$script:BrowserExe = Join-Path $script:Repo "zig-out\bin\lightpanda.exe"

. "$script:Repo\tmp-browser-smoke\common\Win32Input.ps1"
. "$script:Repo\tmp-browser-smoke\tabs\TabProbeCommon.ps1"

function Reset-FetchProfile([string]$ProfileRoot) {
  $appDataRoot = Join-Path $ProfileRoot "lightpanda"
  $downloadsDir = Join-Path $appDataRoot "downloads"
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  New-Item -ItemType Directory -Force -Path $downloadsDir | Out-Null
  $env:APPDATA = $ProfileRoot
  $env:LOCALAPPDATA = $ProfileRoot
  return @{ AppDataRoot = $appDataRoot; DownloadsDir = $downloadsDir }
}

function Seed-FetchProfile([string]$AppDataRoot) {
@"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $AppDataRoot "browse-settings-v1.txt") -NoNewline
}

function Start-FetchServer([int]$Port, [int]$PeerPort, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath "python" -ArgumentList (Join-Path $script:Root "fetch_server.py"),"$Port","$PeerPort" -WorkingDirectory $script:Root -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Wait-FetchServer([int]$Port, [int]$Attempts = 30) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/healthz" -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Start-FetchBrowser([string]$StartupUrl, [string]$Stdout, [string]$Stderr) {
  return Start-Process -FilePath $script:BrowserExe -ArgumentList "browse",$StartupUrl,"--window_width","960","--window_height","640" -WorkingDirectory $script:Repo -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
}

function Format-FetchProbeProcessMeta($Meta) {
  if (-not $Meta) { return $null }
  return [ordered]@{
    name = [string]$Meta.Name
    pid = [int]$Meta.ProcessId
    command_line = [string]$Meta.CommandLine
    created = [string]$Meta.CreationDate
  }
}

function Write-FetchProbeResult($Result, [string]$Prefix = "") {
  foreach ($entry in $Result.GetEnumerator()) {
    $key = if ($Prefix) { "$Prefix$($entry.Key)" } else { [string]$entry.Key }
    $value = $entry.Value
    if ($value -is [System.Collections.IDictionary]) {
      Write-FetchProbeResult $value "$key."
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
