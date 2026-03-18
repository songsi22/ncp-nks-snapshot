param(
  [switch]$Init,
  [string]$ConfigFile = "config.json",
  [string[]]$Namespaces,
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
$api = $cfg.api_version
$cls = $cfg.snapshot_class
$ts = Get-Date -Format "yyyyMMddHHmmss"

foreach ($ns in $targetNs) {
  $pvc = kubectl get pvc -n $ns -o jsonpath='{.items[*].metadata.name}' 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pvc)) { continue }
  foreach ($p in ($pvc -split ' ' | Where-Object { $_ })) {
    $name = "snapshot-$p-$ts"
    if ($DryRun) { Write-Host "[DRY-RUN] create $name in $ns"; continue }
    @"
apiVersion: $api
kind: VolumeSnapshot
metadata:
  name: $name
  namespace: $ns
spec:
  volumeSnapshotClassName: $cls
  source:
    persistentVolumeClaimName: $p
"@ | kubectl apply -f - | Out-Null
    Start-Sleep -Seconds 10
    Write-Host "created: $name"
  }
}
