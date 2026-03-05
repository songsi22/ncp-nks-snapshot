#!/bin/bash
set -euo pipefail

CONFIG_FILE="config.json"
NAMESPACE_CSV=""
NAME=""
FROM=""
TO=""
EXPIRED=false
INTERACTIVE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
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

command -v kubectl >/dev/null || { echo "kubectl required"; exit 1; }
command -v jq >/dev/null || { echo "jq required"; exit 1; }
[[ -f "$CONFIG_FILE" ]] || { echo "Config not found: $CONFIG_FILE"; exit 1; }

if [[ -n "$NAMESPACE_CSV" ]]; then
  IFS=',' read -r -a namespaces <<< "$NAMESPACE_CSV"
else
  mapfile -t namespaces < <(jq -r '.namespaces[]' "$CONFIG_FILE")
fi

retention=$(jq -r '.retention_days' "$CONFIG_FILE")
if cutoff=$(date -d "$retention days ago" -u +%s 2>/dev/null); then :; else cutoff=$(date -v-"${retention}"d -u +%s); fi

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
  done < <(echo "$raw" | jq -r '.items[] | [.metadata.name,.metadata.creationTimestamp] | join("|")')
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
