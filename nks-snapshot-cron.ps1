# ==========================================
# NKS VolumeSnapshot Backup Solution
# PowerShell Cron Version
# ==========================================

param(
    [switch]$Init,
    [switch]$DryRun,
    [string]$ConfigFile = "config.json"
)

if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $ConfigFile = Join-Path -Path $PSScriptRoot -ChildPath $ConfigFile
}

$ErrorActionPreference = "Continue"

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

function Initialize-Config {
    Write-Host "========== NKS Snapshot Configuration ==========" -ForegroundColor Cyan
    $nksVersion = Get-NksVersionFromServer
    $apiVersion = Get-ApiVersion -NksVersion $nksVersion

    $retentionInput = Read-Host "Retention days (default: 7)"
    $retentionDays = 7
    if (-not [string]::IsNullOrWhiteSpace($retentionInput)) {
        try { $retentionDays = [int]$retentionInput; if ($retentionDays -lt 1) { $retentionDays = 7 } } catch { $retentionDays = 7 }
    }

    $nsInput = Read-Host "Namespaces (comma-separated, e.g., staging,monitoring,default)"
    $namespaces = if ([string]::IsNullOrWhiteSpace($nsInput)) { @("default") } else { ($nsInput -split ",").Trim() | Where-Object { $_ -ne "" } }

    $snapshotClass = Read-Host "SnapshotClass (default: nks-block-storage)"
    if ([string]::IsNullOrWhiteSpace($snapshotClass)) { $snapshotClass = "nks-block-storage" }

    @{
        retention_days = $retentionDays
        nks_version = $nksVersion
        namespaces = $namespaces
        snapshot_class = $snapshotClass
        api_version = $apiVersion
        created_at = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    } | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8

    Write-Host "Configuration saved to: $ConfigFile" -ForegroundColor Green
}

function Load-Config {
    if (-not (Test-Path $ConfigFile)) { Write-Host "[ERROR] Config file not found: $ConfigFile" -ForegroundColor Red; exit 1 }
    return (Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json)
}

function Remove-ExpiredSnapshots {
    param($Config, [string]$Namespace)
    $cutoffDate = (Get-Date).AddDays(-[int]$Config.retention_days)
    $snapshots = kubectl get volumesnapshots -n $Namespace -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $snapshots) { return 0 }
    $json = $snapshots | ConvertFrom-Json
    $deletedCount = 0
    foreach ($snap in $json.items) {
        $name = $snap.metadata.name
        if ($name -match "snapshot-.+-(\d{14})$") {
            try {
                $snapDate = [DateTime]::ParseExact($Matches[1], "yyyyMMddHHmmss", $null)
                if ($snapDate -lt $cutoffDate) {
                    if (-not $DryRun) { kubectl delete volumesnapshots $name -n $Namespace 2>$null | Out-Null }
                    $deletedCount++
                }
            } catch {}
        }
    }
    return $deletedCount
}

function New-SnapshotBackup {
    param($Config, [string]$Namespace)
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $pvcOutput = kubectl get pvc -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pvcOutput)) { return @{ Success = 0; Fail = 0 } }
    $successCount = 0; $failCount = 0
    foreach ($pvcName in ($pvcOutput.Split(" ") | Where-Object { $_ -ne "" })) {
        $snapshotName = "snapshot-$pvcName-$timestamp"
        if ($DryRun) { $successCount++; continue }
        $yamlContent = @"
apiVersion: $($Config.api_version)
kind: VolumeSnapshot
metadata:
  name: $snapshotName
  namespace: $Namespace
spec:
  volumeSnapshotClassName: $($Config.snapshot_class)
  source:
    persistentVolumeClaimName: $pvcName
"@
        $yamlContent | kubectl apply -f - 2>$null | Out-Null
        Start-Sleep -Seconds 10
        if ($LASTEXITCODE -eq 0) { $successCount++ } else { $failCount++ }
    }
    return @{ Success = $successCount; Fail = $failCount }
}

if ($Init) { Initialize-Config; exit 0 }
if (-not (Test-Path $ConfigFile)) { Write-Host "[INFO] Config file not found. Entering init mode..." -ForegroundColor Yellow; Initialize-Config; exit 0 }

$config = Load-Config
$currentNksVersion = Get-NksVersionFromServer
$currentApiVersion = Get-ApiVersion -NksVersion $currentNksVersion
if ($currentApiVersion -ne $config.api_version) {
    $config.nks_version = $currentNksVersion
    $config.api_version = $currentApiVersion
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigFile -Encoding UTF8
}

$totalSuccess = 0; $totalFail = 0; $totalDeleted = 0
foreach ($ns in $config.namespaces) {
    $totalDeleted += (Remove-ExpiredSnapshots -Config $config -Namespace $ns)
    $result = New-SnapshotBackup -Config $config -Namespace $ns
    $totalSuccess += $result.Success
    $totalFail += $result.Fail
}

Write-Host "Created: $totalSuccess, Failed: $totalFail, Deleted: $totalDeleted"
if ($totalFail -gt 0) { exit 1 }
exit 0
