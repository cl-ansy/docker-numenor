# Storage

See also [access.md](access.md), [updating.md](updating.md).

## Layout

The MegaRAID controller is in RAID mode, so Linux sees virtual drives rather than
physical disks. Model strings in the Proxmox Disks view name the controller, not
the media.

| Device | Size | Contents |
|---|---|---|
| `/dev/sda` | 1.20 TB | Boot VD. EFI partition + LVM partition holding VG `pve` |
| `/dev/sdb` | 2.40 TB | 2 x 1.2 TB in RAID0. To be reconfigured, see below |

VG `pve` on `/dev/sda` holds:

| LV | Purpose | Proxmox storage |
|---|---|---|
| `pve/root` | Root filesystem, `/var/lib/vz` | `local` |
| `pve/swap` | Swap | |
| `pve/data` | Thin pool | `local-lvm` |

Physical disk topology and RAID levels are only visible in CIMC under Storage >
Modular RAID Controller > Virtual Drive Info. Proxmox can't show them.

## Media disks: JBOD rather than RAID0

No redundancy here by choice. Media is re-acquirable, and mirroring halves
capacity. The only question is how the two disks are presented.

| Config | Usable | One disk fails |
|---|---|---|
| RAID0 | 2.40 TB | Lose everything |
| **JBOD / two single-disk VDs** | 2.40 TB | Lose that disk only |
| RAID1 | 1.20 TB | Survives |
| LVM linear across both | 2.40 TB | Corrupt filesystem, unpredictable loss |

JBOD gives identical capacity. Striping buys sequential throughput this workload
can't use: a 10K SAS drive sustains 150+ MB/s and a 4K remux streams at roughly
12 MB/s. What it costs is failure granularity, turning a half-library loss into a
whole-library loss.

Don't span the two disks with LVM either. A single 2.40 TB filesystem across both
means a disk failure corrupts the filesystem rather than losing a clean half.

### Reconfiguring

The volume is empty, so this costs nothing now and would be a migration later.

1. CIMC > Storage > Modular RAID Controller. Delete the 2.40 TB RAID0 VD.
2. Enable JBOD if the SAS3108 firmware exposes it, controller-wide or per drive. Otherwise create two single-disk RAID0 VDs, which is close to equivalent from the OS side.
3. Confirm two devices appear under node `pve` > Disks.

### Only replaceable data

There's no redundancy either way, so only content that can be downloaded again
goes here. Not `appdata`, secrets, Authentik's database, or anything under
`$DOCKERDIR`.

## Preparing the disks on the host

Raw devices, no GPT. These steps wipe them.

```bash
sudo mkfs.ext4 -L media1 /dev/sdb
sudo mkfs.ext4 -L media2 /dev/sdc
sudo mkdir -p /mnt/media1 /mnt/media2
```

`/etc/fstab` on the **host**:

```
LABEL=media1  /mnt/media1  ext4  defaults,noatime  0 2
LABEL=media2  /mnt/media2  ext4  defaults,noatime  0 2
```

Plain filesystems, mounted by the host. No LVM-thin pool, no Proxmox-managed
storage entry, no VM disk.

Separate filesystems, one per disk, so a failure loses that disk's contents and
leaves the other serving.

### Why not a VM disk

The original plan here was an LVM-Thin pool per disk, attached to VM 100 as a
normal virtual disk (`qm set ... discard=on`). That sweeps the disk into every
snapshot ever taken of VM 100.

Measured on 2026-09-12: a VM snapshot from four days earlier, combined with a
heavy write burst from a bulk media redownload, stalled the whole guest for
about 12 minutes. Not from the pool running out of space - from copy-on-write
overhead on every write while the snapshot existed. See "Discard has to be
enabled per disk" below for the related capacity failure mode, and
`updating.md`'s snapshot section for why snapshots get taken at all. A VM disk
is exposed to this every time the VM is snapshotted, for as long as the
snapshot exists.

Keeping media and downloads as host filesystems, shared into the guest with
virtiofs (below), avoids this entirely: they're never a VM block device, so
`qm snapshot` can't touch them.

### Why not ZFS

ZFS on a hardware RAID virtual drive is the configuration it's designed against,
because the controller hides the per-disk errors ZFS needs to repair anything.
True JBOD weakens that objection, and ZFS on a JBOD-mode MegaRAID does work. The reasons
not to use it here are about the data and the platform:

- **Detection without repair.** Checksums are half the feature. With no redundancy ZFS reports corruption and can't fix it, which gains little over ext4 for files that can be re-downloaded.
- **Compression buys nothing.** lz4 on already-compressed video is wasted cycles.
- **Snapshots don't fit.** A media library is append-mostly, so snapshots would mainly pin deleted files.
- **ARC competes for RAM.** The host runs at ~70% of 94 GiB across two VMs.
- **The VM boundary is no longer the blocker.** virtiofs (below) solves host-to-guest sharing without raw disk passthrough, so this reason alone wouldn't rule ZFS out anymore. The other four still do.

Two ext4 filesystems on the host, shared into the guest with virtiofs, work
with no RAM cost and no VM-disk exposure at all.

Where ZFS would earn its place is `appdata` rather than media. That is small,
precious data where checksums, snapshots and `zfs send` all pay off. It needs a
real HBA in IT mode.

## Sharing them into VM 100 with virtiofs

Requires Proxmox 8.4+; this host was on 8.0.3 as of 2026-09-12. Upgrade first
and confirm VM 100 and its GPU passthrough (see [gpu.md](gpu.md)) still come
up clean before doing this.

Datacenter > Resource Mappings > Directory Mappings > Add, once per host path:

| Mapping name | Host path |
|---|---|
| `media1` | `/mnt/media1` |
| `media2` | `/mnt/media2` |
| `downloads` | wherever `$DOWNLOADSDIR` resolves to, see below |

Then VM 100 > Hardware > Add > VirtIO FS, once per mapping, each using its
mapping name as the tag.

No `backup=0`, no `discard=on`. Neither applies - virtiofs shares aren't VM
disks, so `vzdump` and `qm snapshot` don't see them at all.

## In the guest

Mount by the tag set in VM Hardware, not a device name:

`/etc/fstab`:

```
media1  /mnt/media1  virtiofs  defaults  0 0
media2  /mnt/media2  virtiofs  defaults  0 0
```

Docker must not start before these mount, same as the NFS mount:

```
# /etc/systemd/system/docker.service.d/nfs.conf
[Unit]
RequiresMountsFor=/nfs/<share>/shared /mnt/media1 /mnt/media2
```

```bash
sudo systemctl daemon-reload
```

### Optional: one path instead of two

Run `mergerfs` on the **host**, merging both filesystems before they're ever
shared, and map a single virtiofs mapping for the merged path instead of two.
That keeps the guest side to one mapping and one mount, and no fuse dependency
inside the guest itself.

```bash
sudo apt install mergerfs
```

```
# host: /etc/fstab
/mnt/media1:/mnt/media2  /mnt/media  fuse.mergerfs  defaults,allow_other,category.create=mfs  0 0
```

`category.create=mfs` writes new files to whichever disk has the most free
space. Map `/mnt/media` as the single Directory Mapping instead of `media1`
and `media2` separately.

Without mergerfs, add both paths as separate libraries in Jellyfin and separate
root folders in Radarr and Sonarr. All three support that.

SnapRAID isn't worth it at two disks. Parity would consume a full disk, which is
RAID1 with extra steps. Reconsider at four or more.

## Downloads

`$DOWNLOADSDIR` lives on `vm-100-disk-0` today - the same disk that stalled on
2026-09-12 (see [Why not a VM disk](#why-not-a-vm-disk)). Move it too: its own
disk, or its own directory on one of the media disks, with its own virtiofs
mapping. It was the download write burst that caused the stall, not the media
itself - leaving it behind defeats the point.

## Exposing it to the containers

Add variables to `.env` rather than hardcoding paths:

```
LOCALMEDIADIR=/mnt/media          # or /mnt/media1 without mergerfs
DOWNLOADSDIR=/mnt/downloads
```

Then bind-mount `$LOCALMEDIADIR` alongside the NFS media in
`compose/jellyfin.yml`, `compose/radarr.yml` and `compose/sonarr.yml`:

```yaml
      - $LOCALMEDIADIR:/data/local
```

`$DOWNLOADSDIR` is already bind-mounted into `compose/sabnzbd.yml` - only the
host path behind it changes, from `vm-100-disk-0` to the virtiofs mount.

Paths inside `appdata` databases are absolute strings. Adding a second library
root is safe; moving files between roots means updating the path mapping in each
application, not just moving the files.

## Discard has to be enabled per disk

This section is about `vm-100-disk-0` and any other disk actually attached to
a VM as a block device - media and downloads move off that model entirely
(above). This is the capacity-exhaustion version of the problem; [Why not a VM
disk](#why-not-a-vm-disk) above is the latency/stall version. Same root cause,
copy-on-write blocks accumulating in the pool, two different symptoms.

Deleting a file inside a guest frees blocks in the filesystem's own metadata and
tells the storage layer nothing. LVM-thin keeps every block ever written
allocated until something issues TRIM for it.

Proxmox doesn't enable discard by default. Without it the guest device still
advertises discard support, `fstrim` runs and reports success, and QEMU drops the
requests.

Measured on VM 100, 2026-08-22, guest filesystem 181G used of 491G:

| | Before | After `discard=on` + `fstrim` |
|---|---|---|
| `pve/data` pool | 59.81% | 21.61% |
| `vm-100-disk-0` | 99.21% | 38.33% |

The first `fstrim -av` reported 309.2 GiB trimmed and moved nothing. The same
command after enabling discard reclaimed ~380G including a deleted snapshot.
38.33% of 500G now matches actual guest usage rather than every block ever
written.

**`fstrim` output proves nothing.** It reports what the filesystem walked, not
what the storage honoured. Verify at the pool:

```bash
lvs -o lv_name,data_percent pve    # host, before
sudo fstrim -av                    # guest
lvs -o lv_name,data_percent pve    # host, after
```

Unchanged means discard isn't reaching LVM-thin.

The fix is per disk and needs a stop/start, not a guest reboot:

```bash
qm delsnapshot <vmid> <name>       # snapshots pin blocks; delete first
qm shutdown <vmid>
qm set <vmid> --scsi0 local-lvm:vm-<vmid>-disk-0,iothread=1,discard=on
qm start <vmid>
```

Then in the guest:

```bash
sudo fstrim -av
sudo systemctl enable --now fstrim.timer
```

`fstrim.timer` may already be enabled and running weekly against a device that
ignores it. Enabled isn't the same as effective.

Set `discard=on` on any new disk at creation.

## Monitoring

All pools, on the host:

```bash
vgs
lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent
```

`data_percent` approaching 100 takes thin volumes read-only. `metadata_percent`
does the same and fills faster when snapshots exist.

The `pve/data` pool is overcommitted, meaning provisioned virtual size exceeds
the volume group. That's normal for thin provisioning and only matters if written
data approaches the physical size.

Also check for stale snapshots directly - the failure mode above doesn't show
up in `data_percent` until it's already caused a stall:

```bash
qm listsnapshot 100
```

Anything older than the maintenance window it was taken for should be deleted.

## Effect on a host rebuild

Media on the NAS survives a host wipe. Media on the local disks doesn't,
whether it's sitting on a VM disk or a host filesystem shared with virtiofs -
either way it's on this machine's own storage.

Anything stored locally sits inside the blast radius of a rebuild, so it needs
backing up elsewhere or accepting as re-acquirable. Keeping the local volume to
content you'd be willing to re-download avoids the question.
