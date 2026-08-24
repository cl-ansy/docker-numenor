# An Arc A310 that wouldn't transcode

A debugging session where every layer looked like the answer and wasn't. The
wrong turns are more useful than the fix, so they're kept here.

**Hardware:** Cisco UCS C240 M4 (dual Xeon E5-2680 v3, Haswell-EP, 2015-era),
Proxmox host, Debian guest running a Docker media stack, Intel Arc A310 passed
through to the guest for Jellyfin hardware transcoding.

**Symptom:** the card had never worked. An earlier attempt had been abandoned.

---

## 1. GPU isn't there

Passthrough was configured, with `hostpci0` and `hostpci1` on the VM, but the
guest saw nothing usable:

```console
$ ls -l /dev/dri
total 0
drwxr-xr-x  2 root root      60 Aug 22 13:38 by-path
crw-rw----+ 1 root video 226, 0 Aug 22 13:38 card0
```

Common advice for GPU passthrough says you need OVMF (UEFI) and the q35 machine
type. This VM ran SeaBIOS and i440fx, so that looked like the answer.

It wasn't. `lspci` in the guest showed the card enumerated fine:

```console
$ lspci -nn | grep -iE 'vga|display|intel corporation'
00:02.0 VGA compatible controller [0300]: Device [1234:1111] (rev 02)
00:10.0 VGA compatible controller [0300]: Intel Corporation DG2 [Arc A310] [8086:56a6] (rev 05)
00:11.0 Audio device [0403]: Intel Corporation DG2 Audio Controller [8086:4f92]
```

`00:02.0` is the virtual VGA. The Arc is at `00:10.0`, present and enumerated.

Passthrough was working. Rebuilding the VM's boot configuration would have been
days of work for nothing.

*(Two PCI devices for one card because Arc puts its HDMI audio controller behind
the card's own internal PCIe switch, on a separate bus. NVIDIA and AMD use
function `.1` on the same device.)*

---

## 2: Driver won't bind

`dmesg` had the real message:

```console
$ dmesg | grep -iE 'i915|xe |drm' | head
[    1.819675] [drm] Initialized bochs-drm 1.0.0 for 0000:00:02.0 on minor 0
[    2.213222] i915 0000:00:10.0: Your graphics device 56a6 is not properly
               supported by i915 in this kernel version. To force driver probe
               anyway, use i915.force_probe=56a6
```

The guest was Debian 12 on kernel 6.1, and DG2/Alchemist support landed later.
Upgrading to Debian 13 / kernel 6.12 produced a new error:

```console
$ uname -r
6.12.101+deb13-amd64
$ dmesg | grep -iE 'i915|forcewake' | tail
[    2.954908] i915 0000:00:10.0: [drm] *ERROR* gt: timed out waiting for forcewake ack request.
[  193.057541] i915 0000:00:10.0: [drm] *ERROR* GT0: intel_pcode_init failed -110
[  193.072811] i915 0000:00:10.0: [drm] *ERROR* Device initialization failed (-110)
[  193.073051] i915 0000:00:10.0: probe with driver i915 failed with error -110
               use xe.force_probe='56a6' and i915.force_probe='!56a6'
```

The kernel printed its own fix. `xe` is the correct driver for Alchemist; i915's
DG2 support is the legacy path. Selected in `/etc/modprobe.d/xe.conf`:

```
options i915 force_probe=!56a6
options xe force_probe=56a6
```

After `update-initramfs -u` and a reboot it bound cleanly, with GuC and DMC
firmware loaded and a render node:

```console
$ dmesg | grep -iE '\bxe\b|guc|huc'
[    2.721805] xe 0000:00:10.0: [drm] Found DG2/G11 (device ID 56a6) display version 13.00 stepping C0
[    2.724173] xe 0000:00:10.0: [drm] Using GuC firmware from i915/dg2_guc_70.bin version 70.36.0
[    2.751668] xe 0000:00:10.0: [drm] Finished loading DMC firmware i915/dg2_dmc_ver2_08.bin (v2.8)
[    2.867391] [drm] Initialized xe 1.1.0 for 0000:00:10.0 on minor 1

$ ls -l /dev/dri
crw-rw----+ 1 root video  226,   0 card0
crw-rw----+ 1 root video  226,   1 card1
crw-rw----+ 1 root render 226, 128 renderD128
```

Kernels often tell you exactly what to do. The 193-second `intel_pcode_init`
timeout also explained why boots had become slow, a symptom that had looked
unrelated.

---

## 3. Userspace crashes anyway

```console
$ docker exec -it jellyfin sh -c \
    '/usr/lib/jellyfin-ffmpeg/vainfo --display drm --device /dev/dri/renderD128; echo exit=$?'
Trying display: drm
libva info: VA-API version 1.23.0
libva info: Trying to open /usr/lib/jellyfin-ffmpeg/lib/dri/iHD_drv_video.so
libva info: Found init function __vaDriverInit_1_23
Bus error
exit=135
```

Exit 135 is 128 + 7, meaning SIGBUS.

The driver loads, then dies. Debian's `intel-media-va-driver` and Jellyfin's
bundled build failed the same way, and the kernel logged nothing. The issue was
entirely in userspace.

The cause had been scrolling past in the `xe` init messages:

```console
$ dmesg | grep -iE 'bar|vram'
[    2.332437] xe 0000:00:10.0: [drm] Failed to resize BAR2 to 4096M (-ENOTSUPP)
[    2.753268] xe 0000:00:10.0: [drm] Small BAR device
[    2.753270] xe 0000:00:10.0: [drm] VRAM[0, 0]: Actual physical size 0x0000000100000000,
               usable size exclude stolen 0x00000000fd000000,
               CPU accessible size 0x0000000010000000
```

The BAR (Base Address Register) is the CPU's window into GPU VRAM. The card wants 4GB and got 256MB.
The GPU can still address all its memory. Only CPU access is constrained.

---

## 4. BAR won't grow

The card advertises the capability:

```console
# on the Proxmox host
$ lspci -vv -s 86:00.0 | grep -iE -A8 'resizable|region 0|region 2'
        Region 0: Memory at fa000000 (64-bit, non-prefetchable) [size=16M]
        Region 2: Memory at e0000000 (64-bit, prefetchable) [size=256M]
        Capabilities: [420 v1] Physical Resizable BAR
                BAR 2: current size: 256MB, supported: 256MB 512MB 1GB 2GB 4GB
```

Linux can resize BARs at runtime through sysfs, so this looked testable without a
reboot:

```console
# host, VM stopped so the device is free
$ qm shutdown 100
$ echo 0000:86:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
$ echo 12 > /sys/bus/pci/devices/0000:86:00.0/resource2_resize      # 4GB
-bash: echo: write error: No space left on device
```

The value is log2 of the size in MB, so 12 is 4096MB and 8 is the current
256MB.

`ENOSPC`, not `ENOTSUPP`. The mechanism works, there's just nowhere to put it.

`pci=realloc` on the host kernel command line is the documented fix for that. It
changed nothing, at any size:

```console
$ cat /proc/cmdline
BOOT_IMAGE=/boot/vmlinuz-6.2.16-3-pve root=/dev/mapper/pve-root ro quiet intel_iommu=on pci=realloc

# with the VM stopped, i915 had claimed the card, so unbind from that instead
$ echo 0000:86:00.0 > /sys/bus/pci/drivers/i915/unbind
$ echo 12 > /sys/bus/pci/devices/0000:86:00.0/resource2_resize   # 4GB
-bash: echo: write error: No space left on device
$ echo 11 > ...                                                  # 2GB   same
$ echo 10 > ...                                                  # 1GB   same
$ echo  9 > ...                                                  # 512M  same
```

The bridge chain explains why:

```console
$ for b in 80:03.0 84:00.0 85:01.0; do
    echo "=== $b"; lspci -vv -s $b | grep -iE 'memory behind bridge'
  done
=== 80:03.0                                          # CPU2 root port
        Prefetchable memory behind bridge: e0000000-f07fffff [size=264M] [32-bit]
=== 84:00.0                                          # the card's own switch
        Prefetchable memory behind bridge: e0000000-efffffff [size=256M] [32-bit]
=== 85:01.0
        Prefetchable memory behind bridge: e0000000-efffffff [size=256M] [32-bit]
```

A 32-bit prefetchable window can't address anything above 4GB. The host had
terabytes of PCI space up there:

```console
$ cat /proc/iomem | grep -iE 'PCI Bus' | tail
c8000000-fbffbfff : PCI Bus 0000:80
  e0000000-f07fffff : PCI Bus 0000:84
    e0000000-efffffff : PCI Bus 0000:85
      e0000000-efffffff : PCI Bus 0000:86      # the card, exactly 256MB
38000000000-3bfffffffff : PCI Bus 0000:00      # ~3.8TB, above 4G
3c000000000-3ffffffffff : PCI Bus 0000:80
```

The bridges leading to the card couldn't reach any of it. Firmware enabled
above-4G decoding globally while still programming root ports with small 32-bit
apertures.

This sits below the hypervisor, so a bare-metal install faces identical firmware
allocation. Migrating off the hypervisor had been under consideration partly for
this GPU. It would not have helped.

The BIOS state got inferred from indirect evidence twice here, landing on
opposite conclusions and neither correct. Guest BAR addresses are QEMU's
synthetic address space and say nothing about host firmware.

The Cisco UCS servers don't support Resizable BAR (ReBAR is basically a PCIe feature
that allows the CPU to access the GPU's entire vram at once, instead of in 256MB
chunks) until at least the M6 generation, definitely not on my M4.

---

## 5. Software bug

At this point the conclusion is nearing "2015 server can't run this 2022 GPU." That
conclusion is wrong, and stopping there would have meant buying hardware to solve
a software problem.

Why do I actually need a resizable BAR? The GPU addresses its own memory directly
through its memory controller. The BAR isn't involved in that at all. It exists so the
host CPU can reach VRAM over PCIe, and that's the part limited to a 256MB window.
It should still be usable with a less efficient small BAR.

The kernel handles small BAR correctly. It reports the condition, exposes
`CPU accessible size`, and initialises. It also provides a query so userspace can
allocate inside the visible window. Intel's media driver wasn't calling it: it
allocated its state heap in VRAM and `memset` it without checking, so on a 256MB
BAR the write landed outside the mapping and faulted.

- [intel/media-driver#1927](https://github.com/intel/media-driver/issues/1927) is the crash. Open since May 2025, no maintainer response.
- [intel/media-driver#1990](https://github.com/intel/media-driver/pull/1990) is the fix, merged 2026-07-15.

The fix compares `cpu_visible_size` against `total_size`, sets
`DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM` on allocations, and falls back to
system memory. It names DG2 explicitly.

Worth correcting a widely repeated claim: "Arc requires Resizable BAR" is not
Intel's stated position. Their documentation says it isn't required, and
[IGCIT#315](https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/315)
is a user complaining that the drivers behave as though it is. It's a de facto
software limitation, not a hardware requirement.

---

## 6. Fix not packaged

| Source | Version | Has fix |
|---|---|---|
| Debian trixie | 25.2.3 | No |
| Debian forky/sid | 26.1.6 | No |
| Upstream tag 26.2.4 | published 2026-07-30 | No |
| Upstream tag 26.3.1 | | Yes |

`26.2.4` was published two weeks after the fix merged, but its branch was cut 2026-06-29, before it.

The solution was to build `intel-media-26.3.1` in a container, extract the `.so`,
and point Jellyfin at it with `LIBVA_DRIVERS_PATH`. That avoids a custom Jellyfin
image, so Jellyfin updates don't clobber it.

Four things went wrong in that build, none obvious:

1. **CMake 4.x** (Debian sid) dropped support for `cmake_minimum_required(VERSION <3.5)`, which media-driver's vendored `cmrtlib` still declares. Needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.
2. **gmmlib must be installed, not just checked out beside it.** media-driver finds it via `pkg_check_modules(igdgmm)`, which reads a `.pc` file.
3. **`libigdgmm.so` has to ship with the driver.** The driver links against it at runtime, which is why `LD_LIBRARY_PATH` is set alongside `LIBVA_DRIVERS_PATH`.
4. **`CMAKE_BUILD_TYPE` must be set explicitly.** media-driver prints `BUILD_TYPE not defined, default to: release` about its own variable, not CMake's. Without it you get an unoptimised 576MB `.so` instead of ~40MB.

---

## Status

Hardware fine. Kernel fine. Firmware limitation real but survivable. Blocked on a
driver version that's buildable today.

Cost: one guest distro upgrade that was worth doing anyway, a driver selection
config, and a container build.

Not needed: a new GPU, a new server, or migrating off the hypervisor. The
investigation ruled that last one out as a fix, having started partly as an
argument for it.
