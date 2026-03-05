#!/bin/bash
set -euo pipefail

CONFIG_FILE="config.json"
DRY_RUN=false
NAMESPACE_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --namespaces) NAMESPACE_CSV="$2"; shift 2 ;;
    --dry-run|--dryrun) DRY_RUN=true; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl required"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE"; exit 1; }

if [[ -n "$NAMESPACE_CSV" ]]; then
  IFS=',' read -r -a namespaces <<< "$NAMESPACE_CSV"
else
  mapfile -t namespaces < <(jq -r '.namespaces[]' "$CONFIG_FILE")
fi

server=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "v1.0.0"' || echo "v1.0.0")
if [[ "$server" =~ v?([0-9]+)\.([0-9]+) ]] && { [[ "${BASH_REMATCH[1]}" -gt 1 ]] || { [[ "${BASH_REMATCH[1]}" -eq 1 ]] && [[ "${BASH_REMATCH[2]}" -ge 33 ]]; }; }; then
  api="snapshot.storage.k8s.io/v1"
else
  api="snapshot.storage.k8s.io/v1beta1"
fi

cls=$(jq -r '.snapshot_class' "$CONFIG_FILE")
ts=$(date +%Y%m%d%H%M%S)

for ns in "${namespaces[@]}"; do
  ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
  [[ -z "$ns" ]] && continue
  pvc=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  [[ -n "$pvc" ]] || continue
  for p in $pvc; do
    name="snapshot-${p}-${ts}"
    if [[ "$DRY_RUN" == "true" ]]; then echo "[DRY-RUN] create $name in $ns"; continue; fi
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: $api
kind: VolumeSnapshot
metadata:
  name: $name
  namespace: $ns
spec:
  volumeSnapshotClassName: $cls
  source:
    persistentVolumeClaimName: $p
EOF
    echo "created: $name"
  done
done
