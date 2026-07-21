#!/bin/bash
# Destroy the orphan data/containerd ZFS dataset tree ONE NODE AT A TIME,
# leaf-first (topological order), with a pool-health check before every destroy.
#
# Background: 2026-07-20 a `zfs destroy -r data/containerd` wedged the metaslab
# allocator on the 85%-full / 26%-frag `data` pool (freeing ~1G of clone blocks
# via livelists in a single txg could not allocate spacemap metadata). The pool
# now imports only with zfs_recover=1. This script avoids a repeat by destroying
# one clone OR one snapshot per iteration, re-deriving the dependency graph each
# time, and aborting on the first sign of allocator stress (txg stall, D-state
# zfs thread, pool degraded). See ansible/docs/incident-2026-07-20-hme-srv-01-zfs-destroy-wedge.md.
#
# Usage:
#   DRY_RUN=1 bash destroy-containerd-datasets.sh   # print destruction order, destroy nothing
#   bash destroy-containerd-datasets.sh              # actually destroy
#   MAX_ITERS=400 SLEEP=0.5 bash destroy-containerd-datasets.sh
#
# Must run ON hme-srv-01 (the data pool host). Requires zfs_recover=1 already
# set (persistent in /etc/modprobe.d/zfs.conf) — the pool is already imported
# at boot; this script does NOT import anything.

set -u
POOL=data
BASE=data/containerd
DRY_RUN="${DRY_RUN:-0}"
MAX_ITERS="${MAX_ITERS:-400}"
SLEEP="${SLEEP:-0.5}"

abort() { echo "ABORT: $*" >&2; exit 2; }

# Health gate run before every real destroy.
health_ok() {
  local st
  st=$(zpool status "$POOL" 2>/dev/null) || abort "zpool status failed (pool gone?)"
  echo "$st" | grep -qE "^  pool: $POOL" || abort "pool $POOL missing from status"
  echo "$st" | grep -qE "DEGRADED|FAULTED|UNAVAIL|SUSPENDED" && abort "pool $POOL degraded/faulted/suspended"
  # txg must be advancing: read the latest txg number, wait, read again.
  local t1 t2
  t1=$(awk 'NR>2{print $1}' /proc/spl/kstat/zfs/$POOL/txgs 2>/dev/null | tail -1)
  sleep 2
  t2=$(awk 'NR>2{print $1}' /proc/spl/kstat/zfs/$POOL/txgs 2>/dev/null | tail -1)
  [ -n "$t1" ] && [ -n "$t2" ] || abort "cannot read txgs kstat"
  if [ "$t1" = "$t2" ]; then
    # No txg advanced in 2s — could be idle (no writes) or wedge. Distinguish:
    # a wedge has a txg stuck in S (syncing). Check for S state.
    if awk 'NR>2 && $3=="S"{found=1} END{exit !found}' /proc/spl/kstat/zfs/$POOL/txgs 2>/dev/null; then
      abort "txg $t2 stuck in S (syncing) — allocator wedge suspected, STOPPING"
    fi
    # idle, no S — OK to proceed (we are about to write anyway)
  fi
  # No D-state zfs kernel threads (the wedge signature).
  if ps -eo pid,stat,comm | awk '$2 ~ /D/ && $3 ~ /^z_|z_livelist|txg_sync|z_metaslab/ {found=1} END{exit !found}'; then
    abort "D-state zfs kernel thread detected — STOPPING"
  fi
  return 0
}

destroy_one() {
  local kind="$1" target="$2"
  if [ "$DRY_RUN" = "1" ]; then
    echo "DRY [$kind] $target"
    HIDDEN["$target"]=1
    return 0
  fi
  health_ok || abort "health check failed before $kind $target"
  if ! zfs destroy "$target" 2>&1; then
    abort "zfs destroy $target failed"
  fi
  echo "    [$kind] $target  (free: $(zpool list -H -o free $POOL))"
  sleep "$SLEEP"
}

count=0
# In DRY_RUN, "destroyed" nodes are recorded here so the simulated graph
# evolves across iterations (otherwise the same leaf is picked forever).
declare -A HIDDEN=()

while [ "$count" -lt "$MAX_ITERS" ]; do
  # Refresh dataset (name,origin) and snapshot lists.
  declare -A ORIG=() DSN=()
  while IFS=$'\t' read -r name origin; do
    [ -n "$name" ] || continue
    [ -n "${HIDDEN[$name]+x}" ] && continue          # simulated-removed dataset
    DSN["$name"]=1
    [ "$origin" != "-" ] && [ -n "$origin" ] && [ -z "${HIDDEN[$origin]+x}" ] && ORIG["$origin"]=1
  done < <(zfs list -H -o name,origin -r "$BASE" 2>/dev/null)

  mapfile -t SNAPS < <(zfs list -H -t snapshot -o name -r "$BASE" 2>/dev/null)
  # Filter hidden snapshots out of SNAPS for the simulation.
  if [ "${#HIDDEN[@]}" -gt 0 ]; then
    snaps2=()
    for s in "${SNAPS[@]}"; do [ -n "$s" ] && [ -z "${HIDDEN[$s]+x}" ] && snaps2+=("$s"); done
    SNAPS=("${snaps2[@]}")
  fi

  # If base is already gone, we are done.
  if [ -z "${DSN[$BASE]+x}" ] && [ "${#SNAPS[@]}" -eq 0 ]; then
    echo "DONE: $BASE fully removed ($count destroys)"
    break
  fi

  # 1) Destroy one unreferenced snapshot (no clone has it as origin).
  did=0
  for s in "${SNAPS[@]}"; do
    [ -z "$s" ] && continue
    if [ -z "${ORIG[$s]+x}" ]; then
      destroy_one snapshot "$s"; count=$((count+1)); did=1; break
    fi
  done
  [ "$did" = "1" ] && continue

  # 2) Destroy one leaf dataset: no children, no snapshots of it, not the root.
  for name in "${!DSN[@]}"; do
    [ "$name" = "$BASE" ] && continue
    # has children?
    has_child=0; for d in "${!DSN[@]}"; do case "$d" in "$name"/*) has_child=1; break;; esac; done
    [ "$has_child" = "1" ] && continue
    # has snapshots?
    has_snap=0; for s in "${SNAPS[@]}"; do case "$s" in "$name"@*) has_snap=1; break;; esac; done
    [ "$has_snap" = "1" ] && continue
    destroy_one dataset "$name"; count=$((count+1)); did=1; break
  done
  [ "$did" = "1" ] && continue

  # 3) Root: destroy only when it has no children and no snapshots.
  root_child=0; for d in "${!DSN[@]}"; do case "$d" in "$BASE"/*) root_child=1; break;; esac; done
  root_snap=0;  for s in "${SNAPS[@]}"; do case "$s" in "$BASE"@*) root_snap=1; break;; esac; done
  if [ "$root_child" = "0" ] && [ "$root_snap" = "0" ] && [ -n "${DSN[$BASE]+x}" ]; then
    destroy_one dataset "$BASE"; count=$((count+1)); continue
  fi

  # 4) Stuck — remaining nodes all have dependencies we can't resolve.
  echo "STUCK: no destroyable node, but nodes remain:" >&2
  printf '  dataset: %s\n' "${!DSN[@]}" >&2
  printf '  snapshot: %s\n' "${SNAPS[@]}" >&2
  abort "cannot make progress (remaining nodes have unmet dependencies)"
done

echo "total destroys: $count (DRY_RUN=$DRY_RUN)"