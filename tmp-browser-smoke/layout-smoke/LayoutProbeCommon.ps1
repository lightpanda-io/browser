$ErrorActionPreference = "Stop"

function Get-ProcessCommandLine($TargetPid) {
  $meta = Get-CimInstance Win32_Process -Filter "ProcessId=$TargetPid" -ErrorAction SilentlyContinue |
    Select-Object Name,ProcessId,CommandLine,CreationDate
  if ($meta) { return [string]$meta.CommandLine }
  return ""
}

function Stop-VerifiedProcess($TargetPid) {
  if (-not $TargetPid) { return }
  $cmd = Get-ProcessCommandLine $TargetPid
  if ($cmd -and $cmd -notmatch "codex\\.js|@openai/codex") {
    try {
      Stop-Process -Id $TargetPid -Force -ErrorAction Stop
    } catch {
      if (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue) { throw }
    }
  }
}

function Wait-HttpReady($Url) {
  for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    try {
      $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
      if ($resp.StatusCode -eq 200) { return $true }
    } catch {}
  }
  return $false
}

function Reset-ProfileRoot($ProfileRoot) {
  cmd /c "rmdir /s /q `"$ProfileRoot`"" | Out-Null
  $appDataRoot = Join-Path $ProfileRoot "lightpanda"
  New-Item -ItemType Directory -Force -Path $appDataRoot | Out-Null
  @"
lightpanda-browse-settings-v1
restore_previous_session	0
allow_script_popups	0
default_zoom_percent	100
homepage_url	
"@ | Set-Content -Path (Join-Path $appDataRoot "browse-settings-v1.txt") -NoNewline
}

function Wait-Screenshot($Path) {
  $stableCount = 0
  $lastLength = -1
  $lastWriteTime = $null
  for ($i = 0; $i -lt 80; $i++) {
    Start-Sleep -Milliseconds 250
    if (-not (Test-Path $Path)) {
      continue
    }
    $item = Get-Item $Path
    if ($item.Length -le 0) {
      continue
    }
    if ($item.Length -eq $lastLength -and $lastWriteTime -ne $null -and $item.LastWriteTimeUtc -eq $lastWriteTime) {
      $stableCount++
      if ($stableCount -ge 3) { return $true }
    } else {
      $stableCount = 0
      $lastLength = $item.Length
      $lastWriteTime = $item.LastWriteTimeUtc
    }
  }
  return $false
}

function Read-Pixel($Bitmap, [int]$X, [int]$Y) {
  $c = $Bitmap.GetPixel($X, $Y)
  return [ordered]@{
    r = [int]$c.R
    g = [int]$c.G
    b = [int]$c.B
    a = [int]$c.A
  }
}

function Test-ApproxColor($Pixel, [int]$R, [int]$G, [int]$B, [int]$Tolerance) {
  return ([math]::Abs($Pixel.r - $R) -le $Tolerance) -and
         ([math]::Abs($Pixel.g - $G) -le $Tolerance) -and
         ([math]::Abs($Pixel.b - $B) -le $Tolerance)
}

function Find-ColorBounds($Path, [scriptblock]$Predicate) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width
        $minY = $bmp.Height
        $maxX = -1
        $maxY = -1
        for ($y = 0; $y -lt $bmp.Height; $y++) {
          for ($x = 0; $x -lt $bmp.Width; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if (& $Predicate $c) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minY) { $minY = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
        if ($maxX -lt 0 -or $maxY -lt 0) {
          throw "target color not found in $Path"
        }
        return [ordered]@{
          left = $minX
          top = $minY
          right = $maxX
          bottom = $maxY
          width = $maxX - $minX + 1
          height = $maxY - $minY + 1
        }
      }
      finally {
        $bmp.Dispose()
      }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}

function Find-ColorBoundsRegion(
  $Path,
  [scriptblock]$Predicate,
  [int]$MinX = 0,
  [int]$MinY = 0,
  [int]$MaxX = 2147483647,
  [int]$MaxY = 2147483647
) {
  Add-Type -AssemblyName System.Drawing
  for ($attempt = 0; $attempt -lt 20; $attempt++) {
    try {
      $bmp = [System.Drawing.Bitmap]::new($Path)
      try {
        $minX = $bmp.Width
        $minY = $bmp.Height
        $maxX = -1
        $maxY = -1
        $scanMinX = [Math]::Max(0, $MinX)
        $scanMinY = [Math]::Max(0, $MinY)
        $scanMaxX = [Math]::Min($bmp.Width - 1, $MaxX)
        $scanMaxY = [Math]::Min($bmp.Height - 1, $MaxY)
        for ($y = $scanMinY; $y -le $scanMaxY; $y++) {
          for ($x = $scanMinX; $x -le $scanMaxX; $x++) {
            $c = $bmp.GetPixel($x, $y)
            if (& $Predicate $c) {
              if ($x -lt $minX) { $minX = $x }
              if ($y -lt $minY) { $minY = $y }
              if ($x -gt $maxX) { $maxX = $x }
              if ($y -gt $maxY) { $maxY = $y }
            }
          }
        }
        if ($maxX -lt 0 -or $maxY -lt 0) {
          throw "target color not found in $Path"
        }
        return [ordered]@{
          left = $minX
          top = $minY
          right = $maxX
          bottom = $maxY
          width = $maxX - $minX + 1
          height = $maxY - $minY + 1
        }
      }
      finally {
        $bmp.Dispose()
      }
    } catch {
      if ($attempt -eq 19) { throw }
      Start-Sleep -Milliseconds 200
    }
  }
}
