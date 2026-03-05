#!/bin/bash
set -euo pipefail

CONFIG_FILE="config.json"
NAMESPACE_CSV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --namespaces) NAMESPACE_CSV="$2"; shift 2 ;;
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

for ns in "${namespaces[@]}"; do
  ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
  [[ -z "$ns" ]] && continue
  echo "== Namespace: $ns =="
  kubectl get volumesnapshot -n "$ns"
done
