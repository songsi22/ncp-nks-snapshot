#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
NAMESPACE_CSV=""
NAME=""
FROM=""
TO=""
EXPIRED=false
INTERACTIVE=false
DRY_RUN=false
INIT_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init) INIT_MODE=true; shift ;;
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --namespaces) NAMESPACE_CSV="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --from) FROM="$2"; shift 2 ;;
    --to) TO="$2"; shift 2 ;;
    --expired) EXPIRED=true; shift ;;
    --interactive|-i) INTERACTIVE=true; shift ;;
    --dry-run|--dryrun) DRY_RUN=true; shift ;;
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

if [[ "$EXPIRED" == "true" ]]; then
  retention=$(jq -r '.retention_days // empty' "$CONFIG_FILE")
  if [[ -z "$retention" ]]; then
    echo "[ERROR] --expired requires retention_days in $CONFIG_FILE." >&2
    echo "[ERROR] Run ./nks-snapshot-cron.sh --init to configure retention_days." >&2
    exit 1
  fi
  if cutoff=$(date -d "$retention days ago" -u +%s 2>/dev/null); then :; else cutoff=$(date -v-"${retention}"d -u +%s); fi
fi

candidates=()
for ns in "${namespaces[@]}"; do
  ns=$(echo "$ns" | sed 's/^ *//;s/ *$//')
  [[ -z "$ns" ]] && continue
  raw=$(kubectl get volumesnapshot -n "$ns" -o json 2>/dev/null || true)
  [[ -n "$raw" ]] || continue
  while IFS='|' read -r snap created; do
    [[ -n "$NAME" && "$snap" != "$NAME" ]] && continue
    created_epoch=$(date -u -d "$created" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$created" +%s)
    if [[ -n "$FROM" ]]; then from_epoch=$(date -u -d "$FROM" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$FROM" +%s); [[ "$created_epoch" -lt "$from_epoch" ]] && continue; fi
    if [[ -n "$TO" ]]; then to_epoch=$(date -u -d "$TO" +%s 2>/dev/null || date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$TO" +%s); [[ "$created_epoch" -gt "$to_epoch" ]] && continue; fi
    if [[ "$EXPIRED" == "true" && "$created_epoch" -ge "$cutoff" ]]; then continue; fi
    candidates+=("$ns|$snap|$created")
  done < <(echo "$raw" | jq -r '.items | sort_by(.metadata.creationTimestamp)[] | [.metadata.name,.metadata.creationTimestamp] | join("|")')
done

if [[ "${#candidates[@]}" -eq 0 ]]; then
  echo "No matching snapshots found."
  exit 0
fi

has_filter=false
if [[ -n "$NAME" || -n "$FROM" || -n "$TO" || "$EXPIRED" == "true" ]]; then
  has_filter=true
fi
interactive_mode="$INTERACTIVE"
if [[ "$interactive_mode" != "true" && "$has_filter" != "true" ]]; then
  interactive_mode=true
fi

targets=()
if [[ "$interactive_mode" == "true" ]]; then
  echo "Select snapshots to delete:"
  idx=1
  for c in "${candidates[@]}"; do
    IFS='|' read -r ns snap created <<< "$c"
    echo "[$idx] $ns  $snap  $created"
    idx=$((idx + 1))
  done
  read -r -p "Enter selection (e.g., 1,3-5 or all): " selection
  if [[ "$selection" == "all" ]]; then
    targets=("${candidates[@]}")
  else
    declare -A selected=()
    IFS=',' read -r -a tokens <<< "$selection"
    for token in "${tokens[@]}"; do
      token=$(echo "$token" | sed 's/^ *//;s/ *$//')
      if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        start=${BASH_REMATCH[1]}
        end=${BASH_REMATCH[2]}
        if (( start > end )); then tmp=$start; start=$end; end=$tmp; fi
        for ((i=start; i<=end; i++)); do
          if (( i>=1 && i<=${#candidates[@]} )); then selected[$i]=1; fi
        done
      elif [[ "$token" =~ ^[0-9]+$ ]]; then
        i=$token
        if (( i>=1 && i<=${#candidates[@]} )); then selected[$i]=1; fi
      fi
    done
    for i in "${!selected[@]}"; do
      targets+=("${candidates[$((i-1))]}")
    done
  fi
else
  targets=("${candidates[@]}")
fi

if [[ "${#targets[@]}" -eq 0 ]]; then
  echo "No valid selection. Abort."
  exit 0
fi

if [[ "$DRY_RUN" != "true" ]]; then
  read -r -p "Delete ${#targets[@]} snapshot(s)? Type 'y' to continue: " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" && "$confirm" != "yes" && "$confirm" != "YES" ]]; then
    echo "Abort."
    exit 0
  fi
fi

for t in "${targets[@]}"; do
  IFS='|' read -r ns snap created <<< "$t"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] delete $snap in $ns"
  else
    kubectl delete volumesnapshot "$snap" -n "$ns" >/dev/null && echo "deleted: $snap ($ns)"
  fi
done
