# hme-srv-01 NFS-on-ZFS investigation & RCA

Scripts and documentation for investigating and resolving the hme-srv-01 NFS
deadlock discovered during the Kubernetes 1.29 -> 1.30 -> 1.31 upgrade
(2026-07-18). hme-srv-01 is the cluster's NFS server, backed by a ZFS pool, and
also an NFS client of itself (loopback) and of in-cluster Longhorn NFS
provisioner Services.

## What happened (short version)

Upgrading the control-plane kubelet (rp5-0) to v1.30.14 hung at startup because
cAdvisor (v0.49.x, shipped in kubelet 1.30) calls `statfs` on every mounted
filesystem at startup and blocks indefinitely on a **dead hard NFSv4 mount**
sourced from hme-srv-01. That mount had been dead for ~20 days (expired NFSv4
lease) — v1.29.7's cAdvisor tolerated it; v1.30's doesn't.

The dead mount was itself a symptom of an **hme-srv-01 NFS-server degradation**:
nfsd threads (8) blocking on slow ZFS I/O (pool 85 % full / 27 % fragmented),
1.24 B NFS ops over 63 days, memory pressure (OOM-killer invoked), and a
Longhorn NFS-provisioner dependency (`10.96.97.171`) that was unresponsive on
Jul 13. See `rca-2026-07-18-hme-srv-01-nfs-deadlock.md` for the full RCA.

## Current state (upgrade paused)

- All 7 cluster nodes **Ready @ v1.31.14**, schedulable.
- Upgrade paused at 1.31 to do this hme-srv-01 RCA + recover 14 faulted detached
  Longhorn volumes before continuing 1.32 -> 1.36.
- Longhorn `auto-salvage` set to `false` during the upgrade (transient
  node-NotReady from kubelet restarts was triggering unwanted replica rebuilds).

## Scripts

Run on the indicated host. Most need root (`sudo bash <script>`). The NFS
scripts use background `stat -f` + a timed `kill -0` check so a hung statfs
(D-state) does not wedge the script — the probe reports HUNG and moves on.

| Script | Run on | Purpose |
|---|---|---|
| `../scripts/nfs-server-health.sh` | hme-srv-01 (NFS server) | Full server snapshot: nfs-server status, nfsd threads + D-state count, nfsstat, established :2049 clients, own NFS-client mounts, ZFS pool, dmesg NFS/OOM/blocked, load, all D-state procs. |
| `../scripts/restart-nfsd.sh` | hme-srv-01 | Take a forensic snapshot, restart `nfs-kernel-server`, observe whether nfsd threads clear / load drops / fresh mounts succeed. |
| `../scripts/nfs-client-hang-check.sh` | any NFS client node | List all NFS mounts to the NFS server, classify soft/hard, statfs-probe each (non-blocking), report any HUNG; list D-state procs. |
| `../scripts/unblock-kubelet-nfs-hang.sh` | a node whose kubelet hung on NFS | Lazy-unmount (`umount -l`) the dead **hard** NFSv4 mounts (the ones that block cAdvisor statfs) and restart the kubelet. Leaves soft + CSI mounts for the kubelet to reconcile. |
| `../scripts/longhorn-status.sh` | a node with admin kubeconfig | Longhorn settings (auto-salvage, drain policy, rebuild limits), volume robustness counts, Longhorn node readiness, list of degraded/faulted volumes. |

## Usage examples (from WSL, key-based SSH already set up)

```bash
# NFS server snapshot (hme-srv-01)
ssh administrator@192.168.1.231 'sudo bash -s' < ../scripts/nfs-server-health.sh

# Check whether a worker's NFS mounts will hang a kubelet-1.30+ restart
scp ../scripts/nfs-client-hang-check.sh mcostas@192.168.1.249:/tmp/ && \
  ssh mcostas@192.168.1.249 'sudo bash /tmp/nfs-client-hang-check.sh'

# Longhorn status (from rp5-0, which has /etc/kubernetes/admin.conf)
ssh mcostas@192.168.1.166 'KUBECONFIG=/etc/kubernetes/admin.conf sudo bash -s' < ../scripts/longhorn-status.sh
```

## Next (the actual review)

1. Re-acquire fresh `nfs-server-health.sh` output (state changed since the
   incident — nfsd was restarted, rp5-0's dead mounts were lazy-unmounted).
2. Decide the ZFS pool remediation (free space / add vdevs / raise nfsd count).
3. Stop the self-loopback hard NFS mount pattern on hme-srv-01 (use hostPath /
   local PV for local pods instead of NFS-to-self).
4. Recover the 14 faulted detached Longhorn volumes (manual salvage or brief
   auto-salvage re-enable), then decide the steady-state auto-salvage setting.
5. Investigate why Longhorn faults replicas on a brief node-NotReady when the
   replica processes are still alive.