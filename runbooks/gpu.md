# Intel Arc A310 passthrough

See also [access.md](access.md), [latency.md](latency.md), [storage.md](storage.md).

Hardware transcoding for Jellyfin. The card is passed from the Proxmox host to
VM 100, and from there into the Jellyfin container.

How this configuration was arrived at, including the dead ends, is in
`notes/gpu-case-study.md`.

## State as of 2026-08-30 - decode only, encode abandoned

| Layer | State |
|---|---|
| Card | Intel Arc A310, DG2 `[8086:56a6]` |
| Host | Passed through as `hostpci0` / `hostpci1`, bound to `vfio-pci` |
| Guest | Debian 13.6, kernel 6.12, driver `xe` (not i915) |
| Kernel driver | Working. GuC and DMC firmware load, `renderD128` present |
| VA-API userspace | `media-driver 26.3.1`, built against `debian:trixie`, overlaid onto the jellyfin-ffmpeg image |
| Decode | Working. MPEG2, H264, HEVC, VP9, AV1 all confirmed in real transcodes, not just `vainfo` |
| Encode | **Not working.** Fails on frame zero every time, both via QSV and pure VAAPI. Not pursuing further - see below |
| BAR | 256MB, can't be enlarged on this platform |

The card gets a 256MB CPU-visible window instead of the 4GB it asks for, because
the PCI bridges above it decode prefetchable memory as 32-bit only. That's
firmware-level and can't be fixed here.

The card still decodes despite it.
[intel/media-driver#1990](https://github.com/intel/media-driver/pull/1990)
(merged 2026-07-15) teaches the VA-API driver to allocate inside the visible
window. Anything older crashes with SIGBUS on decode too.

### Encode doesn't work, and isn't worth chasing further

`vainfo` reports full encode capability - `VAEntrypointEncSliceLP` listed for
H264, HEVC, VP9 and AV1 - but that's a capability query, not a working
pipeline. Every real encode attempt failed on the first frame, every time,
across three different tests:

| Path | Content | Error |
|---|---|---|
| QSV (`h264_qsv`, VAAPI-derived) | 1080p Blu-ray remux + subtitle overlay | `Error during encoding: GPU Hang (-21)` |
| QSV (`h264_qsv`, VAAPI-derived) | 720p Live TV, plain decode+encode | `Invalid FrameType:0` |
| Pure VAAPI (`h264_vaapi`, no QSV bridge) | 1080p Blu-ray remux + subtitle overlay | `Failed to map output buffers: 24 (internal encoding error)` |

Three different specific errors, but identical failure point every time -
first frame, at encode submission, never during decode. Two candidate causes,
not distinguished:

1. **Encode's buffer footprint doesn't fit the 256MB window.** Decode only
   needs a couple of small reference-frame buffers live at once. Encode needs
   several reference frames, working buffers, and a pool of coded-output
   buffers simultaneously - the `24` in the VAAPI error is very likely that
   pool's size. `gpu.md`'s own small-BAR section already flagged that both
   decoded input and encoded output funnel through the same 256MB, written
   before any encode had actually been tried.
2. **This specific driver build's encode path is simply immature.** Encode is
   consistently the rougher, later-hardened side of GPU driver development
   compared to decode, and multiple unrelated community reports describe Arc
   encode specifically as rockier than decode. This is also a driver built
   from source today, with zero real-world testing before it hit this exact
   pipeline.

A lower-resolution encode test would separate these (small encode succeeding
would point at the BAR; failing identically would point at the driver) but
wasn't run - decode-only was judged good enough to stop here rather than keep
debugging a card that structurally can't get more BAR window on this
platform regardless of the answer.

### Chassis swap doesn't fix this either

Moving the existing CPUs to a different chassis (a Dell PowerEdge R630 was
considered) wouldn't help. ReBAR support is tied to the CPU/chipset
generation, not the chassis vendor - Dell's own community forum has a thread
requesting ReBAR support for PowerEdge "R\*40 and up" (14th generation,
Skylake-SP era), implying nothing before it, including the R630, has it. The
R630 is the same generation as this box's Haswell-EP Xeons - moving those
CPUs into a same-era chassis of any brand carries the limitation with them.
Actually fixing it means a full platform replacement - new CPUs on a newer
socket, new RAM - not a chassis swap.

### The actual plan: NVENC, no ReBAR dependency

NVIDIA cards have never had a documented ReBAR requirement for NVENC
transcoding, unlike the specific small-BAR crash pattern documented for Arc
([intel/media-driver#1927](https://github.com/intel/media-driver/issues/1927)).
Best-reasoned explanation, not something verifiable from closed-source
driver internals the way Intel's open-source driver was: encoded output is
compressed, and therefore much smaller than the raw frame buffers a decode
or filter pipeline moves around, so it comfortably fits through any BAR size.
NVIDIA's driver has also had two decades of production hardening around
small-BAR-by-default operation, since that was the universal default for
every GPU before ReBAR existed as a spec at all (~2020).

Candidates, both slot-powered with no auxiliary connector, matching the
requirement already in the fallback section below: a **Tesla P4** (Pascal,
75W, HEVC encode but 8-bit only, no AV1) or a **Quadro T400/T600** (Turing,
~30-40W, meaningfully better NVENC quality than Pascal - up to 25% better
HEVC bitrate efficiency - still no AV1 encode). Neither matches the A310's
codec breadth (no AV1 encode on either), but either should just work for
H264/HEVC encode without touching ReBAR at all.

Current Jellyfin config: hardware acceleration on, decode codecs enabled,
**"Enable hardware encoding" turned off** - decode is real and worth keeping,
software `libx264` handles encode until an NVENC card replaces this one.

### Small BAR does not mean 256MB of VRAM

All 4GB stays usable. The BAR is the CPU's window into VRAM, not a cap on it.
The GPU addresses its own memory directly, without going through the BAR. dmesg
reports both numbers:

```
VRAM[0,0]: Actual physical size 0x100000000    (4GB)
           CPU accessible size 0x10000000      (256MB)
Available VRAM: 0xfd000000                      (~3.95GB)
```

It isn't a sliding window paging the whole 4GB through either. The driver splits
VRAM into a CPU-visible region and the rest, then places each allocation
accordingly: buffers the CPU never touches go anywhere, and buffers it reads or
writes get flagged `NEEDS_VISIBLE_VRAM` and land in the 256MB region, or are
staged through it.

The cost is throughput rather than capacity. Source frames in and encoded output
back both funnel through 256MB. That is fine for 1080p. 4K with large frame
buffers will feel it more.

## Host configuration

Two manual changes on the Proxmox host. Everything else is automatic.

**IOMMU** in `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on"
```

then `update-grub` and reboot. Verify:

```bash
cat /proc/cmdline | grep intel_iommu
dmesg | grep -i -e DMAR -e IOMMU | head      # want "DMAR: IOMMU enabled"
```

`iommu=pt` isn't set and isn't needed. It only optimises devices that aren't
passed through.

**vfio modules** in `/etc/modules`:

```
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
```

`vfio_virqfd` merged into vfio core in kernel 6.2 and is a no-op here.

### What's deliberately absent

There's no `/etc/modprobe.d/vfio.conf` with `ids=`, and no `blacklist i915`.
Neither is needed. Modern Proxmox unbinds the host driver and binds `vfio-pci`
when a VM with `hostpci` starts. The static `ids=` approach is PVE 5/6-era
advice.

Confirm binding:

```bash
lspci -nnk -s 86:00
lspci -nnk -s 87:00
```

Both should say `Kernel driver in use: vfio-pci`. With no VM running, the host's
own i915 claims the card instead. That is harmless, because starting the VM
rebinds it.

### Risk when the host kernel is upgraded

The host runs kernel 6.2, which can't drive DG2, so i915 has never competed for
the card. Past 6.8 it can, and may claim the device at boot before Proxmox binds
vfio.

If passthrough breaks after a host upgrade, check this first:

```bash
lspci -nnk -s 86:00 | grep 'Kernel driver'    # want vfio-pci
```

The fix is the config that's currently unnecessary:

```
# /etc/modprobe.d/vfio.conf
options vfio-pci ids=8086:56a6,8086:4f92
softdep i915 pre: vfio-pci
```

then `update-initramfs -u` and reboot.

### Why two PCI devices

One card. Arc puts its HDMI audio controller behind the card's own internal PCIe
switch, so it lands on a separate bus rather than as function `.1`:

| Host | Guest | Device |
|---|---|---|
| `0000:86:00` | `00:10.0` | `[8086:56a6]` Arc A310 |
| `0000:87:00` | `00:11.0` | `[8086:4f92]` DG2 Audio Controller |

Only the GPU is used, but vfio binds a whole IOMMU group, so both stay attached.

## Guest configuration

Debian 13 / kernel 6.12. On 6.12 i915 still claims DG2 by default, reaches
`intel_pcode_init` and times out after ~193 seconds, which also makes boots very
slow. `xe` is the correct driver for Alchemist.

`/etc/modprobe.d/xe.conf`:

```
options i915 force_probe=!56a6
options xe force_probe=56a6
```

then `update-initramfs -u` and reboot. modprobe.d rather than the GRUB command
line so it survives kernel upgrades, and `update-initramfs` because DRM drivers
can load from the initramfs.

This may become unnecessary if a future kernel makes `xe` the default for DG2.

Verify:

```bash
ls -l /dev/dri                              # want card1 + renderD128
sudo dmesg | grep -iE '\bxe\b|guc|huc'      # firmware loaded, xe initialised
```

`card0` is the virtual VGA and stays. `Cannot find any crtc or sizes` is expected
with no display attached.

## Getting a working VA-API driver

Needs media-driver 26.3.1 or later. Nothing packaged has it as of 2026-08-22.
Debian trixie is 25.2.3 and sid is 26.1.6.

Release dates aren't commit cutoffs. `intel-media-26.2.4` was published
2026-07-30, after the fix merged, but its branch was cut 2026-06-29 and doesn't
contain it. Check any tag:

```bash
git log --oneline <tag> | grep -i 'small bar'
```

### From a package, once one exists

`dpkg -x` avoids a system install:

```bash
dpkg -x intel-media-va-driver_26.3.x_amd64.deb /tmp/ihd
sudo mkdir -p /opt/iHD
sudo cp /tmp/ihd/usr/lib/x86_64-linux-gnu/dri/iHD_drv_video.so /opt/iHD/
```

### From source

`build/media-driver/` builds a tagged release in a container and writes the
driver plus `libigdgmm` to `/opt/iHD`:

```bash
./build/media-driver/build.sh                                      # 26.3.1
MEDIA_DRIVER_TAG=intel-media-26.3.2 ./build/media-driver/build.sh
```

Four things that each cost a build cycle:

- **Base is `debian:sid`** for libva 1.24. If the driver fails in the container with `GLIBC_2.xx not found`, sid has moved past the container's glibc. Switch to `debian:trixie`, which matches at 2.41. trixie's libva 1.22 still works, because libva falls back through older `__vaDriverInit_<maj>_<min>` symbols.
- **`-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.** sid's CMake 4.x dropped `cmake_minimum_required(VERSION <3.5)`, which media-driver's vendored `cmrtlib` still declares. Needed for the gmmlib build too.
- **gmmlib must be installed, not just checked out beside it.** media-driver finds it via `pkg_check_modules(igdgmm)`, which reads `igdgmm.pc`.
- **`-DCMAKE_BUILD_TYPE=Release` must be explicit.** media-driver prints `BUILD_TYPE not defined, default to: release` about its own variable, not CMake's. Without it you get an unoptimised 576MB `.so` instead of ~40MB.

Delete `build/media-driver/` once Debian or jellyfin-ffmpeg ships 26.3.x. It
bridges a packaging lag and an unpackaged binary isn't worth keeping past that.

## Wiring it into Jellyfin

In `compose/jellyfin.yml`, add the render device and the host's numeric render
GID:

```yaml
    devices:
      - /dev/dri:/dev/dri
    group_add:
      - "105"                     # getent group render
```

The numeric GID is required. The service runs `user: $PUID:$PGID`, which drops
supplementary groups, and a group name won't resolve inside the container.

### The driver has to overlay the bundled one, not sit beside it

`LIBVA_DRIVERS_PATH`/`LD_LIBRARY_PATH` pointed at `/opt/iHD` is the documented,
standard way to redirect libva to an external driver - and it doesn't work
here. jellyfin-ffmpeg's bundled `libva.so.2` is hardcoded to only search its
own `/usr/lib/jellyfin-ffmpeg/lib/dri`, ignoring `LIBVA_DRIVERS_PATH` even set
explicitly inline on the command, not just inherited from the container
environment. Confirmed by testing both.

The fix is to bind-mount the built files directly over the bundled,
SIGBUS-crashing ones, at the exact paths jellyfin-ffmpeg is hardcoded to load
from:

```yaml
    volumes:
      - /opt/iHD/iHD_drv_video.so:/usr/lib/jellyfin-ffmpeg/lib/dri/iHD_drv_video.so:ro
      - /opt/iHD/libigdgmm.so.12.10.0:/usr/lib/jellyfin-ffmpeg/lib/libigdgmm.so.12.9.0:ro
```

The `libigdgmm` mount targets the *bundled* filename
(`libigdgmm.so.12.9.0`), not whatever version number the build actually
produced - `gmmlib` isn't pinned to a tag in `build.sh`, so its version drifts
between builds. Match the mount's target to whatever's currently bundled
(`ls /usr/lib/jellyfin-ffmpeg/lib/ | grep gmm` in the container) rather than
assuming it's still `.12.9.0`.

```bash
dcup
sudo docker exec -it jellyfin sh -c \
  '/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128; echo exit=$?'
```

| Result | Meaning |
|---|---|
| `exit=0` with profiles listed | Working |
| `Bus error`, exit=135 | Still SIGBUS. Driver too old, or the overlay isn't reaching the container |
| `has no function __vaDriverInit_1_0` | Driver built against a libva newer than the runtime's. Rebuild on `debian:trixie`, not `sid` - see the Dockerfile comments |
| `Failed to open the given device!` | `/dev/dri` isn't mounted, or the container hasn't been recreated since it was added - check `docker exec jellyfin ls -l /dev/dri` |
| `GLIBC_2.xx not found` | Build base too new for the container's glibc; rebuild on `debian:trixie` |

Then turn on QSV or VAAPI in Jellyfin > Dashboard > Playback. It doesn't switch
on by itself. Watch a forced transcode with `intel_gpu_top` to confirm.

### Building it

`-j"$(nproc)"` in the Dockerfile is capped at half of `nproc`, not full. A
full-parallelism build of media-driver's codec backend once pushed this VM's
shared vCPUs into enough memory pressure to hang the entire guest -
unresponsive to SSH and to the Proxmox console both, needing a hard
`qm stop`/`qm start` to recover. Nothing else sharing that VM survives a full
box hang gracefully.

## What hardware transcode does and doesn't fix

It improves throughput and concurrent stream count, and barely affects time to
first frame. See [latency.md](latency.md), which found playback start delay here
is a storage problem rather than a compute one.

| Symptom | GPU helps |
|---|---|
| Buffering or stutter mid-playback | Yes |
| Second stream degrades both | Yes |
| 4K HEVC unwatchable, 1080p fine | Yes |
| Slow to start, then plays fine | No |

## Fallbacks

**Software transcode.** Dual E5-2680 v3, 48 threads, `libx264` scales well:
comfortable for 1080p and several concurrent streams, expensive for 4K HEVC -
roughly one stream, possibly not real-time. Works today with no changes.

**An NVIDIA card.** NVENC has no ReBAR requirement, sidestepping this entirely.
Prefer 75W slot-powered with no auxiliary connector. A Tesla P4 is the classic
UCS fit; a Quadro T400/T600 is a lower-power modern option on a current driver
branch. Needs the NVIDIA driver plus `nvidia-container-toolkit` in the guest, and
a `deploy.resources.reservations.devices` block rather than `/dev/dri`.

Check chassis fan behaviour with any card. UCS fan curves key off recognised
components, and an unrecognised PCIe card can pin the fans high permanently.

## Attacking the small BAR directly

Optional now that the driver fix works within the 256MB window. Both need a
console, either physical or CIMC configured per [access.md](access.md):

1. **BIOS**: F2 > Advanced > PCI Configuration > Memory Mapped I/O Above 4 GB. Cisco documents this as enabled by default and the evidence suggests it already is.
2. **A different PCIe slot.** `80:03.0` is a CPU2 root port; CPU1's slots were allocated separately by firmware.

Both are low-probability. The full investigation is in
`notes/gpu-case-study.md`.
