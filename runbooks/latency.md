# Playback latency

Jellyfin slow to start playback. See also [access.md](access.md), [gpu.md](gpu.md).

The numbered checks below assume a file on the NAS. Live TV never touches that
path, so skip to [Live TV is a different path](#live-tv-is-a-different-path).

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

## Live TV is a different path

No NAS read, no spin-up, no file probe. Checks 1 to 7 don't apply. The delay is
the tuner locking, the broadcast standard, or a transcode.

### ATSC 1.0 vs 3.0

An ATSC 3.0 tuner receives both. Stations broadcast the two side by side during
the transition, so the same callsign often appears twice in the lineup.

| | ATSC 1.0 | ATSC 3.0 |
|---|---|---|
| Video | MPEG-2 | HEVC |
| Audio | AC-3 | AC-4 |
| Modulation | 8VSB | OFDM |
| Delivery | Continuous transport stream | IP, segmented as DASH over ROUTE |
| Typical tune-in | ~2s | 3s to 18s |

3.0 is slower to tune because it is segmented. The tuner waits for a segment
boundary and the first I-frame of a group of pictures before it can emit
anything. That floor belongs to the standard and no change here removes it.

A market's 3.0 channels usually share one RF channel, so they arrive as a group.

### Which channels are which

The lineup gives no ATSC version field, so probe the codecs instead. MPEG-2 plus
AC-3 is 1.0, HEVC plus AC-4 is 3.0:

```bash
curl -s "http://<tuner>/lineup.json" \
  | jq -r '.[] | "\(.GuideNumber)\t\(.GuideName)\t\(.URL)"' \
  | while IFS=$'\t' read -r num name url; do
      codecs=$(sudo docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffprobe \
        -v error -analyzeduration 3M -probesize 5M \
        -show_entries stream=codec_type,codec_name -of csv=p=0 "$url" 2>/dev/null \
        | paste -sd' ')
      printf '%-8s %-24s %s\n' "$num" "$name" "${codecs:-probe failed}"
    done
```

Each probe occupies a tuner and takes a few seconds, so this runs as long as the
lineup is big. Stop it once the pattern is obvious.

### AC-4 audio has no decoder

ffmpeg cannot decode AC-4, including the jellyfin-ffmpeg build
([jellyfin-ffmpeg#311](https://github.com/jellyfin/jellyfin-ffmpeg/issues/311),
[jellyfin#9307](https://github.com/jellyfin/jellyfin/issues/9307), open as of
2026-08). A 3.0 channel carrying AC-4 therefore cannot be transcoded. It plays
only where the client decodes AC-4 directly, and otherwise fails or runs silent.

This is worth establishing before chasing a timing problem. Silent or failing 3.0
channels are this, not the tuner.

### Checks in order

Stop at the first one that explains the delay.

**1. Time the tuner alone.** `time_starttransfer` is time to first byte, which is
the lock. Compare a 3.0 channel against a 1.0 one on the same tuner:

```bash
curl -s -o /dev/null -w '%{time_starttransfer}\n' --max-time 30 "http://<tuner>/auto/v<atsc3-channel>"
curl -s -o /dev/null -w '%{time_starttransfer}\n' --max-time 30 "http://<tuner>/auto/v<atsc1-channel>"
```

Slow on 3.0 and fast on 1.0 is the standard, and you are done. Both fast means
the delay is entirely Jellyfin's.

**2. Is it transcoding.** Play the channel, then open Dashboard > Playback. HEVC
into a client that wants H.264 is a full CPU transcode, and Jellyfin writes HLS
segments before the client sees a frame. Switching that client to one that takes
HEVC removes more startup delay than anything else available.

**3. Signal quality.** A marginal signal makes the tuner retry rather than fail.
`status.json` reports only tuners currently in use, so read it while the slow
channel is playing:

```bash
curl -s "http://<tuner>/status.json" | jq
```

Want `SignalStrengthPercent` above 75, with `SignalQualityPercent` and
`SymbolQualityPercent` at or near 100. Low symbol quality alongside high signal
strength is interference rather than a weak signal.

**4. Transcode scratch location.** Same as check 6 above, and it costs more here
because Live TV transcodes continuously rather than once.

### The GPU won't fix this

Same reasoning as at the top of this file. Hardware encode changes sustained
throughput and concurrent stream count, not time to first frame. Finishing
[gpu.md](gpu.md) will fix stutter on 4K HEVC. It will not make channels start
faster, and it does nothing for AC-4.

## Slow browsing is a different problem

Jellyfin's database lives in `$DOCKERDIR/appdata/jellyfin`. If browsing is slow
but playback starts promptly, look at that storage rather than the NAS or the GPU.
