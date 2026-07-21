# Baseline & RCA — 2026-07-19 — hme-srv-01 storage/cluster health (pre-migration)

Snapshot taken before the storage-migration work (plan: `fancy-questing-balloon.md`).
Re-applies to any ZFS+Longhorn+Plex node under similar pressure.

## Cluster
- 7 nodes Ready @ v1.36.2 (k8s 1.29→1.36 upgrade complete). hme-srv-02/03 freshly joined (~3h).
- API: k8s.costascomputers.com:6443 → 192.168.1.166 (rp5-0). DNS to this name is **intermittent from non-LAN-resolver hosts** — pin kubeconfig server to the IP (done: `~/.kube/config.ip`).

## hme-srv-01 — ACUTE overload (the keystone problem)
- **Load 169→97→~100+** after ARC relief; RAM 23Gi, free was 1.3Gi→4Gi. 34 procs in D-state.
- **ZFS pool `data`**: 27.2T, **86% full**, 27% frag. Corruption: 2 permanent errors (both media, re-fetchable):
  - `/data/complete/music/John Landis Fans - Songs For The Frozen Latitudes [1999] [Album] [FLAC]/05 - Silent Waters.flac`
  - `/data/complete/movies/Schindler's.List.1993.1080p.BluRay.DTS.x264.D-Z0N3.mkv`
  - raidz1-1 = 3.19K cksum on all 3 disks (suspect: smartctl pending); raidz1-0 = 4 cksum each; raidz1-2 clean. ZIL (zfs_slog_lv 10G) healthy.
- **ARC**: c_max was 11.65Gi (50% default) but **size overshot to 16.7–18Gi** (pinned by in-flight I/O). Lowered `zfs_arc_max` to 8Gi live + persisted (`/etc/modprobe.d/zfs.conf`). ARC shrank to 15Gi then stuck (buffers pinned by D-state I/O); still freed ~2.7Gi and dropped load. `arc_meta_used` only ~0.9Gi (the earlier 10Gi metadata-floor trap is gone, so low cap is safe).
- **Load root cause = NFS `getattr` metadata storm** (15M+ getattrs) + Longhorn loopback writes, all hitting the 86%-full fragmented pool. Disks individually NOT saturated (%util 5–38%); load is from the **count** of small random metadata ops pinning procs in D-state (`txg_sync`, 8× `nfsd`, 6× `dp_sync_taskq`).
- **Longhorn "disk-1" on hme-srv-01 = a 1.5T loopback image file on ZFS** (`/data/longhorn_backend.img` → loop0 → `/mnt/longhorn-ext4`). Any ZFS I/O stall flips disk-1 not-ready → instance-manager `Error`, engine-image 2545 restarts, csi-plugin 4013 restarts → ~9 faulted + ~7 unknown volumes. This is the data-plane flap root cause.
- **Separate failing 1G virtual disk `sdl`** backs the home-assistant PVC (pvc-e0ff9c7c); ext4 journal aborted, remounted read-only. Minor app, but adds I/O errors.
- **NFS exports** (`/etc/exports`): /data, /data/complete, /data/home, /data/incomplete, /data/watch, AND `/var/lib/containerd/io.containerd.snapshotter.v1.zfs` (containerd snapshotter exported via NFS — almost certainly stale/misconfigured; review).
- LVM (ubuntu-vg, 165.68G): ubuntu-lv 82.8G (root /), zfs_l2arc_lv 50G (**exists but NOT attached** as cache — reclaimable for containerd overlayfs), zfs_slog_lv 10G (ZIL). VFree 22.84G.

## Plex (WS2 target — corrections to plan)
- `plex-kube-plex-686cb8f5b6-2mw7m` on hme-srv-01, 2/2 Running. Image plexinc/pms-docker:1.43.1.10611.
- Volumes: config=PVC `plex-kube-plex-config` (pvc-a8e15fc3, **200Gi RWX longhorn** — NOT 100Gi, NOT the NFS-provisioner as the plan said; it's the Plex config DB volume, the migration target), data=PVC `plex-kube-plex-data` (40Gi RWX longhorn), transcode=emptyDir 4Gi, + 3 **loopback NFS** extraVolumes (server hme-srv-01): /data/complete/{tv,movies,music} → /tv /movies /music.
- **Plex cgroup `memory.max = max` — NO memory limit applied** despite values.yaml `limits.memory: 14Gi`. Current 282Mi, peak 5.3Gi. → The plan's "lower 14Gi→10Gi" is moot until the chart actually applies resources; fix that in the WS2 helm upgrade.
- nodeSelector: kubernetes.io/arch=amd64 (NOT pinned to hme-srv-01 hostname yet). loadbalancer.yaml selector app: kube-plex.
- Stale: `charts/kube-plex/nfs.yaml` (triplicated dead garbage), standalone `plex/` dir (broken linuxserver/plex STS, not deployed), `inteldeviceplugins-controller-manager` CrashLoopBackOff in plex ns (231 restarts, stale).

## pihole (WS3)
- STS 2/2 (HPA min2/max5): pihole-0@rp5-1, pihole-1@rp5-2. nebula-sync@rp5-3. shell-operator@hme-srv-01. No pihole-2 (HPA design). PVCs on longhorn (10 PVCs for replicas 0–4; pihole-2/3/4 orphaned faulted/unknown).

## vault (broken now)
- STS 0/5 ready. vault-0 Init on hme-srv-03; vault-1..4 Running 0/1 (sealed/not-ready). vault-agent-injector CrashLoopBackOff 3555 restarts on hme-srv-01. Raft HA = app-layer redundancy → migrate to hostPath, but currently unhealthy; review before migrating.

## transmission (5 ns)
- transmission-ebooks (Deployment, openvpn, rp5-3, 43 restarts), transmission-movies (STS 0/1, no pod), transmission-music (STS 4/5), transmission-porn (ns empty), transmission-tv (STS 1/1). Per-node sharded by design → hostPath per node.

## Longhorn (KEPT, stabilize)
- v1.11.1, v1 engine. SC `longhorn` (default) `numberOfReplicas=3`; `default-replica-count=2`; most volumes have 2 replicas — **mismatch**. `auto-salvage=false`, `node-drain-policy=block-if-contains-last-replica`, `storage-network` empty, `storage-over-provisioning-percentage=140`, `storage-reserved-percentage-for-default-disk=30`, `engine-replica-timeout=8`.
- LH node hme-srv-01 Ready=False (disk-1 flapping). Others Ready.
- Faulted/unknown volumes map to real workloads (consul, mastodon-es×4, mastodon-pg, mastodon-redis, lidarr-config, home-assistant, squid, pihole-2/3/4 orphaned). Many may auto-recover once hme-srv-01 data plane is fixed.
- Full PVC-by-namespace map captured (authentik, autobrr, consul, grafana, prometheus, alertmanager, headscale, home-assistant, icinga×5, lidarr, loki×6, mastodon×6, navidrome, overseerr, pihole×10, plex×2, prowlarr, squid, syncthing).

## Monitoring (WS5 — broken, needs repair first)
- `monitoring` ns is EMPTY. Prometheus/Grafana/Alertmanager/kube-state-metrics/node-exporter are in `default` ns, **not operator-based** (no ServiceMonitor/PrometheusRule CRDs).
- Broken: grafana `Init:Error`, alertmanager `Init:CrashLoopBackOff`, kube-state-metrics `CrashLoopBackOff` (3348 restarts), one node-exporter pod `CrashLoopBackOff`. metrics-server API unavailable (kubectl top fails). cAdvisor NOT deployed. alloy→Loki ingestion mostly works (alloy DaemonSet 7/6).
- → No Grafana/Prometheus baseline available pre-migration; must repair the stack to do the WS5 metrics review.

## Immediate relief applied
- `zfs_arc_max` 11.65Gi → 8Gi, live + persisted. Load 169→~97, free 1.3Gi→4Gi. ARC stuck at 15Gi (I/O-pinned) but partial win. Reversible.
- Plex RAM cut DEFERRED — no cgroup limit applied; restart gives zero relief; fold into WS2 (fix chart resources + 10Gi + hostPath in one upgrade).

## Next (per plan priority)
1. WS2 Plex hostPath migration (kills loopback NFS getattr storm = biggest load relief; fixes missing resource limit; pins to hme-srv-01) — highest leverage + user priority.
2. WS1b free pool <80% (propose prune of stale containerd@ snapshots + old media snapshots; NOT media).
3. WS1c containerd → SSD overlayfs (reclaim the unused 50G zfs_l2arc_lv; frees ZFS I/O + 666 snapshots).
4. WS4a fix hme-srv-01 data plane (disk_reservation + force-delete crashloop pods) → may auto-recover faulted volumes.
5. WS3 pihole local + DNS HA; WS4c migrate vault/transmission; WS5 repair monitoring + baseline.