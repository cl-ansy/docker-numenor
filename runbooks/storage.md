# Storage

Companions: [access.md](access.md), [updating.md](updating.md).

## Layout

The MegaRAID controller (`UCSC-MRAID12G`) is in RAID mode, so Linux sees *virtual
drives*, not physical disks. Model strings in the Proxmox Disks view name the
controller, not the media.

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

Physical disk topology and RAID levels are only visible in CIMC under
Storage > Modular RAID Controller > Virtual Drive Info. Proxmox cannot show them.

## Disk layout for media: JBOD, not RAID0

Redundancy is deliberately not used here. Media is re-acquirable, and mirroring
halves capacity. The remaining choice is how the two disks are presented.

| Config | Usable | One disk fails |
|---|---|---|
| RAID0 | 2.40 TB | Lose everything |
| **JBOD / two single-disk VDs** | 2.40 TB | Lose that disk only |
| RAID1 | 1.20 TB | Survives |
| LVM linear across both | 2.40 TB | Corrupt filesystem, unpredictable loss |

JBOD wins on identical capacity. Striping buys sequential throughput that this
workload cannot use: a 10K SAS drive sustains 150+ MB/s, and a 4K remux streams at
roughly 12 MB/s. What striping costs is failure granularity, turning a half-library
loss into a whole-library loss.

Do not span the two disks with LVM. A single 2.40 TB filesystem across both means
a disk failure corrupts the filesystem rather than losing a clean half.

### Reconfiguring

The volume is empty, so this is free now and a migration later.

1. CIMC > Storage > Modular RAID Controller. Delete the 2.40 TB RAID0 VD.
2. Enable JBOD if the SAS3108 firmware exposes it, controller-wide or per drive. Otherwise create **two single-disk RAID0 VDs**, which is close to equivalent from the OS side.
3. Confirm two devices appear under Proxmox node `pve` > Disks.

### Only replaceable data

Either way there is no redundancy. Only content that can be downloaded again goes
here. Not `appdata`, secrets, Authentik's database, or anything under `$DOCKERDIR`.

## Adding the disks as storage

Raw devices, no GPT. These steps wipe them.

Proxmox: node `pve` > Disks > LVM-Thin > Create: Thinpool, once per device. Name
them `media1` and `media2`.

LVM-Thin rather than plain LVM, so VM disks on them stay snapshot-capable. Plain
LVM breaks snapshots for any VM holding a disk there.

Avoid the ZFS option for these devices. ZFS on top of a hardware RAID virtual drive
is the configuration ZFS is designed against: the controller hides the per-disk
errors ZFS needs in order to repair anything, leaving the overhead without the
benefit.

## Attaching them to VM 100

Provision **below** each pool size. A thin volume equal to its pool leaves no room
for copy-on-write, and any snapshot taken afterwards fills it.

```
1.20 TB pool -> provision ~1.0 TB, leaving ~200 GB headroom
```

VM 100 > Hardware > Add > Hard Disk, once per pool.

### Set backup=0

Media must not enter `vzdump`. Without this, every backup of VM 100 copies
terabytes of replaceable files. This is the current cause of backups running long
enough to be cancelled.

```bash
qm set 100 --scsi1 media1:vm-100-disk-1,backup=0
qm set 100 --scsi2 media2:vm-100-disk-2,backup=0
```

Verify:

```bash
qm config 100 | grep -E 'scsi[12]'      # both must show backup=0
```

## In the VM

Confirm device names with `lsblk` first; they will not match the host's.

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

Separate filesystems, one per disk. A failure loses that disk's contents and
leaves the other mounted and serving.

Docker must not start before these mount, for the same reason as the NFS mount:

```
# /etc/systemd/system/docker.service.d/nfs.conf
[Unit]
RequiresMountsFor=/nfs/readynas/shared /mnt/media1 /mnt/media2
```

```bash
sudo systemctl daemon-reload
```

### Optional: one path instead of two

`mergerfs` presents both mounts as a single directory while keeping the underlying
filesystems independent, so the failure behaviour above is unchanged.

```bash
sudo apt install mergerfs
```

```
/mnt/media1:/mnt/media2  /mnt/media  fuse.mergerfs  defaults,allow_other,category.create=mfs  0 0
```

`category.create=mfs` writes new files to the disk with the most free space.

Without mergerfs, add both paths as separate libraries in Jellyfin and separate
root folders in Radarr and Sonarr. All three support that natively.

SnapRAID is not worth adding at two disks: parity would consume a full disk, which
is RAID1 with extra steps. Reconsider at four or more.

## Exposing it to the containers

Add a variable to `.env` rather than hardcoding paths:

```
LOCALMEDIADIR=/mnt/media          # or /mnt/media1 if not using mergerfs
```

Then bind-mount it alongside the existing NFS media in the services that need it
(`compose/jellyfin.yml`, `compose/radarr.yml`, `compose/sonarr.yml`):

```yaml
      - $LOCALMEDIADIR:/data/local
```

Paths inside `appdata` databases are absolute strings. Adding a second library
root is safe; **moving files between roots requires updating the path mapping in
each application**, not just moving the files.

## Monitoring

All pools, on the host:

```bash
vgs
lvs -a -o lv_name,vg_name,lv_size,data_percent,metadata_percent
```

`data_percent` approaching 100 takes thin volumes read-only. `metadata_percent`
does the same and fills faster when snapshots exist. See the thin pool notes in
[updating.md](updating.md).

The `pve/data` pool is overcommitted: provisioned virtual size exceeds the volume
group. That is normal for thin provisioning and only matters if written data
approaches the physical size.

## What this changes about the migration

`.plans/proxmox-migration.md` assumes all media lives on the ReadyNAS and
therefore survives a host wipe untouched. Media on the local disks does not.

Anything stored locally is inside the blast radius of a rebuild and must either be
backed up elsewhere or accepted as re-acquirable. Keeping the local volume to
content you are willing to re-download preserves the original assumption.
