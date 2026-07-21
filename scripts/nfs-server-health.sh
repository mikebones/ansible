#!/usr/bin/env bash
# nfs-server-health.sh — full NFS-server snapshot. Run ON the NFS server
# (hme-srv-01), as root:  ssh administrator@192.168.1.231 'sudo bash -s' < $0
#
# Captures everything needed to diagnose an nfsd-stall / fresh-mount-hang:
# service state, nfsd thread count + D-state count, nfsstat totals + op mix,
# established :2049 clients, the server's OWN nfs-client mounts (incl. the
# self-loopback hard mounts + Longhorn CSI mounts), ZFS pool state, dmesg
# (NFS/OOM/blocked), load, and every D-state process on the box.
#
# Safe to run any time (read-only; no state change).

set -u

echo "=== $(date -Is)  host=$(hostname)  uptime ==="
uptime
echo

echo "=== nfs-kernel-server service ==="
systemctl status nfs-kernel-server --no-pager -l 2>/dev/null | sed -n '1,12p'
echo

echo "=== nfsd threads + D-state ==="
# /proc/fs/nfsd counts threads; check which are uninterruptible (D).
NFSD_PIDS=$(pgrep -x nfsd)
echo "nfsd PIDs: ${NFSD_PIDS:-<none>}"
echo "nfsd count: $(echo "${NFSD_PIDS}" | wc -l)"
DSTATES=""
for p in ${NFSD_PIDS}; do
  st=$(awk '{print $3}' /proc/$p/stat 2>/dev/null)
  [ "${st}" = "D" ] && DSTATES="${DSTATES} $p"
done
echo "nfsd in D-state:$(echo "${DSTATES}" | wc -w)${DSTATES}"
echo

echo "=== nfsstat -s (totals + op mix) ==="
nfsstat -s 2>/dev/null | sed -n '1,40p'
echo

echo "=== established clients to :2049 ==="
ss -tan state established '( sport = :2049 )' 2>/dev/null
echo

echo "=== this server's OWN nfs-client mounts (self-loopback + Longhorn CSI) ==="
awk '$3 ~ /nfs4?/ {print $1"\t"$2"\t"$3"\t"$4}' /proc/mounts
echo "  -- with mount options (third field shows soft/hard):"
mount | awk '$5 ~ /nfs4?/ {print $0}'
echo

echo "=== ZFS pool ==="
zpool list -v 2>/dev/null
echo "--- status:"
zpool status data 2>/dev/null | sed -n '1,30p'
echo "--- dataset usage:"
df -hT /data* 2>/dev/null
echo

echo "=== load + memory ==="
cat /proc/loadavg
free -h
echo

echo "=== all D-state processes (any user) ==="
for p in /proc/[0-9]*; do
  pid=${p##*/}
  st=$(awk '{print $3}' /proc/$p/stat 2>/dev/null) || continue
  if [ "${st}" = "D" ]; then
    comm=$(awk '{print $2}' /proc/$p/stat 2>/dev/null | tr -d '()')
    wchan=$(cat /proc/$p/wchan 2>/dev/null)
    echo "  pid=${pid} comm=${comm} wchan=${wchan}"
  fi
done
echo

echo "=== dmesg (NFS / OOM / blocked / hung_task) — last matches ==="
dmesg -T 2>/dev/null \
  | grep -iE 'nfs|server .* not responding|oom|killed process|blocked for more|hung_task' \
  | tail -40
echo
echo "=== done ==="