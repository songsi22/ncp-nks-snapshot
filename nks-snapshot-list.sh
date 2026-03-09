#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
NAMESPACE_CSV=""
INIT_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init|-i) INIT_MODE=true; shift ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --namespaces) NAMESPACE_CSV="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ ! "$CONFIG_FILE" =~ ^([A-Za-z]:[\\/]|/) ]]; then
  CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE"
fi

check_deps() {
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

check_deps || { echo "kubectl/jq required"; exit 1; }

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
  echo "[INFO] Config file not found. Entering initialization..." >&2
  local nksVersion apiVersion ns_input snapshot_class created_at
  local -a raw_namespaces namespaces_arr
  nksVersion=$(get_nks_version)
  apiVersion=$(get_api_version "$nksVersion")
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

  read -r -p "SnapshotClass (default: nks-block-storage): " snapshot_class
  snapshot_class=${snapshot_class:-nks-block-storage}

  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  cat > "$CONFIG_FILE" <<EOF
{
  "namespaces": $(printf '%s\n' "${namespaces_arr[@]}" | jq -R . | jq -s .),
  "nks_version": "$nksVersion",
  "api_version": "$apiVersion",
  "snapshot_class": "$snapshot_class",
  "created_at": "$created_at"
}
EOF
  echo "[INFO] Config created: $CONFIG_FILE" >&2
}

if [[ "$INIT_MODE" == "true" ]]; then
  init_config_interactive
  exit 0
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  init_config_interactive
fi

if [[ -n "$NAMESPACE_CSV" ]]; then
  IFS=',' read -r -a namespaces <<< "$NAMESPACE_CSV"
else
  mapfile -t namespaces < <(jq -r '.namespaces[]' "$CONFIG_FILE")
fi

for ns in "${namespaces[@]}"; do
  ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
  [[ -z "$ns" ]] && continue
  echo "== Namespace: $ns =="
  kubectl get volumesnapshot -n "$ns" --sort-by=.metadata.creationTimestamp
done
