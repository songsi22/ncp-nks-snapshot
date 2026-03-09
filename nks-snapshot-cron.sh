#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
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

if [[ ! "$CONFIG_FILE" =~ ^([A-Za-z]:[\\/]|/) ]]; then
  CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
fi

# Initialize config if not exists (like other scripts)
if [[ ! -f "$CONFIG_FILE" ]] || [[ "$INIT_MODE" == "true" ]]; then
  init_config_interactive
  exit 0
fi

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 1
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1
}

check_deps() {
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

setup_kube_env() {
  if [[ -z "${KUBECONFIG:-}" ]]; then
    if [[ -f "$SCRIPT_DIR/kubeconfig" ]]; then
      export KUBECONFIG="$SCRIPT_DIR/kubeconfig"
    elif [[ -n "${HOME:-}" && -f "$HOME/.kube/config" ]]; then
      export KUBECONFIG="$HOME/.kube/config"
    fi
  fi
}

log_kube_env() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "<unavailable>")
  echo "[INFO] Runtime user=$(id -un)" >&2
  echo "[INFO] KUBECONFIG=${KUBECONFIG:-<unset>}" >&2
  echo "[INFO] kubectl-context=$ctx" >&2
}

get_nks_version() {
  local sv
  sv=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "v1.0.0"' || echo "v1.0.0")
  if [[ "$sv" =~ v?([0-9]+)\.([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    echo "1.0"
  fi
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

init_config_interactive() {
  local nks api retention ns_input namespaces snapshot_class created_at
  local -a raw_namespaces namespaces_arr
  nks=$(get_nks_version)
  api=$(get_api_version "$nks")
  read -p "Retention days (default: 7): " retention
  retention=${retention:-7}
  while true; do
    read -r -p "Namespaces (comma-separated, e.g., default,staging): " ns_input
    IFS=',' read -r -a raw_namespaces <<< "$ns_input"
    namespaces_arr=()
    for ns in "${raw_namespaces[@]}"; do
      ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
      [[ -n "$ns" ]] && namespaces_arr+=("$ns")
    done
    if [[ ${#namespaces_arr[@]} -gt 0 ]]; then
      break
    fi
    echo "[WARN] At least one namespace is required." >&2
  done
  namespaces=$(printf '%s\n' "${namespaces_arr[@]}" | jq -R . | jq -s .)
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

ensure_retention_days() {
  local retention input
  retention=$(jq -r '.retention_days // empty' "$CONFIG_FILE")
  if [[ "$retention" =~ ^[0-9]+$ ]] && [[ "$retention" -ge 1 ]]; then
    return 0
  fi

  if [[ -t 0 ]]; then
    echo "[WARN] retention_days is missing in $CONFIG_FILE."
    while true; do
      read -r -p "Retention days (default: 7): " input
      input=${input:-7}
      if [[ "$input" =~ ^[0-9]+$ ]] && [[ "$input" -ge 1 ]]; then
        jq --argjson r "$input" '.retention_days=$r' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        return 0
      fi
      echo "[WARN] Please enter an integer >= 1."
    done
  fi

  echo "[ERROR] retention_days is missing in $CONFIG_FILE." >&2
  echo "[ERROR] Non-interactive mode detected. Run manual init first: ./nks-snapshot-cron.sh --init" >&2
  exit 1
}

remove_expired() {
  local ns="$1" retention cutoff snapshots name deleted=0
  retention=$(jq -r '.retention_days' "$CONFIG_FILE")
  if cutoff=$(date -d "$retention days ago" +%Y%m%d 2>/dev/null); then :; else cutoff=$(date -v-"${retention}"d +%Y%m%d); fi
  if ! snapshots=$(kubectl get volumesnapshot -n "$ns" -o json 2>&1); then
    echo "[WARN] Failed to list snapshots ns=$ns" >&2
    echo "[WARN] kubectl: $snapshots" >&2
    echo 0
    return
  fi
  [[ -n "$snapshots" ]] || { echo 0; return; }
  while IFS= read -r name; do
    [[ "$name" =~ snapshot-.+-([0-9]{14})$ ]] || continue
    [[ "${BASH_REMATCH[1]:0:8}" < "$cutoff" ]] || continue
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN][DELETE] ns=$ns snapshot=$name" >&2
      ((deleted++))
    else
      if kubectl delete volumesnapshot "$name" -n "$ns" >/dev/null 2>&1; then
        echo "[OK][DELETE] ns=$ns snapshot=$name" >&2
        ((deleted++))
      else
        echo "[FAIL][DELETE] ns=$ns snapshot=$name" >&2
      fi
    fi
  done < <(echo "$snapshots" | jq -r '.items[].metadata.name')
  echo "$deleted"
}

create_snapshots() {
  local ns="$1" api cls pvc ts s=0 f=0 snap apply_output
  api=$(jq -r '.api_version' "$CONFIG_FILE")
  cls=$(jq -r '.snapshot_class' "$CONFIG_FILE")
  if ! pvc=$(kubectl get pvc -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>&1); then
    echo "[WARN] Failed to list PVCs ns=$ns" >&2
    echo "[WARN] kubectl: $pvc" >&2
    echo "0 0"
    return
  fi
  if [[ -z "$pvc" ]]; then
    echo "[INFO] No PVC found ns=$ns" >&2
    echo "0 0"
    return
  fi
  ts=$(date +%Y%m%d%H%M%S)
  for p in $pvc; do
    snap="snapshot-${p}-${ts}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN][CREATE] ns=$ns pvc=$p snapshot=$snap" >&2
      ((s++))
      continue
    fi
    if apply_output=$(cat <<EOF | kubectl apply -f - 2>&1
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
    ); then
      echo "[OK][CREATE] ns=$ns pvc=$p snapshot=$snap" >&2
      ((s++))
    else
      echo "[FAIL][CREATE] ns=$ns pvc=$p snapshot=$snap" >&2
      echo "[FAIL][CREATE][DETAIL] $apply_output" >&2
      ((f++))
    fi
  done
  echo "$s $f"
}

check_deps || { echo "kubectl/jq required"; exit 1; }
setup_kube_env
log_kube_env
ensure_retention_days

current=$(get_nks_version)
api=$(get_api_version "$current")
if [[ "$(jq -r '.api_version' "$CONFIG_FILE")" != "$api" ]]; then
  jq --arg n "$current" --arg a "$api" '.nks_version=$n | .api_version=$a' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
fi

total_s=0; total_f=0; total_d=0
mapfile -t namespaces < <(jq -r '.namespaces[]' "$CONFIG_FILE")
# Remove duplicate namespaces
IFS=$'\n' namespaces=($(sort -u <<<"${namespaces[*]}")); unset IFS

for ns in "${namespaces[@]}"; do
  ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
  [[ -z "$ns" ]] && continue
  echo "[INFO] Processing namespace: $ns" >&2
  d=$(remove_expired "$ns"); total_d=$((total_d + d))
  result=$(create_snapshots "$ns")
  s=$(echo "$result" | cut -d' ' -f1)
  f=$(echo "$result" | cut -d' ' -f2)
  total_s=$((total_s + s)); total_f=$((total_f + f))
done
echo "Created: $total_s, Failed: $total_f, Deleted: $total_d"
if [[ "$total_f" -gt 0 ]]; then
  exit 1
fi
