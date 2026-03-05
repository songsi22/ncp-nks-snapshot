param(
  [string]$ConfigFile = "config.json",
  [string[]]$Namespaces,
  [switch]$DryRun
)

function Get-ApiVersion {
  $v = kubectl version -o json 2>$null | ConvertFrom-Json
  $git = $v.serverVersion.gitVersion
  if ($git -match 'v?(\d+)\.(\d+)') {
    $n = [version]"$($Matches[1]).$($Matches[2])"
    if ($n -ge [version]"1.33") { return "snapshot.storage.k8s.io/v1" }
  }
  return "snapshot.storage.k8s.io/v1beta1"
}

if (-not (Test-Path $ConfigFile)) { Write-Host "Config not found: $ConfigFile" -ForegroundColor Red; exit 1 }
$cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
$targetNs = if ($Namespaces -and $Namespaces.Count -gt 0) { $Namespaces } else { $cfg.namespaces }
$api = Get-ApiVersion
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
    Write-Host "created: $name"
  }
}
