# WS1 assessment — hme-srv-01 ZFS + containerd + memory (2026-07-18)

Read-only investigation via SSH (administrator@192.168.1.231). Findings + remediation
proposal. Durable fixes are ansible/WSL (node config) + one physical (cable).

## 1. Pool health + corruption (`zpool status -v data`)
- Pool ONLINE, 27.2T, **86% full** (23.6T alloc, 3.65T free), **27% frag**.
- **2 permanent errors (both media, re-fetchable)**:
  - `/data/complete/music/John Landis Fans - Songs For The Frozen Latitudes [1999]/05 - Silent Waters.flac`
  - `/data/complete/movies/Schindler's.List.1993.1080p.BluRay.DTS.x264.D-Z0N3.mkv`
- **raidz1-1: 3.19K CKSUM on all 3 disks** (READ/WRITE=0). raidz1-0: 4 CKSUM each. raidz1-2: clean.
- ZIL (ubuntu-vg/zfs_slog_lv 10G) healthy.

### smartctl on raidz1-1 disks → ROOT CAUSE = SATA cable, NOT disk failure
| disk | model | power_on | Realloc | Pending | Uncorrectable | UDMA_CRC |
|---|---|---|---|---|---|---|
| WD-WX42D43AF8PF | WD40EFPX | 18537h (~2.1y) | 0 | 0 | 0 | **0** (clean) |
| WD-WMC1T3168724 | WD30EFRX | 104778h (~12y) | 0 | 0 | 0 | **3** |
| WD-WMC1T3237707 | WD30EFRX | 104777h (~12y) | 0 | 0 | 0 | **4** |

**No reallocated/pending/uncorrectable sectors on any disk → platters are fine.**
The two 12-year-old WD30EFRX drives show UDMA_CRC_Error_Count (3 and 4) = SATA
*cable/interface* CRC errors. That flaky link is what produces the 3.19K ZFS
checksum errors (data corrupted in transit, not on disk).

**Fix (physical, hands-on hme-srv-01):** reseat or replace the SATA cables on
WD-WMC1T3168724 and WD-WMC1T3237707 (and check/swap the SATA ports on the
HBA/motherboard). After the cable fix, `zpool scrub data` should clear the
cksum errors. The 2 permanent-error media files need re-fetch (or `zfs clear`
+ delete to drop the error entries). The WD40EFPX (2y) needs no action.
**Gate any disk replace behind confirmation** — raidz1-1 already has cksum
errors, so a second failure there before the cable fix = data loss risk.

## 2. Free space (#16) — no non-media lever
- `data` USED 15.7T, **USEDSNAP 0B** (snapshots hold NO unique space), REFER 98.1G.
- `data/complete` 14.6T (media — 93% of used). KEEP.
- `data/plex-config` 91.2G (Plex config migrated to local ZFS — expected).
- `data/containerd` 10.5G USED / 7.48M REFER.
- **Conclusion:** the pool is 86% full because of media. Snapshots = 0B lever,
  containerd = ~10G lever. Reaching 80% needs ~1.8T freed → only achievable by
  media pruning (user wants media kept) or adding disks. **WS1c containerd→overlayfs
  is NOT a meaningful space win** — it's an ARC/I/O-relief win (see §4).

## 3. containerd is on the ZFS snapshotter (`/etc/containerd/config.toml`)
- `snapshotter = "zfs"`, `io.containerd.snapshotter.v1.zfs` root_path on the
  HDD `data` pool. Image/layer I/O + hundreds of containerd snapshots live on
  the saturated HDD pool → ZFS metadata churn → ARC pressure.
- **`zfs_l2arc_lv` (50G, SSD, in ubuntu-vg) EXISTS but is DETACHED** (not
  attached as L2ARC; `zpool list -v` shows no cache device). Available to
  repurpose as the SSD backing store for containerd overlayfs.
- **WS1c plan:** move containerd to overlayfs on the 50G SSD LV (or a new LV
  carved from ubuntu-vg free space). Takes containerd image/layer I/O off the
  HDD pool. **This is a destructive node-config op → ansible `roles/containerd`
  from WSL** (drain hme-srv-01, reconfigure containerd `snapshotter=overlayfs`,
  restart containerd, re-pull images). NOT executable from the Git Bash env.
  Update `roles/containerd/defaults/main.yml` to source the SSD LV
  (`/dev/ubuntu-vg/zfs_l2arc_lv` or a new LV) instead of assuming L2ARC reclamation.

## 4. ARC / memory pressure — the Longhorn-killer root cause
- Box RAM: 25G (`memory_all_bytes` 25023401984). Free: 3.7G. Available: 2.77G.
- `zfs_arc_max`=8Gi (c_max 8589934592), **but ARC `size`=14.6Gi** — ARC is
  **I/O-pinned ~6.5Gi ABOVE the cap** and cannot shrink (active metadata refs).
  `memory_throttle_count=0` (hasn't throttled yet).
- This is why Longhorn `engine-image` pods on hme-srv-01 get SIGKILL'd
  (exit 137) under pressure → instance-manager flaps → LH node NotReady →
  csi-plugin can't create socket → PVCs can't attach (seen repeatedly).
- **Durable fix = WS1c** (containerd off ZFS → less ZFS metadata → ARC can
  shrink toward 8G cap → memory headroom). Lowering the cap further won't help
  (ARC is already pinned above it). Temporary relief: `echo 3 > /proc/sys/vm/drop_caches`
  (done before in WS4a, non-durable). Also consider `zfs_arc_shrinker`/`arc_prune`
  tuning and reducing `zfs_arc_meta_limit` pressure in `roles/zfs`.

## 5. ZFS perf tuning (WS1d) — proposed `zfs set`, apply via `roles/zfs`
Safe live changes (new writes only for recordsize; atime/xattr apply going forward):
- `data/complete`: `recordsize=1M` (media), `atime=off`, `xattr=sa`, `relatime=on`
- `data/plex-config`: `recordsize=16K` (Plex SQLite DB), `atime=off`, `xattr=sa`
- `data/containerd`: (moot — moving to overlayfs)
- `data`: `atime=off`, `xattr=sa`, `relatime=on` (defaults for children)
Parameterize as a `roles/zfs` dataset-tuning task; do NOT retroactively rewrite
existing media (recordsize applies to new writes only).

## Remediation summary — who does what
| Item | Fix | Where | Env |
|---|---|---|---|
| raidz1-1 cksum | reseat/replace SATA cables on the 2 WD30EFRX + reseat ports | hme-srv-01 | **physical (user)** |
| 2 corrupt files | re-fetch media (or `zfs clear` + delete) | hme-srv-01 | SSH (gated) |
| containerd→overlayfs on 50G SSD LV | reconfigure containerd + drain + re-pull | hme-srv-01 | **ansible/WSL** |
| ARC relief | flows from containerd→overlayfs; + arc_shrinker/prune tuning | hme-srv-01 | **ansible/WSL** |
| ZFS dataset tuning (recordsize/atime/xattr) | `roles/zfs` task | hme-srv-01 | **ansible/WSL** |
| pool <80% | media-bound — no non-media lever; add disks or accept 86% | — | decision |

**Bottom line:** the dominant in-env next step for hme-srv-01 stability is
WS1c (containerd→overlayfs, ansible/WSL) — it breaks the ARC-pin → memory-pressure
→ Longhorn-engine-kill chain. The cable fix is physical. Pool-full is media-bound.
See also [[baseline-2026-07-19-hme-srv-01-storage-health.md]].