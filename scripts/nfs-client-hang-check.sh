#!/usr/bin/env bash
# nfs-client-hang-check.sh — check whether a node's NFS mounts will hang a
# kubelet-1.30+ restart (cAdvisor statfs blocks on dead hard NFS mounts).
# Run ON the NFS client node (any worker / the control plane) as root:
#   ssh mcostas@192.168.1.249 'sudo bash /tmp/nfs-client-hang-check.sh'
#
# For every NFS mount we: classify soft vs hard, and statfs-probe it with a
# timed background process + kill -0 so a D-state statfs is reported HUNG
# without wedging the script. Hard mounts that HUNG are the ones that will
# block cAdvisor at kubelet startup and need a lazy-unmount (see
# unblock-kubelet-nfs-hang.sh). Soft mounts return errors and don't block.

set -u

echo "=== $(date -Is)  host=$(hostname) ==="
echo
echo "=== NFS mounts (proc/mounts) ==="
awk '$3 ~ /^nfs4?$/ {
  dev=$1; mp=$2; opts=$4
  soft = (opts ~ /,soft,|,softerr,/) ? "soft" : "hard"
  printf "%-6s  %-45s  %-40s  %s\n", soft, dev, mp, opts
}' /proc/mounts
echo

echo "=== statfs probe (per mount; HUNG = would block cAdvisor) ==="
# Read nfs mountpoints (col 2) + their device (col 1) and type (col 3).
HUNG=0
while read -r dev mp mtype opts rest; do
  [ "${mtype}" = "nfs" ] || [ "${mtype}" = "nfs4" ] || continue
  soft="hard"
  case "${opts}" in *,soft,*|*,softerr,*) soft="soft";; esac
  # Background a stat -f; poll liveness with kill -0 for up to 3s.
  ( stat -f "${mp}" >/dev/null 2>&1 ) &
  pid=$!
  hung=0
  for _ in 1 2 3 4 5 6; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "${pid}" 2>/dev/null; then
    hung=1
    kill -9 "${pid}" 2>/dev/null
  fi
  wait "${pid}" 2>/dev/null
  if [ "${hung}" = "1" ]; then
    echo "  HUNG   ${soft}  ${mp}  (${dev})"
    [ "${soft}" = "hard" ] && HUNG=$((HUNG+1))
  else
    echo "  ok     ${soft}  ${mp}  (${dev})"
  fi
done < /proc/mounts
echo
echo "=== hard NFS mounts that HUNG (block cAdvisor statfs): ${HUNG} ==="
echo
echo "=== D-state processes on this node ==="
for p in /proc/[0-9]*; do
  pid=${p##*/}
  st=$(awk '{print $3}' /proc/$p/stat 2>/dev/null) || continue
  if [ "${st}" = "D" ]; then
    comm=$(awk '{print $2}' /proc/$p/stat 2>/dev/null | tr -d '()')
    echo "  pid=${pid} comm=${comm} wchan=$(cat /proc/$p/wchan 2>/dev/null)"
  fi
done
echo
echo "=== kubelet state ==="
systemctl is-active kubelet 2>/dev/null
if [ "${HUNG}" -gt 0 ]; then
  echo
  echo "!! ${HUNG} dead HARD nfs mount(s) will block a kubelet-1.30+ restart."
  echo "!! Run unblock-kubelet-nfs-hang.sh to lazy-unmount them + restart kubelet."
fi