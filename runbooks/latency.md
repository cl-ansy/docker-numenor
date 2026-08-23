# Playback latency

Jellyfin slow to start playback. See also [access.md](access.md), [gpu.md](gpu.md).

## Check before assuming it's the GPU

Hardware encode improves frames per second and how many streams run at once. It
barely affects time to first frame. A 15 second start delay stays about 15
seconds with a GPU.

| Symptom | GPU helps |
|---|---|
| Slow to start, then plays fine | No |
| Buffers or stutters mid-playback | Yes |
| Second stream degrades both | Yes |
| 4K HEVC unwatchable, 1080p fine | Yes |
| Whole library slow to browse | No, that's metadata I/O |

## Checks in order

Stop at the first one that explains the delay.

### 1. Is it transcoding at all

Play the file, then open Jellyfin **Dashboard > Playback** while it runs. It says
"Direct playing" or "Transcoding" and why.

Direct play means no transcode, so the GPU is irrelevant. Go to check 2.

### 2. NAS cold start

Play a file and note the delay. Immediately play a different file in the same
folder.

If the second is much faster, drives were spun down. Disable disk standby and
power management on the NAS.

Spinning drives take 5 to 15 seconds to spin up. This is the usual cause of "slow
the first time, fine afterwards".

### 3. NFS read latency

From the Docker VM:

```bash
F="$SHAREDDIR/media/Movies/<file>"
time head -c 100M "$F" > /dev/null      # sequential read from the start
time tail -c 10M  "$F" > /dev/null      # seek to end
```

If `tail` is much slower than `head`, the container's index sits at the end of
the file. That happens with an MP4 carrying a trailing moov atom, or an MKV with
cues at the end. Jellyfin has to reach the end of a multi-gigabyte file before it
can start.

Check the mount options too:

```bash
mount | grep nfs
```

Want `rsize`/`wsize` at 1048576 on NFSv4, and `hard`. Small `rsize` throttles
sequential reads.

### 4. Media analysis

Jellyfin probes each file before playback. Time the same call:

```bash
time sudo docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffprobe \
  -v quiet -print_format json -show_format -show_streams \
  "/data/media/Movies/<file>"
```

Several seconds means storage, not compute. Compare against a file already in
cache to separate probe cost from read cost.

### 5. Subtitle burn-in

Image-based subtitles (PGS, VOBSUB) can't be passed through. Turning them on
forces a full video transcode, adding startup cost even when the video would
otherwise direct play.

Check which subtitle track is in use, then test the same file with subtitles off.

### 6. Transcode scratch location

If it is transcoding, Jellyfin writes HLS segments before playback starts.
Writing those to NFS adds latency every time.

Set Dashboard > Playback > Transcode path to local disk, not anything under
`$SHAREDDIR` or `$DOWNLOADSDIR`.

### 7. Jellyfin logs

```bash
dclogs jellyfin
```

The ffmpeg command line and playback timestamps are logged. Measure the gap
between the request and the first segment written.

## Fixes

| Cause | Fix |
|---|---|
| Drive spin-up | Disable disk standby on the NAS |
| Trailing index in container | Remux so the index is at the front |
| Small NFS `rsize`/`wsize` | `rsize=1048576,wsize=1048576` in `/etc/fstab` |
| 1GbE saturated | 10GbE on the VIC, or LACP to the NAS |
| Transcode scratch on NFS | Point the transcode path at local disk |
| Subtitle burn-in | Use text subtitle tracks where available |
| Sustained transcode too slow | Hardware encode - see [gpu.md](gpu.md) |

## Network capacity

1GbE caps around 110 MB/s, which a single high-bitrate remux can approach. Check
the link speed before blaming storage:

```bash
ip -br link
ethtool <iface> | grep -i speed
```

The C240 M4 often has a Cisco VIC (1225/1227/1385) capable of 10GbE alongside the
onboard i350 1GbE. Check you aren't on the i350 with a 10GbE adapter sitting idle.

## Slow browsing is a different problem

Jellyfin's database lives in `$DOCKERDIR/appdata/jellyfin`. If browsing is slow
but playback starts promptly, look at that storage rather than the NAS or the GPU.
