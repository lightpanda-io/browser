$script:BookmarkProbeDir = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) "lightpanda"
$script:BookmarkProbeFile = Join-Path $script:BookmarkProbeDir "bookmarks.txt"

function Get-BookmarkProbeFile {
  return $script:BookmarkProbeFile
}

function Backup-BookmarkProbeFile {
  if (-not (Test-Path $script:BookmarkProbeDir)) {
    New-Item -ItemType Directory -Path $script:BookmarkProbeDir -Force | Out-Null
  }
  $backup = "$script:BookmarkProbeFile.codex-bak"
  Remove-Item $backup -Force -ErrorAction SilentlyContinue
  if (Test-Path $script:BookmarkProbeFile) {
    Copy-Item $script:BookmarkProbeFile $backup -Force
  }
  return $backup
}

function Restore-BookmarkProbeFile([string]$BackupPath) {
  if (Test-Path $BackupPath) {
    Move-Item $BackupPath $script:BookmarkProbeFile -Force
    return
  }
  Remove-Item $script:BookmarkProbeFile -Force -ErrorAction SilentlyContinue
}

function Set-BookmarkProbeEntries([string[]]$Entries) {
  if (-not (Test-Path $script:BookmarkProbeDir)) {
    New-Item -ItemType Directory -Path $script:BookmarkProbeDir -Force | Out-Null
  }
  if (-not $Entries -or $Entries.Count -eq 0) {
    Remove-Item $script:BookmarkProbeFile -Force -ErrorAction SilentlyContinue
    return
  }
  [System.IO.File]::WriteAllLines($script:BookmarkProbeFile, $Entries)
}

function Get-BookmarkProbeContent {
  if (-not (Test-Path $script:BookmarkProbeFile)) {
    return ""
  }
  return [string](Get-Content $script:BookmarkProbeFile -Raw)
}

function Wait-BookmarkProbeContains([string]$Needle, [int]$Attempts = 40, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    $content = Get-BookmarkProbeContent
    if ($content -match [regex]::Escape($Needle)) {
      return $content
    }
  }
  throw "bookmark file did not contain expected entry"
}

function Wait-BookmarkProbeNotContains([string]$Needle, [int]$Attempts = 40, [int]$DelayMs = 200) {
  for ($i = 0; $i -lt $Attempts; $i++) {
    Start-Sleep -Milliseconds $DelayMs
    $content = Get-BookmarkProbeContent
    if ($content -notmatch [regex]::Escape($Needle)) {
      return $content
    }
  }
  throw "bookmark file still contained removed entry"
}
