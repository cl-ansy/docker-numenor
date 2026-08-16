# Diagnosing playback latency

Scope: Jellyfin slow to start playback. Companion: [access.md](access.md).

## What GPU transcoding does and does not fix

Hardware encode improves throughput (frames per second) and concurrent stream
count. It has almost no effect on time to first frame. A 15 second start delay
will still be roughly 15 seconds with a GPU.

| Symptom | GPU helps |
|---|---|
| Slow to start, then plays fine | No |
| Buffers or stutters mid-playback | Yes |
| Second concurrent stream degrades both | Yes |
| 4K HEVC unwatchable, 1080p fine | Yes |
| Whole library slow to browse | No, that is metadata I/O |

Diagnose before buying or configuring anything.

## Order of checks

Stop at the first one that explains the delay.

### 1. Is it transcoding at all

Play the file, then open Jellyfin **Dashboard > Playback** while it runs. It
reports "Direct playing" or "Transcoding" plus the reason.

Direct play means no transcode is happening and the GPU question is settled. Skip
to check 2.

### 2. NAS cold start

Play a file and note the delay. Immediately play a **different** file in the same
folder.

Second file much faster means drive spin-up. Check the ReadyNAS for disk standby
and power management, and disable them.

Spinning drives take 5 to 15 seconds to come out of standby. This is the most
common cause of the symptom "slow the first time, fine afterwards".

### 3. NFS read latency

From the Docker VM:

```bash
F="$SHAREDDIR/media/Movies/<file>"
time head -c 100M "$F" > /dev/null      # sequential read from the start
time tail -c 10M  "$F" > /dev/null      # seek to end
```

`tail` much slower than `head` points at container index placement: MP4 with a
trailing moov atom, or MKV with cues at the end. Jellyfin must reach the end of a
multi-gigabyte file before it can start.

Also confirm the mount options:

```bash
mount | grep nfs
```

Look for `rsize`/`wsize` (want 1048576 on NFSv4), `hard`, and the protocol
version. Small `rsize` values throttle sequential reads badly.

### 4. Media analysis

Jellyfin probes each file before playback. Time the same call it makes:

```bash
time sudo docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffprobe \
  -v quiet -print_format json -show_format -show_streams \
  "/data/media/Movies/<file>"
```

Several seconds here means the delay is storage, not compute. Compare against a
file already in cache to separate probe cost from read cost.

### 5. Subtitle burn-in

Image-based subtitles (PGS, VOBSUB) cannot be passed through. Enabling them forces
a full video transcode and adds startup cost even when the video would otherwise
direct play.

Check the subtitle track in use during playback. Test the same file with subtitles
off.

### 6. Transcode scratch location

If it is transcoding, the temp directory matters. Jellyfin writes HLS segments
before playback begins, and writing those to NFS adds latency to every start.

Set Dashboard > Playback > Transcode path to a local disk rather than anything
under `$SHAREDDIR` or `$DOWNLOADSDIR`.

### 7. Jellyfin logs

```bash
dclogs jellyfin
```

The ffmpeg command line and the timestamps around playback start are logged. The
gap between the request and the first segment written is the number to measure.

## Fixes by cause

| Cause | Fix |
|---|---|
| Drive spin-up | Disable disk standby on the ReadyNAS |
| Trailing index in container | Remux affected files so the index is at the front |
| Small NFS `rsize`/`wsize` | Set `rsize=1048576,wsize=1048576` in `/etc/fstab` |
| 1GbE saturated | 10GbE on the VIC, or LACP to the NAS. See below |
| Transcode scratch on NFS | Point the transcode path at local disk |
| Subtitle burn-in | Prefer text subtitle tracks where available |
| Sustained transcode too slow | Hardware encode, i.e. the Arc card |

## Network capacity

1GbE caps around 110 MB/s, which a single high-bitrate remux can approach. Confirm
the link speed before assuming storage is the problem:

```bash
ip -br link
ethtool <iface> | grep -i speed
```

The C240 M4 often carries a Cisco VIC (1225/1227/1385) capable of 10GbE alongside
the onboard i350 1GbE. Running on the i350 while a 10GbE adapter sits idle is
worth ruling out.

## Metadata and browsing

Slow library browsing is a different problem from slow playback start. Jellyfin's
database lives in `$DOCKERDIR/appdata/jellyfin`. If browsing is slow but playback
starts promptly, look at that storage, not at the NAS or the GPU.
