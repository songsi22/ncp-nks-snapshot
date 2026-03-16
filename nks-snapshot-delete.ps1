param(
  [switch]$Init,
  [string]$ConfigFile = "config.json",
  [string[]]$Namespaces,
  [string]$Name,
  [datetime]$From,
  [datetime]$To,
  [switch]$Expired,
  [switch]$Interactive,
  [switch]$DryRun
)

if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
  $ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath $ConfigFile
}

function Get-ServerVersion {
  $versionInfo = kubectl version -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $versionInfo) { return "v1.0.0" }
  try {
    $json = $versionInfo | ConvertFrom-Json
    return ($json.serverVersion.gitVersion | ForEach-Object { if ($_){$_} else {"v1.0.0"} })
  } catch { return "v1.0.0" }
}

function Get-NksVersionFromServer {
  $serverVersion = Get-ServerVersion
  if ($serverVersion -match 'v?(\d+)\.(\d+)') { return "$($Matches[1]).$($Matches[2])" }
  return "1.0"
}

function Get-ApiVersion {
  param([string]$NksVersion)
  try { $nksVer = [version]$NksVersion } catch { $nksVer = [version]"1.0" }
  if ($nksVer -ge [version]"1.33") { return "snapshot.storage.k8s.io/v1" }
  return "snapshot.storage.k8s.io/v1beta1"
}

function Initialize-ConfigMinimal {
  Write-Host "[INFO] Config file not found. Entering initialization..." -ForegroundColor Yellow
  $nksVersion = Get-NksVersionFromServer
  $apiVersion = Get-ApiVersion -NksVersion $nksVersion
  
  $namespaces = @()
  while ($namespaces.Count -eq 0) {
    $nsInput = Read-Host "Namespaces (comma-separated, e.g., default,staging)"
    if (-not [string]::IsNullOrWhiteSpace($nsInput)) {
      $namespaces = ($nsInput -split ",").Trim() | Where-Object { $_ -ne "" }
    }
    if ($namespaces.Count -eq 0) {
      Write-Host "[WARN] At least one namespace is required." -ForegroundColor Yellow
    }
  }

  $snapshotClass = Read-Host "SnapshotClass (default: nks-block-storage)"
  if ([string]::IsNullOrWhiteSpace($snapshotClass)) { $snapshotClass = "nks-block-storage" }
  
  $minimalConfig = @{
    namespaces = $namespaces
    nks_version = $nksVersion
    api_version = $apiVersion
    snapshot_class = $snapshotClass
    created_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
  }
  
  $minimalConfig | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
  Write-Host "[INFO] Config created: $ConfigFile" -ForegroundColor Green
}

if ($Init) { Initialize-ConfigMinimal; exit 0 }
if (-not (Test-Path $ConfigFile)) { Initialize-ConfigMinimal }
$cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
$targetNs = if ($Namespaces -and $Namespaces.Count -gt 0) { $Namespaces } else { $cfg.namespaces }
$cutoff = $null
if ($Expired) {
  if ($null -eq $cfg.retention_days -or [string]::IsNullOrWhiteSpace([string]$cfg.retention_days)) {
    Write-Host "[ERROR] --Expired requires retention_days in $ConfigFile." -ForegroundColor Red
    Write-Host "[ERROR] Run .\nks-snapshot-cron.ps1 -Init to configure retention_days." -ForegroundColor Red
    exit 1
  }
  $cutoff = (Get-Date).AddDays(-[int]$cfg.retention_days)
}
$hasFilter = $false
if ($Name -or $From -or $To -or $Expired) { $hasFilter = $true }
$interactiveMode = $Interactive -or (-not $hasFilter)

function Match-Snapshot($snapName, $createdAt) {
  if ($Name -and $snapName -ne $Name) { return $false }
  if ($From -and $createdAt -lt $From) { return $false }
  if ($To -and $createdAt -gt $To) { return $false }
  if ($Expired -and $createdAt -ge $cutoff) { return $false }
  return $true
}

function Parse-Selection {
  param([string]$InputText, [int]$MaxIndex)
  $result = New-Object System.Collections.Generic.HashSet[int]
  if ([string]::IsNullOrWhiteSpace($InputText)) { return @() }
  if ($InputText.Trim().ToLower() -eq "all") {
    1..$MaxIndex | ForEach-Object { [void]$result.Add($_) }
    return @($result | Sort-Object)
  }

  foreach ($token in ($InputText -split ",")) {
    $t = $token.Trim()
    if ($t -match '^(\d+)-(\d+)$') {
      $start = [int]$Matches[1]
      $end = [int]$Matches[2]
      if ($start -gt $end) { $tmp = $start; $start = $end; $end = $tmp }
      for ($i = $start; $i -le $end; $i++) {
        if ($i -ge 1 -and $i -le $MaxIndex) { [void]$result.Add($i) }
      }
    } elseif ($t -match '^\d+$') {
      $idx = [int]$t
      if ($idx -ge 1 -and $idx -le $MaxIndex) { [void]$result.Add($idx) }
    }
  }
  return @($result | Sort-Object)
}

$candidates = @()
foreach ($ns in $targetNs) {
  $raw = kubectl get volumesnapshots -n $ns -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $raw) { continue }
  $items = ($raw | ConvertFrom-Json).items
  foreach ($it in $items) {
    $snapName = $it.metadata.name
    $createdAt = [datetime]$it.metadata.creationTimestamp
    if (-not (Match-Snapshot $snapName $createdAt)) { continue }
    $candidates += [PSCustomObject]@{
      Namespace = $ns
      Name = $snapName
      CreatedAt = $createdAt
    }
  }
}

if (-not $candidates -or $candidates.Count -eq 0) {
  Write-Host "No matching snapshots found." -ForegroundColor Yellow
  exit 0
}

$candidates = $candidates | Sort-Object CreatedAt

$targets = $candidates
if ($interactiveMode) {
  Write-Host "Select snapshots to delete:" -ForegroundColor Cyan
  $i = 1
  foreach ($c in $candidates) {
    Write-Host ("[{0}] {1}  {2}  {3}" -f $i, $c.Namespace, $c.Name, $c.CreatedAt.ToString("s"))
    $i++
  }
  $sel = Read-Host "Enter selection (e.g., 1,3-5 or all)"
  $idxs = Parse-Selection -InputText $sel -MaxIndex $candidates.Count
  if (-not $idxs -or $idxs.Count -eq 0) {
    Write-Host "No valid selection. Abort." -ForegroundColor Yellow
    exit 0
  }
  $targets = @()
  foreach ($idx in $idxs) { $targets += $candidates[$idx - 1] }
}

if (-not $DryRun) {
  $confirm = Read-Host "Delete $($targets.Count) snapshot(s)? Type 'y' to continue"
  if ($confirm -notin @("y", "Y", "yes", "YES")) {
    Write-Host "Abort." -ForegroundColor Yellow
    exit 0
  }
}

foreach ($t in $targets) {
  if ($DryRun) {
    Write-Host "[DRY-RUN] delete $($t.Name) in $($t.Namespace)"
  } else {
    kubectl delete volumesnapshots $($t.Name) -n $($t.Namespace) | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "deleted: $($t.Name) ($($t.Namespace))" }
  }
}
