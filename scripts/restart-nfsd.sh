#!/usr/bin/env bash
# restart-nfsd.sh — forensic snapshot, restart nfs-kernel-server, observe.
# Run ON the NFS server (hme-srv-01) as root:
#   ssh administrator@192.168.1.231 'sudo bash -s' < $0
#
# During the 1.30 hop, restarting nfsd cleared the accumulated dead NFSv4
# sessions and dropped the load average (139 -> 19), but it did NOT fully fix
# the problem: 2 of 8 nfsd threads went straight back to D-state because the
# underlying ZFS I/O latency is the real bottleneck, not the dead sessions.
# Use this to capture before/after and to confirm whether a restart is enough
# or the ZFS pool needs attention.

echo "=== BEFORE: $(date -Is) ==="
echo "load: $(cat /proc/loadavg)"
NFSD_PIDS=$(pgrep -x nfsd)
DSTATES=""
for p in ${NFSD_PIDS}; do
  [ "$(awk '{print $3}' /proc/$p/stat 2>/dev/null)" = "D" ] && DSTATES="${DSTATES} $p"
done
echo "nfsd total=$(echo "${NFSD_PIDS}" | wc -l)  D-state=$(echo "${DSTATES}" | wc -w)${DSTATES}"
echo "established :2049 clients: $(ss -tan state established '( sport = :2049 )' 2>/dev/null | wc -l)"
echo

echo "=== restarting nfs-kernel-server ==="
systemctl restart nfs-kernel-server
sleep 5
systemctl is-active nfs-kernel-server
echo

echo "=== AFTER: $(date -Is) ==="
echo "load: $(cat /proc/loadavg)"
NFSD_PIDS=$(pgrep -x nfsd)
DSTATES=""
for p in ${NFSD_PIDS}; do
  [ "$(awk '{print $3}' /proc/$p/stat 2>/dev/null)" = "D" ] && DSTATES="${DSTATES} $p"
done
echo "nfsd total=$(echo "${NFSD_PIDS}" | wc -l)  D-state=$(echo "${DSTATES}" | wc -w)${DSTATES}"
echo "established :2049 clients: $(ss -tan state established '( sport = :2049 )' 2>/dev/null | wc -l)"
echo

echo "=== observe fresh-mount reachability from THIS server (loopback) ==="
# A loopback mount test confirms nfsd can negotiate a new client. If this
# hangs, nfsd is still stalled regardless of the restart.
TMPDIR_TEST=$(mktemp -d)
echo "  mount -t nfs4 -o soft,timeo=5,retrans=1 127.0.1.1:/data ${TMPDIR_TEST}"
if timeout 8 mount -t nfs4 -o soft,timeo=5,retrans=1 127.0.1.1:/data "${TMPDIR_TEST}"; then
  echo "  loopback mount: OK"
  umount -l "${TMPDIR_TEST}" 2>/dev/null
else
  echo "  loopback mount: FAILED/HUNG (rc=$?)"
fi
rmdir "${TMPDIR_TEST}" 2>/dev/null
echo

echo "=== load trend (wait 20s, recheck) ==="
sleep 20
echo "load after 20s: $(cat /proc/loadavg)"
echo
echo "=== done — re-run nfs-server-health.sh for the full post-restart snapshot ==="