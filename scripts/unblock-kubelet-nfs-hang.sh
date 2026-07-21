#!/usr/bin/env bash
# unblock-kubelet-nfs-hang.sh — recover a node whose kubelet hung at startup on
# a dead HARD NFSv4 mount (cAdvisor statfs blocks indefinitely on it; kubelet
# ignores SIGTERM and the node goes NotReady).
#
# Run ON the affected node as root:
#   ssh mcostas@192.168.1.166 'sudo bash /tmp/unblock-kubelet-nfs-hang.sh'
#
# What this does:
#   1. Identify every HARD nfs4 mount whose statfs hangs (timed probe).
#   2. Lazy-unmount (umount -l) ONLY those dead hard mounts. Lazy-unmount
#      detaches the mountpoint now so new lookups stop, while existing
#      blocked references wind down — it does NOT block on the dead server.
#      SOFT nfs mounts and Longhorn CSI (softerr) mounts are LEFT ALONE because
#      they don't block cAdvisor and the kubelet can reconcile them itself.
#   3. Restart the kubelet. cAdvisor no longer blocks → node goes Ready.
#
# This is the one-off recovery used to unblock rp5-0 at the 1.30 hop. It is NOT
# baked into the kubeadm_upgrade role (deliberate — confirm the dead mount
# before nuking it).

set -u

echo "=== $(date -Is)  host=$(hostname) ==="

DEAD=()
echo "=== finding dead HARD nfs4 mounts ==="
while read -r dev mp mtype opts rest; do
  [ "${mtype}" = "nfs4" ] || [ "${mtype}" = "nfs" ] || continue
  # only hard mounts (no soft/softerr) block cAdvisor indefinitely
  case "${opts}" in *,soft,*|*,softerr,*) continue;; esac
  ( stat -f "${mp}" >/dev/null 2>&1 ) &
  pid=$!
  hung=0
  for _ in 1 2 3 4 5 6 7 8; do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "${pid}" 2>/dev/null; then
    hung=1
    kill -9 "${pid}" 2>/dev/null
  fi
  wait "${pid}" 2>/dev/null
  if [ "${hung}" = "1" ]; then
    echo "  DEAD hard:  ${mp}  (${dev})  -> will lazy-unmount"
    DEAD+=("${mp}")
  else
    echo "  ok hard:    ${mp}  (${dev})  -> keep"
  fi
done < /proc/mounts

if [ "${#DEAD[@]}" -eq 0 ]; then
  echo "=== no dead hard nfs mounts found; kubelet hang is NOT NFS. Aborting. ==="
  exit 0
fi

echo
echo "=== lazy-unmounting ${#DEAD[@]} dead hard nfs mount(s) ==="
for mp in "${DEAD[@]}"; do
  echo "  umount -l ${mp}"
  umount -l "${mp}" && echo "    ok" || echo "    FAILED (rc=$?)"
done

echo
echo "=== restarting kubelet ==="
systemctl restart kubelet
sleep 8
echo "kubelet: $(systemctl is-active kubelet)"

echo
echo "=== node status from kubelet's own API (via delegate node if needed) ==="
echo "On rp5-0 run:  KUBECONFIG=/etc/kubernetes/admin.conf kubectl get node $(hostname) "
echo
echo "=== done. Verify Ready within ~1-2 min. ==="