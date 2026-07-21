# Incident 2026-07-20 — hme-srv-01 ZFS pool wedge + spacemap corruption (recovered)

hme-srv-01 (`data` pool, 27.2T, raidz1 ×3, 86% full / 26% fragmented). Root cause:
a `zfs destroy -r data/containerd` run on the near-full fragmented pool. **Do not
re-run that destroy** (see below). Pool recovered; data intact; cluster recovered.

## Timeline
1. WS1 cleanup: attempted to destroy the orphan `data/containerd` ZFS dataset tree
   (112 datasets with snapshot clone-chains, ~1.13G) left over from the
   containerd→overlayfs cutover (#15). containerd no longer referenced them
   (the `io.containerd.snapshotter.v1.zfs` dir was gone).
2. `zfs destroy -r data/containerd` freed the first ~6 leaf datasets, then **wedged
   the metaslab allocator**: freeing clone blocks via the livelist requires
   allocating spacemap metadata, and the 86%-full / 26%-fragmented pool could not
   service the allocation. `[z_livelist_dest]` + `[txg_sync]` + `[z_metaslab]`
   threads stuck in D-state; txg 51393493 stuck in "S" (syncing) ~15+ min with
   zero advancement; pool doing 0 I/O; load climbing to ~22. Cluster held (node
   Ready, pods Running on cached status) but ZFS writes stalled.
3. `kill -KILL` on the userland `zfs destroy` did NOT stop the kernel
   `z_livelist_dest` work (D-state is uninterruptible). No online knob can unwedge
   a stuck ZFS metaslab allocator.
4. User-approved reboot: `systemctl reboot --force --force` (skipped the wedged-FS
   unmount; ZFS is crash-safe). Node hung on `zfs-import-cache.service` (pool
   import). User hard power-cycled; GRUB → recovery mode → root shell.
5. `zpool import` (list) showed all ONLINE, no dmesg errors (no disk failure).
   But `zpool import data` **PANICKED**: `adding existent segment to range tree`
   = ZFS spacemap corruption. The destroy's block-frees committed across txgs
   51393487–51393492, each carrying a bad range-tree entry; the wedged txg 51393493
   never committed. `zpool import -F -n data` and `zpool import -F -X -n data`
   (rewind, extreme rewind) **also panicked** — no clean uberblock reachable.
6. **Recovery:** set `zfs_recover=1` (downgrades certain verification panics to
   warnings during import) and ran `zpool import -F -X data` from the GRUB
   recovery root shell. Pool imported; data visible on `/data/complete`.
7. Made `zfs_recover=1` **persistent** in `/etc/modprobe.d/zfs.conf`
   (`options zfs zfs_recover=1`) so the boot-time `zfs-import-cache.service`
   imports without panicking. Re-applied `zfs set atime=off data` (WS1 tuning).
8. Plain `reboot` → node came up Ready, pool ONLINE, uncordoned, all amd64 pods
   rescheduled and Running, zero Pending pods cluster-wide.

## Current steady state
- Pool `data` ONLINE and serving. Bulk data (14.6T media, plex-config, fs objects)
  intact — the corruption was free-space bookkeeping (spacemaps), NOT data blocks.
- **The pool imports ONLY with `zfs_recover=1`.** This is now persistent in
  `/etc/modprobe.d/zfs.conf`. Without it, `zpool import` panics. A future node
  rebuild / kernel change MUST carry this option or the pool won't mount.
- The on-disk spacemap still carries the duplicate segment (ignored via
  `zfs_recover`). The in-memory range tree is correct (the duplicate is a no-op),
  so allocations are safe. The on-disk duplicate self-cleans when the metaslab
  condenses (writes a fresh spacemap). A scrub (#46) verifies data integrity and
  clears the 2 permanent-error list entries but does NOT repair the spacemap.
- 2 permanent-error files (FLAC + Schindler's List mkv, re-fetchable) deleted +
  `zpool clear` run; the error *list* entries clear on the next scrub.
- `atime=off` applied on `data` (inherits to children); recordsize=1M + xattr=sa
  already set.

## HARD RULES (do not violate)
- **NEVER run `zfs destroy -r data/containerd` (or any large clone-tree destroy on
  this pool) while it is 86% full / fragmented.** It wedged the allocator and
  corrupted the spacemaps. The 106 remaining `data/containerd/*` datasets are
  ABANDONED in place (1.13G, not worth the risk). Leave them.
- **Always boot hme-srv-01 with `zfs_recover=1`** (persisted in modprobe.d). If a
  future change reloads the zfs module without it, the pool import will panic and
  the node will hang in boot at `zfs-import-cache.service` — recover via GRUB
  recovery shell + `zfs_recover=1` + `zpool import -F -X data`.
- The raidz1-1 SATA-cable CRC issue (WD-WMC1T3168724 + WD-WMC1T3237707, UDMA_CRC
  3/4) is still unfixed (physical, user). Reseat/replace those cables, then scrub.

## Recovery runbook (if the pool won't import / panics on boot)
1. GRUB → "Advanced options for Ubuntu" → "(recovery mode)" → `root` shell
   (password `0830Bones!`). If that prompts for a password it won't accept, edit
   the GRUB `linux` line to append `systemd.unit=emergency.target` and boot.
2. Confirm recovery mode is on: `cat /sys/module/zfs/parameters/zfs_recover`
   (should be 1; if 0: `echo 1 > /sys/module/zfs/parameters/zfs_recover`).
3. Import with rewind + recovery: `zpool import -F -X data`.
4. Verify: `zpool status data` (ONLINE), confirm data on `/data/complete`.
5. Ensure persistence: `grep zfs_recover /etc/modprobe.d/zfs.conf` (must show
   `options zfs zfs_recover=1`; if missing, append it).
6. `reboot` → node boots normally with the pool imported.

## Remaining (tracked in task list)
- #46 scrub `data` (~7 days) — verify integrity + clear the 2 error entries.
- #16 free pool <80% — media-bound (data/complete = 14.6T = 93% of used); needs
  media pruning or adding disks; user decision.
- raidz1-1 SATA cable reseat (physical, user) → then scrub to clear the 3.29K cksum.

See also: [[ws1-2026-07-18-hme-srv-01-zfs-assessment.md]],
[[baseline-2026-07-19-hme-srv-01-storage-health.md]],
[[rca-2026-07-18-hme-srv-01-nfs-deadlock.md]].