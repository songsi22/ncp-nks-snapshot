param(
  [string]$ConfigFile = "config.json",
  [string[]]$Namespaces
)

if (-not (Test-Path $ConfigFile)) { Write-Host "Config not found: $ConfigFile" -ForegroundColor Red; exit 1 }
$cfg = Get-Content -Raw $ConfigFile | ConvertFrom-Json
$targetNs = if ($Namespaces -and $Namespaces.Count -gt 0) { $Namespaces } else { $cfg.namespaces }

foreach ($ns in $targetNs) {
  Write-Host "== Namespace: $ns ==" -ForegroundColor Cyan
  kubectl get volumesnapshots -n $ns
}
