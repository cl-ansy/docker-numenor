# An Arc A310 that wouldn't transcode

A debugging session where every layer looked like the answer and wasn't. The
wrong turns are more useful than the fix, so they're kept here.

**Hardware:** Cisco UCS C240 M4 (dual Xeon E5-2680 v3, Haswell-EP, 2015-era),
Proxmox host, Debian guest running a Docker media stack, Intel Arc A310 passed
through to the guest for Jellyfin hardware transcoding.

**Symptom:** the card had never worked. An earlier attempt had been abandoned.

---

## Layer 1: the card isn't there

Passthrough was configured, with `hostpci0` and `hostpci1` on the VM, but the
guest saw nothing usable:

```
$ ls -l /dev/dri
card0                    # and nothing else
```

Common advice for GPU passthrough says you need OVMF (UEFI) and the q35 machine
type. This VM ran SeaBIOS and i440fx, so that looked like the answer.

It wasn't. `lspci` in the guest showed the card enumerated fine:

```
00:10.0 VGA compatible controller: Intel Corporation DG2 [Arc A310] [8086:56a6]
00:11.0 Audio device: Intel Corporation DG2 Audio Controller [8086:4f92]
```

Passthrough was working. Rebuilding the VM's boot configuration would have been
days of work for nothing.

The folklore fix and the actual fix are often unrelated. Check what the guest
actually sees before restructuring anything.

*(Two PCI devices for one card because Arc puts its HDMI audio controller behind
the card's own internal PCIe switch, on a separate bus. NVIDIA and AMD use
function `.1` on the same device.)*

---

## Layer 2: the driver won't bind

`dmesg` had the real message:

```
i915 0000:00:10.0: Your graphics device 56a6 is not properly supported by i915
in this kernel version. To force driver probe anyway, use i915.force_probe=56a6
```

The guest was Debian 12 on kernel 6.1, and DG2/Alchemist support landed later.
Upgrading to Debian 13 / kernel 6.12 produced a new error:

```
i915: [drm] *ERROR* gt: timed out waiting for forcewake ack request
i915: [drm] *ERROR* GT0: intel_pcode_init failed -110
i915: probe with driver i915 failed with error -110
      use xe.force_probe='56a6' and i915.force_probe='!56a6'
```

The kernel printed its own fix. `xe` is the correct driver for Alchemist; i915's
DG2 support is the legacy path. Selected via `/etc/modprobe.d/xe.conf`:

```
options i915 force_probe=!56a6
options xe force_probe=56a6
```

Then it bound cleanly, with GuC and DMC firmware loaded and a render node:

```
xe: [drm] Using GuC firmware from i915/dg2_guc_70.bin version 70.36.0
[drm] Initialized xe 1.1.0 for 0000:00:10.0 on minor 1
$ ls /dev/dri
card0  card1  renderD128
```

Kernels often tell you exactly what to do. The 193-second `intel_pcode_init`
timeout also explained why boots had become slow, a symptom that had looked
unrelated.

---

## Layer 3: userspace crashes anyway

```
$ vainfo --display drm --device /dev/dri/renderD128
libva info: Trying to open .../iHD_drv_video.so
libva info: Found init function __vaDriverInit_1_23
Bus error          # exit 135, SIGBUS
```

The driver loads, then dies. Debian's `intel-media-va-driver` and Jellyfin's
bundled build failed identically, and the kernel logged nothing. The fault was
entirely in userspace.

The cause had been scrolling past in the `xe` init messages all along:

```
xe: [drm] Failed to resize BAR2 to 4096M (-ENOTSUPP)
xe: [drm] Small BAR device
xe: VRAM[0,0]: Actual physical size 4GB, CPU accessible size 256MB
```

The BAR is the CPU's window into GPU VRAM. The card wants 4GB and got 256MB. The
GPU can still address all its memory. Only CPU access is constrained.

---

## Layer 4: why the BAR can't grow

The card advertises the capability:

```
Capabilities: [420 v1] Physical Resizable BAR
        BAR 2: current size: 256MB, supported: 256MB 512MB 1GB 2GB 4GB
```

Linux can resize BARs at runtime through sysfs, so this looked testable without a
reboot:

```bash
echo 0000:86:00.0 > /sys/bus/pci/drivers/vfio-pci/unbind
echo 12 > /sys/bus/pci/devices/0000:86:00.0/resource2_resize   # 4GB
# write error: No space left on device
```

`ENOSPC`, not `ENOTSUPP`. The mechanism works, there's just nowhere to put it.

`pci=realloc` on the host kernel command line is the documented fix for that. It
changed nothing, at any size, down to 512MB.

The bridge chain explains why:

```
80:03.0  CPU2 Root Port    Prefetchable memory behind bridge: [32-bit]
  84:00.0 (card's switch)  Prefetchable memory behind bridge: [32-bit]
    85:01.0                Prefetchable memory behind bridge: [32-bit]
```

A 32-bit prefetchable window can't address anything above 4GB. The host had
terabytes of PCI space up there; `/proc/iomem` showed ranges at `0x38000000000`.
The bridges leading to the card couldn't reach any of it. Firmware enabled
above-4G decoding globally while still programming root ports with small 32-bit
apertures, because it doesn't anticipate resizable BARs.

This sits below the hypervisor, so a bare-metal install faces identical firmware
allocation. Migrating off the hypervisor had been under consideration partly for
this GPU. It would not have helped.

The BIOS state got inferred from indirect evidence twice here, landing on
opposite conclusions and neither correct. Guest BAR addresses are QEMU's
synthetic address space and say nothing about host firmware. Read the setting
rather than reasoning about it.

---

## Layer 5: it's a software bug, and it's already fixed

At this point the obvious conclusion is "2015 server can't run a 2022 GPU." That
conclusion is wrong, and stopping there would have meant buying hardware to solve
a software problem.

The kernel handles small BAR correctly. It reports the condition, exposes
`CPU accessible size`, and initialises. It also provides a query so userspace can
allocate inside the visible window. Intel's media driver wasn't calling it: it
allocated its state heap in VRAM and `memset` it without checking, so on a 256MB
BAR the write landed outside the mapping and faulted.

- [intel/media-driver#1927](https://github.com/intel/media-driver/issues/1927) - the crash, open since May 2025, no maintainer response
- [intel/media-driver#1990](https://github.com/intel/media-driver/pull/1990) - the fix, merged 2026-07-15

The fix compares `cpu_visible_size` against `total_size`, sets
`DRM_XE_GEM_CREATE_FLAG_NEEDS_VISIBLE_VRAM` on allocations, and falls back to
system memory. It names DG2 explicitly.

Worth correcting a widely repeated claim: "Arc requires Resizable BAR" is not
Intel's stated position. Their documentation says it isn't required, and
[IGCIT#315](https://github.com/IGCIT/Intel-GPU-Community-Issue-Tracker-IGCIT/issues/315)
is a user complaining that the drivers behave as though it is. It's a de facto
software limitation, not a hardware requirement.

---

## Layer 6: nothing packaged has the fix

| Source | Version | Has fix |
|---|---|---|
| Debian trixie | 25.2.3 | No |
| Debian forky/sid | 26.1.6 | No |
| Upstream tag 26.2.4 | published 2026-07-30 | No |
| Upstream tag 26.3.1 | | Yes |

That third row is the trap. `26.2.4` was published two weeks after the fix
merged, but its branch was cut 2026-06-29, before it. Release dates aren't commit
cutoffs.

The solution was to build `intel-media-26.3.1` in a container, extract the `.so`,
and point Jellyfin at it with `LIBVA_DRIVERS_PATH`. That avoids a custom Jellyfin
image, so Jellyfin updates don't clobber it.

Four things went wrong in that build, none obvious:

1. **CMake 4.x** (Debian sid) dropped support for `cmake_minimum_required(VERSION <3.5)`, which media-driver's vendored `cmrtlib` still declares. Needs `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`.
2. **gmmlib must be installed, not just checked out beside it.** media-driver finds it via `pkg_check_modules(igdgmm)`, which reads a `.pc` file.
3. **`libigdgmm.so` has to ship with the driver.** The driver links against it at runtime, which is why `LD_LIBRARY_PATH` is set alongside `LIBVA_DRIVERS_PATH`.
4. **`CMAKE_BUILD_TYPE` must be set explicitly.** media-driver prints `BUILD_TYPE not defined, default to: release` about its own variable, not CMake's. Without it you get an unoptimised 576MB `.so` instead of ~40MB.

---

## The pattern that showed up three times

Three unrelated problems the same day, all the same shape: a component reporting
success while the layer beneath silently discarded the work.

**Redis** answered `PING` while refusing every write with `MISCONF`. The
healthcheck passed, Docker reported it healthy, and dependents started. It had
been doing that for three weeks. The Celery worker couldn't acknowledge tasks, so
they were redelivered hourly and re-executed indefinitely.

**`fstrim`** reported `309.2 GiB trimmed`. The thin pool didn't move. Without
`discard=on` in the hypervisor, the guest device still advertises TRIM support,
accepts the commands, and drops them. Enabling discard reclaimed ~380GB.

**docker-gc's cron** was installed and correctly formatted, and had never fired -
the image didn't accept the six-field expression it was configured with. It had
been armed to delete volumes for a year without running once.

In all three the check and the effect were never connected. Verify at the layer
where the outcome lands, not the layer that reports on it: check the pool rather
than `fstrim`'s output, and make the healthcheck perform a write rather than a
ping.

---

## Where it ended

Hardware fine. Kernel fine. Firmware limitation real but survivable. Blocked on a
driver version that's buildable today.

Cost: one guest distro upgrade that was worth doing anyway, a driver selection
config, and a container build.

Not needed: a new GPU, a new server, or migrating off the hypervisor. The
investigation ruled that last one out as a fix, having started partly as an
argument for it.
