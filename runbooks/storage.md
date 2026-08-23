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

## Adding the disks as storage

Raw devices, no GPT. These steps wipe them.

Node `pve` > Disks > LVM-Thin > Create: Thinpool, once per device. Name them
`media1` and `media2`.

LVM-Thin rather than plain LVM keeps VM disks on them snapshot-capable. Plain LVM
breaks snapshots for any VM holding a disk there.

### Why not ZFS

ZFS on a hardware RAID virtual drive is the configuration it's designed against,
because the controller hides the per-disk errors ZFS needs to repair anything.
True JBOD weakens that objection, and ZFS on a JBOD-mode MegaRAID does work. The reasons
not to use it here are about the data and the platform:

- **Detection without repair.** Checksums are half the feature. With no redundancy ZFS reports corruption and can't fix it, which gains little over ext4 for files that can be re-downloaded.
- **Compression buys nothing.** lz4 on already-compressed video is wasted cycles.
- **Snapshots don't fit.** A media library is append-mostly, so snapshots would mainly pin deleted files.
- **ARC competes for RAM.** The host runs at ~70% of 94 GiB across two VMs.
- **The VM boundary.** A host ZFS pool can't be bind-mounted into a VM. That needs virtiofs, which landed in PVE 8.4 while this host runs 8.0.3, or an NFS hop from host to guest. ZFS inside the VM instead requires raw disk passthrough, which breaks VM snapshots.

Two ext4 filesystems on thin-pool-backed VM disks work on the current version
with no RAM cost and snapshots intact.

Where ZFS would earn its place is `appdata` rather than media. That is small,
precious data where checksums, snapshots and `zfs send` all pay off. It needs a
real HBA in IT mode and preferably no VM boundary.

## Attaching them to VM 100

Provision below each pool size. A thin volume equal to its pool leaves no room
for copy-on-write, and any snapshot taken afterwards fills it. Roughly 1.0 TB
from a 1.2 TB pool.

VM 100 > Hardware > Add > Hard Disk, once per pool.

### Set backup=0

Media must not enter `vzdump`, or every backup of VM 100 copies terabytes of
replaceable files. That's why backups have run long enough to be cancelled.

```bash
qm set 100 --scsi1 media1:vm-100-disk-1,backup=0,discard=on
qm set 100 --scsi2 media2:vm-100-disk-2,backup=0,discard=on
qm config 100 | grep -E 'scsi[12]'      # both must show backup=0
```

## In the VM

Confirm device names with `lsblk` first. They won't match the host's.

```bash
sudo mkfs.ext4 -L media1 /dev/sdb
sudo mkfs.ext4 -L media2 /dev/sdc
sudo mkdir -p /mnt/media1 /mnt/media2
```

`/etc/fstab`:

```
LABEL=media1  /mnt/media1  ext4  defaults,noatime  0 2
LABEL=media2  /mnt/media2  ext4  defaults,noatime  0 2
```

Separate filesystems, one per disk, so a failure loses that disk's contents and
leaves the other serving.

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

`mergerfs` presents both mounts as a single directory while keeping the
filesystems independent, so failure behaviour is unchanged.

```bash
sudo apt install mergerfs
```

```
/mnt/media1:/mnt/media2  /mnt/media  fuse.mergerfs  defaults,allow_other,category.create=mfs  0 0
```

`category.create=mfs` writes new files to whichever disk has the most free space.

Without mergerfs, add both paths as separate libraries in Jellyfin and separate
root folders in Radarr and Sonarr. All three support that.

SnapRAID isn't worth it at two disks. Parity would consume a full disk, which is
RAID1 with extra steps. Reconsider at four or more.

## Exposing it to the containers

Add a variable to `.env` rather than hardcoding paths:

```
LOCALMEDIADIR=/mnt/media          # or /mnt/media1 without mergerfs
```

Then bind-mount it alongside the NFS media in `compose/jellyfin.yml`,
`compose/radarr.yml` and `compose/sonarr.yml`:

```yaml
      - $LOCALMEDIADIR:/data/local
```

Paths inside `appdata` databases are absolute strings. Adding a second library
root is safe; moving files between roots means updating the path mapping in each
application, not just moving the files.

## Discard has to be enabled per disk

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

## Effect on a host rebuild

Media on the NAS survives a host wipe. Media on the local disks doesn't.

Anything stored locally sits inside the blast radius of a rebuild, so it needs
backing up elsewhere or accepting as re-acquirable. Keeping the local volume to
content you'd be willing to re-download avoids the question.
