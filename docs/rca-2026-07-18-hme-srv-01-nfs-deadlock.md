# RCA — hme-srv-01 NFS deadlock (discovered during 1.29 → 1.30 upgrade)

**Date:** 2026-07-18
**Trigger event:** kubeadm upgrade of control-plane node `rp5-0` from v1.29.7 to v1.30.14.
**Impact:** rp5-0 kubelet 1.30.14 hung at startup → node `NotReady` → ~30 user pods stuck
`Terminating`. Cluster API server stayed up (static pod), so the cluster remained
functional for API operations; only rp5-0's kubelet + its local user pods were down.
**Root cause:** a **pre-existing, ~20-day-old dead NFSv4 hard mount** on rp5-0 (sourced
from hme-srv-01) that v1.29.7's cAdvisor tolerated but v1.30.14's cAdvisor blocks on at
startup. The dead mount is itself a symptom of an **underlying hme-srv-01 NFS-server
degradation** (nfsd threads blocking on slow ZFS I/O) that has been brewing for weeks.

This document captures the situation, the troubleshooting steps taken, the acquirable
status of the NFS server and the affected pods, and prevention recommendations. It is
intended to feed the post-upgrade RCA/resolution of hme-srv-01.

---

## 1. Timeline / what happened

1. **Phase A (prior session):** two new workers `hme-srv-02` (192.168.1.154) and
   `hme-srv-03` (192.168.1.174) joined the v1.29.7 cluster as workers. Cluster = 7 nodes.
2. **Phase B — 1.29 → 1.30 hop:** `kubeadm upgrade apply` ran on rp5-0; kubelet/kubeadm/
   kubectl upgraded to 1.30.14; packages held. CP static pods (apiserver, etcd,
   controller-manager, scheduler, kube-proxy) restarted cleanly at 1.30.14.
3. **kubelet 1.30.14 on rp5-0 hung at startup.** A goroutine stack dump (`kill -QUIT`)
   showed the main goroutine blocked in `syscall.Statfs → cadvisor/fs.getVfsStats →
   GetGlobalFsInfo → machine.Info → cadvisor.New`. The kubelet ignored SIGTERM
   (systemd had to SIGKILL it on timeout).
4. **Diagnosis:** rp5-0 had several **hard NFSv4 mounts from hme-srv-01** under
   `/var/lib/kubelet/pods/<uid>/volumes/kubernetes.io~nfs/`. `mountstats` showed
   `lease_expired=435534` and `age: 1721949` (~20 days) — the mount's NFSv4 client lease
   had expired long ago and the transport was dead. A `stat -f` on the mount blocked
   indefinitely (D-state). v1.29.7's cAdvisor did not block on this; v1.30.14's cAdvisor
   enumerates and stats every mount at startup (`machine.Info()`) and blocks.
5. **NFS server (hme-srv-01) found degraded, not down:** `nfs-server.service` active
   (up 63 days), listening on 2049, exports present. But `nfsstat -s` showed **1.24
   billion NFS ops over 63 days** (1.16B NFSv4 compounds, dominated by `sequence`/
   `putfh` polling). **5 of 8 nfsd threads were in D-state** (`cv_timedwait`),
   all 8 threads occupied by established connections, so new NFSv4 `SETCLIENTID`
   exchanges queued and timed out — a **fresh `mount -t nfs4` from rp5-0 hung to a
   25 s timeout (`rc=124`)** even though raw TCP to 2049 succeeded.
6. **Restart of nfsd on hme-srv-01** cleared the dead sessions and dropped load
   (139 → 19.77) but **2 of 8 nfsd threads immediately went D-state again**, and fresh
   mounts from rp5-0 still failed — because the underlying ZFS I/O latency is the real
   bottleneck, not the dead sessions.
7. **rp5-0 unblocked:** lazy-unmounted (`umount -l`) the 6 dead hard NFS4 mounts on
   rp5-0 and restarted the kubelet. cAdvisor no longer blocked → node `Ready @ v1.30.14`.
   Stuck-Terminating pods cleaned up and rescheduled off rp5-0.

---

## 2. Current acquirable status (as of the incident)

### 2.1 hme-srv-01 — NFS server node (the actual root cause)

- **OS:** Ubuntu 24.04.2 LTS, kernel 6.8.0-111-generic, uptime 63 days.
- **Backing storage:** ZFS pool `data` — **27.2 T, 23.4 T allocated (85 % full),
  27 % fragmented**, 7 vdev disks (sdb–sdh, 2.7 T / 3.6 T mix) + 10 G ZIL
  (`zfs_slog_lv`) + 50 G L2ARC (`zfs_l2arc_lv`). Exports: `/data`, `/data/complete`,
  `/data/home`, `/data/incomplete`, `/data/watch`, plus a stray
  `/var/lib/containerd/io.containerd.snapshotter.v1.zfs` export.
- **NFS server:** `nfs-server.service` active; 8 nfsd threads; listening on 2049
  (v4 + v6); mountd / nlockmgr / nfs_acl all registered.
- **nfsd thread state (pre-restart):** 5/8 in D-state (`cv_timedwait_comm`),
  all 8 threads occupied by established connections.
- **Load average:** 139.24 / 102.10 / 76.79 (pre-restart) → 19.77 / 61.81 / 69.49
  (post-restart). Spiky, sustained high.
- **NFS volume:** `nfsstat -s` ≈ 1.24 B total calls, 1.16 B NFSv4 compounds.
  Op mix: `sequence` 1.16 B (28 %), `putfh` 1.16 B (28 %), `getattr` 912 M (22 %),
  `lookup` 288 M (7 %). Dominance of `sequence`/`putfh` ⇒ many sessions polling.
- **Current NFS clients (established to :2049):** rp5-2 (192.168.1.249),
  rp5-3 (192.168.1.171 ×2), and **hme-srv-01 itself via loopback (127.0.1.1)**.
- **hme-srv-01 is also an NFS *client*:** it mounts its own exports via loopback
  (`hme-srv-01:/data/complete/{tv,movies,music}` → 127.0.1.1, **hard** nfs4) for its
  own pods, AND it mounts **Longhorn CSI NFS-provisioner** exports as nfs4.1
  (`softerr,softreval`):
  - `10.96.97.171:/pvc-a8e15fc3-…` (globalmount + per-pod mount)
  - `10.96.227.126:/pvc-cf5f7b89-…` (globalmount + per-pod mount)
- **dmesg highlights:**
  - Jul 13: `nfs: server 10.96.97.171 not responding, timed out` (×15) — the
    Longhorn NFS-provisioner Service `10.96.97.171` was unresponsive; hme-srv-01's
    CSI globalmounts to it timed out.
  - Jul 17 03:31: `alloy invoked oom-killer` → killed process `tracer`
    (anon-rss 880 MB, `oom_score_adj:998`) under a containerd/cri scope. Memory
    pressure on the node.
  - Jul 18 22:28: `nfs: server hme-srv-01 not responding, still trying` / `OK`
    (transient, recovered the same second — observed by another client).
- **Other D-state process:** `PMS Butler` (Plex Media Server) in `DN` state —
  heavy I/O consumer on the ZFS pool.

### 2.2 rp5-0 — control plane (where the hang surfaced)

- Debian 12, kernel 6.6.31+rpt-rpi-2712 (Raspberry Pi 5, arm64), containerd 1.7.19.
- 6 dead **hard NFSv4** mounts from hme-srv-01 under pod `5e4aa6d4-…`
  (transmission-openvpn stack): `nfs-incomplete`, `mullvad-ca-crt`, `nfs-watch-ebooks`,
  `nfs-config`, `nfs-complete-ebooks`, and a `volume-subpath` (`mullvad-ca-crt/…/4`).
  All `vers=4.2,hard,proto=tcp,timeo=600,retrans=2`, `lease_expired`, `age` ~20 days.
- 2 **soft** NFSv3 mounts (`nfs-complete-music`, `nfs-incomplete-music`) — these return
  errors on timeout and do **not** hard-block (cAdvisor tolerates them).
- Longhorn CSI globalmounts (softerr nfs4.1) — also do not hard-block.

### 2.3 Affected pods (pre-recovery)

On rp5-0, ~30 user pods stuck `Terminating` because their volumes wouldn't unmount from
the dead NFS mount (unmount of a hard NFS mount with blocked processes hangs):

- `argocd` (repo-server, server), `authentik-worker`, `cert-manager-webhook`,
  `icinga-stack-icingadb`, `coredns`, `loki-read`, all Longhorn CSI controllers
  (`csi-attacher`, `csi-provisioner`, `csi-resizer`, `csi-snapshotter`,
  `instance-manager`), `mastodon-streaming` (24 323 restarts), `transmission-ebooks`
  (2 304 restarts), `transmission-music` (448 restarts), `vault-4`.

The enormous restart counts on mastodon-streaming / transmission-ebooks confirm these
NFS-backed workloads had **already been failing for weeks** — the dead NFS mount is
not new; the kubelet upgrade merely made rp5-0 intolerant of it.

### 2.4 PDBs that block worker drains (relevant to the rest of the upgrade)

`kubectl get pdb -A` — PDBs with **ALLOWED DISRUPTIONS = 0** (drain cannot evict):

| Namespace | PDB | Constraint | Allowed |
|---|---|---|---|
| longhorn-system | instance-manager-027e… / 5e32… / 73f5… / 7deb… / 9091… / f62f… / fc81… (×6, one per storage node) | minAvailable 1 | 0 |
| loki | loki-write | maxUnavailable 1 | 0 |
| vault | vault | maxUnavailable 2 | 0 |
| istio-system | istiod | minAvailable 1 | 0 |

→ Every worker that hosts a Longhorn instance-manager (i.e. every storage node,
including the new hme-srv-02/03) is PDB-blocked from drain. A standard
`kubectl drain --ignore-daemonsets --delete-emptydir-data` will fail on all workers.

---

## 3. Root-cause chain

```
ZFS pool "data" 85 % full, 27 % fragmented (write/metadata latency rising)
        │
        ▼
nfsd threads (8) block on slow ZFS I/O  →  D-state, can't service new requests
        │
        ▼
New NFSv4 SETCLIENTID exchanges time out  →  fresh mounts hang (rc=124 / TCP ok)
        │
        ▼
Existing hard NFSv4 mounts whose leases expired (dead for ~20 days on rp5-0)
cannot renegotiate  →  statfs on them blocks indefinitely (D-state)
        │
        ▼
kubelet 1.30.14 cAdvisor stats every mount at startup (machine.Info → GetGlobalFsInfo)
→ blocks on the dead hard mount  →  kubelet hangs, ignores SIGTERM, node NotReady
        │
        ▼
pods can't terminate (volume unmount hangs on dead mount) → stuck Terminating
```

Aggravating factors observed on hme-srv-01:
- Memory pressure (OOM-killer invoked Jul 17, killed `tracer`/Plex).
- Plex Media Server (`PMS Butler`) doing heavy I/O on the same ZFS pool.
- Longhorn NFS-provisioner Service `10.96.97.171` was unresponsive Jul 13 — hme-srv-01's
  CSI mounts to it timed out, compounding stalls.
- Extreme NFS op volume (1.24 B ops / 63 days) with heavy `sequence` polling.
- hme-srv-01 mounts its **own** exports via loopback (hard nfs4) — a self-dependency
  that makes nfsd stalls also stall hme-srv-01's own pods.

**Why v1.29.7 didn't hang but v1.30.14 did:** cAdvisor version 0.49.x (shipped in
kubelet 1.30) calls `syscall.Statfs` on every mounted filesystem synchronously during
`machine.Info()` at startup; the 1.29 cAdvisor build did not block startup on it. This
is a **latent-fault-exposing** change, not a regression — the NFS mount was already
dead and the workloads already broken.

---

## 4. Immediate remediation taken (to unblock the upgrade)

1. Restarted `nfs-kernel-server` on hme-srv-01 (cleared dead sessions, dropped load;
   did **not** fully resolve because ZFS latency persisted — 2/8 nfsd back to D-state).
2. On rp5-0: lazy-unmounted (`umount -l`) the 6 dead **hard** NFSv4 mounts (left the
   soft NFSv3 and Longhorn CSI mounts for the kubelet to reconcile).
3. Restarted the rp5-0 kubelet → cAdvisor no longer blocked → node `Ready @ v1.30.14`.
   Stuck-Terminating pods cleaned up and rescheduled.

The NFS-backed workloads (transmission-ebooks, transmission-music, mastodon-streaming)
remain broken until hme-srv-01's NFS is properly resolved (post-upgrade RCA). They
were already broken before the upgrade (weeks of CrashLoop), so this is not a
regression.

---

## 5. Prevention recommendations (for the post-upgrade hme-srv-01 RCA)

### NFS server side (hme-srv-01)
1. **Reduce ZFS pool fill.** Pool `data` is 85 % full / 27 % fragmented. ZFS write/metadata
   latency rises sharply past ~80 % free-space depletion. Free space or add vdevs.
   Target ≤ 80 % used.
2. **Investigate nfsd thread count / blocking.** 8 threads with 5 in D-state under load
   suggests threads starve on ZFS I/O. Consider raising `RPCNFSDCOUNT` (e.g. 16–32) so
   blocked threads don't starve new requests, **and** fix the ZFS latency so threads
   don't block in the first place (more threads is a band-aid, not a cure).
3. **Stop the self-loopback hard NFS mount pattern.** hme-srv-01 mounting its own
   exports via `hard` nfs4 over 127.0.1.1 creates a self-dependency: nfsd stalls stall
   hme-srv-01's own pods. For local pods, use a `hostPath` or `local` PV instead of NFS
   to self.
4. **Memory pressure:** the Jul 17 OOM (killed Plex `tracer`) indicates memory
   pressure. Review node memory limits / Plex transcoder limits. `alloy` invoked the
   OOM killer — check alloy's memory limits.
5. **Longhorn NFS-provisioner dependency:** hme-srv-01 mounts Longhorn PVCs over NFS
   (`10.96.97.171`, `10.96.227.126`) with `softerr,softreval` — good (soft, won't
   hard-block), but the Jul 13 outage of `10.96.97.171` cascaded. Investigate why that
   Service was unresponsive (Longhorn NFS-provisioner pod health / resources).
6. **Monitoring/alerting on nfsd D-state & load.** Add an alert for nfsd threads in
   D-state and for hme-srv-01 load average > N so this is caught before it stalls
   clients.

### Kubernetes / mount-policy side
7. **Avoid `hard` NFS mounts for non-critical data.** Hard NFS mounts block forever
   when the server is unresponsive; `soft` (or `softerr`) mounts return errors. The
   transmission/mastodon workloads are non-critical media pipelines — they should use
   `soft` NFS (or `softerr`) so a stale server doesn't wedge the kubelet or the pod.
   The dead mounts on rp5-0 were all `hard`; the soft ones (music) did not block.
8. **Don't let cAdvisor statfs wedge the kubelet.** This is exposed by 1.30+. The
   robust fix is #7 (no hard mounts to an unreliable server). There is no clean kubelet
   flag to skip NFS mounts in cAdvisor; the upstream-safe mitigation is healthy mounts.
9. **Drain hygiene / PDBs:** the cluster has PDBs pinning single-replica stateful
   workloads (Longhorn instance-manager per node, loki-write, vault, istiod) to
   `allowedDisruptions=0`, which makes `kubectl drain` impossible without manual PDB
   patching. For an upgrade workflow, either (a) script a temporary PDB-minAvailable=0
   patch during drains and restore after, or (b) use cordon + upgrade-in-place for
   kubelet-only minor hops (no eviction, pods keep running). Document the chosen
   policy in the upgrade runbook.

### Upgrade-workflow side (this repo)
10. The `kubeadm_upgrade` role has been adjusted to support **cordon + upgrade-in
    place** (`drain_nodes: false` plus an always-run cordon task) for the worker hops,
    because drains are PDB-blocked cluster-wide. Lazy-unmounting NFS is **not** baked
    into the role — it remains a deliberate one-off recovery action on a node whose
    `Wait for Ready` times out (confirmed-dead hard NFS mount).

---

## 6. Forensic artefacts retained

- `mountstats` for `hme-srv-01:/data/incomplete` on rp5-0: `lease_expired=435534`,
  `age=1721949`, dead transport.
- `nfsstat -s` on hme-srv-01 (1.24 B ops snapshot) — above.
- `ss -tan state established '( sport = :2049 )'` client IP list — above.
- `dmesg -T` NFS/OOM/blocked excerpts — above.
- `zpool list` / `lsblk` / `df -hT /data*` — above.

Re-acquire fresh snapshots during the post-upgrade hme-srv-01 RCA, since restarting
nfsd and lazy-unmounting has changed the state. The reusable capture scripts now live
in `../scripts/` (see `hme-srv-01-review.md`).

---

## 7. Longhorn rebuild behaviour during the upgrade (separate but interacting issue)

During the 1.30/1.31 worker hops, Longhorn began rebuilding many volumes,
causing heavy network/CPU activity (compounding hme-srv-01's load). Investigation:

- **`auto-salvage` was `true`** (Longhorn setting
  `setting.longhorn.io/auto-salvage`). It had been "disabled" in the UI but the
  change never reached the CR (the source of truth). Patched to `false` via
  `kubectl -n longhorn-system patch setting.longhorn.io auto-salvage
  --type=merge -p '{"value":"false"}'` and verified.
- **Cause of the rebuilds:** every in-place kubelet restart creates a brief
  node-NotReady window. With `auto-salvage=true`, Longhorn marked replicas on
  that node faulted and triggered rebuilds — **even though the replica processes
  never died (containerd keeps them across a kubelet restart) and the local
  disks are untouched.** A brief kubelet restart should *not* force a rebuild;
  this was undesirable churn, aggravated by lingering faults from the
  prolonged rp5-0 outage.
- **`node-drain-policy = block-if-contains-last-replica`** is correct/desirable
  (makes drains PDB-block rather than lose the last replica). Not the cause;
  leave it.
- Other aggressive rebuild settings observed: `concurrent-replica-rebuild-per-node-limit = 5`,
  `offline-replica-rebuilding = true`, `replica-auto-balance = best-effort`,
  `fast-replica-rebuild-enabled = {v1:true,v2:true}`.

**Consequence of disabling auto-salvage:** with it off, faulted volumes no longer
auto-recover. At the pause point the volume robustness breakdown was
**41 healthy / 14 faulted / 11 unknown**, with all 14 faulted volumes in
`detached`/`detaching` state (not attached to running pods — i.e. workloads that
are currently down). These need **manual salvage** (or a brief re-enable of
auto-salvage) to recover — to be done in the post-upgrade RCA. Recommended
operational pattern: keep `auto-salvage=false` during upgrade hops (avoids
churn from kubelet-restart transients), then salvage faulted volumes afterward
and decide the steady-state setting deliberately.

**Recommendation (Longhorn):** consider a more targeted guard than a global
auto-salvage toggle — e.g. raise the node-down timeout before replicas are marked
failed (so a ~30s kubelet restart doesn't fault replicas), or ensure the
instance-manager/engine pods are not disrupted by kubelet restarts. Investigate
why Longhorn faults replicas on a brief node-NotReady when the replica processes
are still alive (this may be a Longhorn node-controller sensitivity worth a
bug report / setting).

## 8. Upgrade progress & current status (paused)

- **Completed hops:** 1.29 -> 1.30, 1.30 -> 1.31.
- **Current state (pause point):** all 7 nodes **Ready @ v1.31.14**, all
  schedulable. Control plane healthy (apiserver/etcd/scheduler/controller-manager/
  kube-proxy static pods Running at 1.31.14).
- **Remaining hops:** 1.31 -> 1.32 -> 1.33 -> 1.34 -> 1.35 -> 1.36.
- **Paused because:** hme-srv-01 ZFS/NFS RCA + recovery of the 14 faulted
  detached volumes take priority over pushing to 1.36. The upgrade is
  resumable; the working pattern is documented in
  `../playbooks/upgrade_k8s.yml`.

## 9. Operational lessons (process, not cluster)

1. **Do not run a full-cluster hop in one 600s-capped background job.** A slow
   node (hme-srv-01 under load) blew the budget; SIGKILLing the WSL-side
   `ansible-playbook` **orphaned the remote `apt-get`**, which kept running 9.5+
   minutes holding the dpkg lock (stuck in the `needrestart` apt post-invoke
   hook). Recovery: kill the orphaned apt chain (`kill -9` the apt/needrestart
   PIDs), `dpkg --configure -a` (no-op if clean), re-run. Run hops foreground in
   small batches that fit the timeout instead.
2. **`needrestart` can hang on a heavily-loaded node** scanning processes.
   Mitigation: `NEEDRESTART_MODE=l DEBIAN_FRONTEND=noninteractive` for apt on
   slow nodes (used to finish hme-srv-01 manually after the orphan).
3. **`kubeadm upgrade apply` restarts the apiserver static pod**, and for
   ~10-20s afterward RBAC returns `Forbidden` to `kubectl`. The role's cordon
   task now has `retries: 6 delay: 10` to tolerate this; also run the CP and
   worker plays as separate invocations so worker cordons don't race the CP
   apiserver restart.
4. **PDBs make real drains impossible here** without patching — use
   cordon + upgrade-in-place (`drain_nodes=false`) for kubelet-only minor hops.
5. **cAdvisor (kubelet 1.30+) blocks startup on a dead hard NFS mount's statfs.**
   Before each CP hop, confirm rp5-0 has no hung hard NFS mounts (the 1.30 hop
   required lazy-unmounting 6 dead hard NFS mounts to unblock the kubelet).

---

## 10. Re-review — 2026-07-19 (current baseline, post-pause)

Re-acquired fresh data with `scripts/nfs-server-health.sh` + `scripts/longhorn-status.sh`
+ an expanded forensics pass. The picture is materially worse / clearer than the
incident snapshot, and the root cause is now confirmed as **ZFS I/O saturation**,
not just "pool 85 % full".

### 10.1 hme-srv-01 — I/O-bound, memory-starved

- **Load 84/83/93 sustained.** nfs-server was restarted again 49 min before this
  snapshot (Jul 18 23:53 UTC) and **2/8 nfsd were back in D-state** within that hour.
- **CPU is I/O-bound, not CPU-bound:** `iowait 69.86 %`, `system 27.20 %`,
  **`idle 0.00 %`**. Pool disks sdd/sdi/sdj ~98 % util, sdg 97.7 %, `r_await` up to
  **91 ms** (sdd), 58 ms (sdi/sdg). The load is entirely disk queueing.
- **Memory starved:** MemTotal 24 GiB, **MemAvailable 1.0 GiB**, **SwapTotal 0**,
  **Slab 1.23 GiB of which SUnreclaim 1.13 GiB** (ZFS arc/dnode buffers).
  `arc_prune` at 21 % CPU — kernel is thrashing, frantically shrinking the ARC under
  pressure. This is the OOM-pressure source (the Jul 17 OOM that killed Plex `tracer`).
- **containerd uses the ZFS snapshotter on pool `data`** — `zpool events` shows
  constant `data/containerd/<id>` clone/snapshot activity; the stray
  `/var/lib/containerd/io.containerd.snapshotter.v1.zfs` export is this. So **containerd
  image/layer I/O competes with NFS exports on the same pool** — a structural design
  problem and a major contributor to the I/O saturation.
- **`longhorn-manage` and `alloy` are themselves in D-state** (blocked on the same pool).
- **nfsd = default 8 threads** (no `RPCNFSDCOUNT` in `/etc/default/nfs-kernel-server`).
  Raising it is a lever but will likely worsen contention while the pool is I/O-bound
  (more threads queueing on the same saturated disks) — fix I/O first.
- A zombie `hub` process (PID 557958, Z state) is harmless (already dead, awaiting reap).

### 10.2 ZFS pool — has real damage now

- `data` 27.2 T, **86 % CAP, 27 % FRAG** (raidz1-0 88 %, raidz1-1 86 %, raidz1-2 85 %).
- **Permanent errors in 2 media files** (left by the scrub that finished Jul 18 18:34
  with 2 errors; scrub repaired 0 B = the checksum mismatches are real, not transient):
  - `/data/complete/music/John Landis Fans - Songs For The Frozen Latitudes [1999] [Album] [FLAC]/05 - Silent Waters.flac`
  - `/data/complete/movies/Schindler's.List.1993.1080p.BluRay.DTS.x264.D-Z0N3.mkv`
  Both are non-critical media (re-acquireable). Clear them with `zpool clear` after
  deleting/re-acquiring the files so the error counters reset.
- **Checksum errors per disk:** raidz1-0 = 4 on each of its 3 disks; raidz1-1 = **3.19K
  on each of its 3 disks**. Equal counts across all disks in a vdev usually means the
  corruption is at the block/parity level (a block that reconstructed inconsistently)
  rather than one bad disk — but a flaky disk/cable in raidz1-1 is not ruled out.
  Needs a SMART check + `zpool events`/`zpool scrub` follow-up (separate workstream;
  not the cause of the NFS stall).

### 10.3 Self-loopback hard NFS mounts — unchanged, belong to Plex

- Pod `5e3ff8dd` = **`plex-kube-plex`** (10.0.4.231): mounts its **own** exports
  `tv/movies/music` via **hard** nfs4.2 over 127.0.1.1 — the self-dependency. Plex
  reading + transcoding media over loopback NFS is a heavy consumer feeding the I/O
  saturation and the nfsd stalls.
- Pod `cb448f0e` = **`ftp-74c8956669-bnj4d`** (10.0.4.41): uses **soft** NFSv3
  (ebooks/tv/music/movies) — fine, does not hard-block.

### 10.4 Longhorn — data plane healthy; provisioner backing volume degraded

- All 7 engine-image + 7 instance-manager pods **Running** on all 7 nodes. Good.
- `auto-salvage = false` (confirmed), `concurrent-replica-rebuild-per-node-limit = 2`,
  `node-drain-policy = block-if-contains-last-replica`.
- **Volume robustness:** 44 healthy / 12 faulted / 9 unknown / 1 degraded (66 total).
  Slightly improved vs the pause point (44 vs 41 healthy). All non-healthy volumes are
  **detached** (their workloads are not running) — except:
- **`pvc-a8e15fc3` is `degraded` and attached** — this is the volume behind the Longhorn
  **NFS-provisioner Service `10.96.97.171`**. A degraded replica + `auto-salvage=false`
  means it is not self-healing, which is why dmesg still shows continuous
  `nfs: server 10.96.97.171 not responding, timed out` (and now `10.96.227.126` too).
  hme-srv-01's CSI mounts to these Services time out (soft, so they don't hard-block,
  but they fail the workloads that use them).

### 10.5 Updated root-cause picture

```
ZFS pool "data" 86 % full, 27 % fragmented  +  containerd zfs-snapshotter on same pool
        │                                              (image/layer I/O competes with NFS)
        ▼
Disk I/O saturated (iowait 70 %, idle 0 %, r_await up to 91 ms, disks 98 % util)
        │
        ├──▶ ARC memory pressure (only 1 GiB available, 0 swap, arc_prune thrashing)
        │        → OOM risk (already killed Plex tracer Jul 17)
        │
        ├──▶ nfsd threads block on ZFS I/O (D-state) → fresh mounts hang
        │
        └──▶ longhorn-manage / alloy / kubelet themselves block on the pool (D-state)

Separately:
  - pvc-a8e15fc3 (Longhorn NFS-provisioner share 10.96.97.171) degraded + auto-salvage=off
      → 10.96.97.171 / 10.96.227.126 time out → hme-srv-01 CSI mounts fail
  - Plex self-loopback hard nfs4 mounts keep the self-dependency alive and add I/O load
  - 2 permanently-corrupted media files + raidz1-1 cksum errors (disk-health workstream)
```

### 10.6 Remediation priorities (to execute with user)

**Tier 1 — relieve I/O / memory pressure (high impact, mostly reversible):**
1. Move containerd off the ZFS snapshotter onto `overlayfs` on a **separate disk**
   (not pool `data`). Stops containerd churn competing with NFS on the pool.
2. Free space on pool `data` (target ≤ 80 %) and/or add a vdev — biggest single ZFS
   latency win.
3. Give the box a memory cushion: add a small swap file or cap the ZFS ARC
   (`zfs_arc_max`) so ARC + slab can't push available memory to ~1 GiB. Reduces
   `arc_prune` thrash and OOM risk.
4. Salvage `pvc-a8e15fc3` (briefly re-enable `auto-salvage` or trigger a manual
   salvage) so the Longhorn NFS-provisioner recovers and `10.96.97.171` stops timing out.

**Tier 2 — break the self-dependency / NFS policy (medium impact, needs pod changes):**
5. Stop Plex reading media over loopback **hard** NFS — either re-point Plex's
   `tv/movies/music` volumes at a `hostPath`/`local` PV (the data is local to
   hme-srv-01 anyway), or at minimum switch those mounts to `soft`. Removes the
   self-dependency and a class of cAdvisor-statfs risk.
6. After I/O is relieved, raise `RPCNFSDCOUNT` (e.g. 16) — only useful once threads
   aren't all queueing on saturated disks.

**Tier 3 — cleanup (low risk):**
7. Delete/re-acquire the 2 corrupted media files + `zpool clear data` to reset error
   counters; run SMART + a targeted scrub on raidz1-1 to investigate the 3.19K cksum.
8. Recover the remaining 11 faulted + 9 unknown detached Longhorn volumes (decide
   per-volume: salvage vs. recreate-from-backup vs. abandon) and decide the
   steady-state `auto-salvage` setting.
9. Re-acquire a fresh `nfs-server-health.sh` snapshot after Tier 1 to confirm the
   load/iowait/nfsd-D-state have dropped before resuming the 1.32 upgrade hop.