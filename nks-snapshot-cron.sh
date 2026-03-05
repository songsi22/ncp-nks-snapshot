#!/bin/bash
set -euo pipefail

CONFIG_FILE="config.json"
DRY_RUN=false
INIT_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init|-i) INIT_MODE=true; shift ;;
    --dry-run|--dryrun) DRY_RUN=true; shift ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    *) CONFIG_FILE="$1"; shift ;;
  esac
done

check_deps() { command -v kubectl >/dev/null && command -v jq >/dev/null; }

get_nks_version() {
  local sv parsed
  sv=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "v1.0.0"' || echo "v1.0.0")
  parsed=$(echo "$sv" | sed -n -E 's/.*v?([0-9]+)\.([0-9]+).*/\1.\2/p' | head -n1)
  echo "${parsed:-1.0}"
}

get_api_version() {
  local major minor
  major=$(echo "$1" | cut -d. -f1)
  minor=$(echo "$1" | cut -d. -f2)
  if [[ "$major" -gt 1 ]] || [[ "$major" -eq 1 && "$minor" -ge 33 ]]; then
    echo "snapshot.storage.k8s.io/v1"
  else
    echo "snapshot.storage.k8s.io/v1beta1"
  fi
}

init_config() {
  local nks api retention ns_input namespaces snapshot_class created_at
  nks=$(get_nks_version)
  api=$(get_api_version "$nks")
  read -p "Retention days (default: 7): " retention
  retention=${retention:-7}
  read -p "Namespaces (comma-separated, e.g., staging,monitoring,default): " ns_input
  if [[ -z "$ns_input" ]]; then namespaces='["default"]'; else namespaces=$(echo "$ns_input" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' | jq -R . | jq -s .); fi
  read -p "SnapshotClass (default: nks-block-storage): " snapshot_class
  snapshot_class=${snapshot_class:-nks-block-storage}
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$CONFIG_FILE" <<EOF
{
  "retention_days": $retention,
  "nks_version": "$nks",
  "namespaces": $namespaces,
  "snapshot_class": "$snapshot_class",
  "api_version": "$api",
  "created_at": "$created_at"
}
EOF
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1
}

remove_expired() {
  local ns="$1" retention cutoff snapshots name deleted=0
  retention=$(jq -r '.retention_days' "$CONFIG_FILE")
  if cutoff=$(date -d "$retention days ago" +%Y%m%d 2>/dev/null); then :; else cutoff=$(date -v-"${retention}"d +%Y%m%d); fi
  snapshots=$(kubectl get volumesnapshot -n "$ns" -o json 2>/dev/null || true)
  [[ -n "$snapshots" ]] || { echo 0; return; }
  while IFS= read -r name; do
    [[ "$name" =~ snapshot-.+-([0-9]{14})$ ]] || continue
    [[ "${BASH_REMATCH[1]:0:8}" < "$cutoff" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then ((deleted++)); else kubectl delete volumesnapshot "$name" -n "$ns" >/dev/null 2>&1 && ((deleted++)); fi
  done < <(echo "$snapshots" | jq -r '.items[].metadata.name')
  echo "$deleted"
}

create_snapshots() {
  local ns="$1" api cls pvc ts s=0 f=0 snap
  api=$(jq -r '.api_version' "$CONFIG_FILE")
  cls=$(jq -r '.snapshot_class' "$CONFIG_FILE")
  pvc=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  [[ -n "$pvc" ]] || { echo "0 0"; return; }
  ts=$(date +%Y%m%d%H%M%S)
  for p in $pvc; do
    snap="snapshot-${p}-${ts}"
    if [[ "$DRY_RUN" == "true" ]]; then ((s++)); continue; fi
    cat <<EOF | kubectl apply -f - >/dev/null 2>&1 && ((s++)) || ((f++))
apiVersion: $api
kind: VolumeSnapshot
metadata:
  name: $snap
  namespace: $ns
spec:
  volumeSnapshotClassName: $cls
  source:
    persistentVolumeClaimName: $p
EOF
  done
  echo "$s $f"
}

check_deps || { echo "kubectl/jq required"; exit 1; }
if [[ "$INIT_MODE" == "true" ]]; then init_config; exit 0; fi
if ! load_config; then echo "[INFO] Config missing. Entering init mode..."; init_config; exit 0; fi

current=$(get_nks_version)
api=$(get_api_version "$current")
if [[ "$(jq -r '.api_version' "$CONFIG_FILE")" != "$api" ]]; then
  jq --arg n "$current" --arg a "$api" '.nks_version=$n | .api_version=$a' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi

total_s=0; total_f=0; total_d=0
mapfile -t namespaces < <(jq -r '.namespaces[]' "$CONFIG_FILE")
for ns in "${namespaces[@]}"; do
  d=$(remove_expired "$ns"); total_d=$((total_d + d))
  read -r s f < <(create_snapshots "$ns")
  total_s=$((total_s + s)); total_f=$((total_f + f))
done
echo "Created: $total_s, Failed: $total_f, Deleted: $total_d"
[[ "$total_f" -eq 0 ]]
