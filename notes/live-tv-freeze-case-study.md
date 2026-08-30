# A Live TV stream that freezes and never comes back

A debugging session covering two different failure modes that both present as
"the picture froze." One is transient and self-heals. The other doesn't, and
turned out to be a known, unfixed upstream bug. The wrong turns are kept here
because they're the reusable part.

**Setup:** Jellyfin Live TV over an HDHomeRun tuner, `t3_proxy` network,
software transcoding only (hardware transcode not yet wired up, see
[gpu.md](../runbooks/gpu.md)). Symptom reported from two different clients: the
web player (Firefox) and an Android TV client.

---

## 1. It looked like a CPU problem

`docker stats` caught the Jellyfin container at 166% CPU during a single Live
TV transcode. Suspicious on its own, but `vmstat 1` during a live reproduction
showed:

```
procs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----
 r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st
 0  0 379692 4488772 423500 6074264   0    0     0    92 9133 14729  8  2 90  0  0
```

`st` (steal) is 0 throughout, `id` stays 88-99%. No CPU steal from the
hypervisor, no local exhaustion. 166% of one container is not 100% of 16
vCPUs. Ruled out.

## 2. It looked like the GPU

It wasn't wired in at all, which was easy to confirm three ways at once: the
Dashboard's Playback > Transcoding page said `Hardware acceleration: None`,
the actual `ffmpeg` command line in the logs had no `-hwaccel`/`vaapi`/`qsv`
flags, and `compose/jellyfin.yml` doesn't mount `/dev/dri` or set
`LIBVA_DRIVERS_PATH`. Structurally unreachable from the container. Ruled out.

## 3. Corrupted video, that fixed itself (channel A)

First reproduction: playback started, froze after 1-2 seconds, then
recovered on its own after several minutes. The per-job ffmpeg log
(`/config/log/FFmpeg.Transcode-*.log` — named after the LiveTV `native_...`
stream ID, not the HLS output ID used in the segment filenames, which cost a
few wrong greps) showed the decoder choking on the input itself:

```
[mpeg2video @ 0x...] Invalid mb type in P-frame at 62 23
[mpeg2video @ 0x...] invalid cbp 0 at 87 19
[mpeg2video @ 0x...] concealing 551 DC, 551 AC, 551 MV errors in P frame
[dec:mpeg2video @ 0x...] Error submitting packet to decoder: Invalid data found when processing input
[dec:ac3 @ 0x...] Error submitting packet to decoder: Error number -16976906 occurred
```

Both the video and audio decoders failing on the same feed at the same time
points at bad bytes in the transport stream, not a decoder bug. The tuner's
own signal metrics, checked live against `<tuner>/status.json`, were clean —
strength 79%, quality 92%, symbol quality 100%, all comfortably above the
"marginal signal" threshold. That rules out a weak over-the-air signal, but
not corruption introduced between the tuner and Jellyfin (network path, or
Jellyfin's own re-serving). That differential test — capturing straight from
the tuner with `curl` and `ffprobe`-ing it, bypassing Jellyfin's
`LiveStreamFiles` proxy entirely — was never actually run. This one is
unresolved, not fixed; it just happened to recover before anyone needed an
answer.

## 4. A permanent freeze, on a different channel

Second reproduction, a different channel (channel B) on the Android TV
client: video froze solid, ffmpeg had vanished (`ps aux | grep ffmpeg` in the
container: nothing), and it never recovered on its own — over an hour later,
still frozen.

Finding the crash log took a couple of wrong turns worth naming:

- Grepping for the HLS output ID (the one in the `.m3u8`/`.ts` filenames)
  found nothing. Live TV generates *three* different IDs per session — the
  transcode/HLS output ID, the `LiveStreamFiles` proxy ID, and the
  `native_...` device-profile ID the crash log is actually named after — and
  they only cross-reference through the full `ffmpeg` command line in the
  main log.
- `docker exec jellyfin ls /cache/transcodes/*.m3u8` came back "No such file
  or directory" even though the file existed. The glob was expanding on the
  host shell (where the path doesn't exist) before `docker exec` ever ran,
  passing a literal, unmatched `*` into the container. Needs
  `docker exec jellyfin sh -c 'ls ... *.m3u8'` so the glob expands inside the
  container.

The actual crash log, once found, showed something completely different from
case 3 — no video corruption at all:

```
[aost#0:1/copy @ 0x...] Non-monotonic DTS; previous: 9139361898, current: 3152715604; changing to 9139361899.
[aost#0:1/copy @ 0x...] Non-monotonic DTS; previous: 9139361899, current: 3152718484; changing to 9139361900.
...
frame=377324 fps=60 q=28.0 size=N/A time=01:44:52.53 bitrate=N/A dup=58226 drop=58016 speed=1x
```

Repeated for the entire ~104-minute session. `previous` and `current` differ
by about 5.99 billion ticks at the stream's 90kHz timebase — roughly 18.5
hours. ffmpeg was patching the audio timestamp by exactly 1 tick per frame,
every frame, for the whole session, rather than resolving the discontinuity.
16% of frames duplicated, 16% dropped, just to keep something monotonic
against a broken clock. Then the log just stops — no fatal error, no
"Conversion failed," nothing.

## 5. Ruling out the obvious silent-death causes

A process vanishing with zero log trace has a short list of usual suspects,
checked in order:

```
$ sudo dmesg -T | grep -i -e kill -e oom -e "out of memory"
(nothing near the crash time)

$ sudo dmesg -T | grep -i segfault
(nothing)

$ docker inspect jellyfin --format 'StartedAt={{.State.StartedAt}} RestartCount={{.RestartCount}}'
StartedAt=2026-08-28T15:22:24Z RestartCount=0
```

No OOM kill, no kernel-visible segfault, no container/Jellyfin restart. Three
of the most likely mechanisms, all ruled out, which is most of why this
writeup exists instead of a one-line fix.

## 6. The tell: comparing it to a session that closed cleanly

Earlier the same evening, the same channel had been opened and closed within
47 seconds — a normal client disconnect. That one logged the full, expected
teardown:

```
Live stream "native_..." consumer count is now 0
Closing live stream "..."
Live stream "..." closed successfully
```

The session that froze for an hour logged **none of that**. Same log level,
same code, same channel — just never entered on the second attempt. That
rules out both an ordinary client disconnect and a log-level filtering
explanation. Whatever killed `ffmpeg` bypassed Jellyfin's normal
stream-closing path entirely, which is consistent with something like
`SIGKILL` (a process can't log its own death from that) or an internal abort
that exited without printing.

Because Jellyfin's own session tracking never saw this stream end, it never
appended `#EXT-X-ENDLIST` to the still-open HLS playlist, and never told the
client anything. An "event" playlist with no end marker means the player has
no signal the stream is over — it just waits forever for the next segment.
No error, no retry, just a frozen frame.

## 7. This is a known, unfixed upstream bug

[jellyfin/jellyfin#8159](https://github.com/jellyfin/jellyfin/issues/8159),
"Live TV Freeze at break," describes this exact signature: playback freezes
when a channel hits a commercial break, with `non-monotonous DTS` errors in
the log. Filed July 2022 against 10.8.1. Closed as **not planned**, for
insufficient reproduction data.

Best-supported explanation, not a confirmed one: a station's local
ad-insertion splice resets or jumps the multiplex's PTS/DTS clock. Jellyfin's
Live TV audio path uses `-codec:a:0 copy` (no re-encode), which depends on
the source's timestamps staying sane — when they don't, `ffmpeg`'s muxer has
no real discontinuity handling, just the frame-by-frame patch seen above.
Other candidates that produce the same signature and weren't ruled out: an
affiliate switching feeds, an EAS interruption, or an unrelated multiplex
clock reset. Confirming it for certain would mean catching the failure live
and cross-referencing the exact timestamp against that channel's schedule.

---

## What an actual fix would look like

Two separate systems are broken, upstream, neither of them ours to patch
without maintaining a fork:

1. **`ffmpeg`'s HLS muxer** needs to treat a DTS jump past some sane
   threshold as a genuine discontinuity — reset the timestamp baseline and
   continue, instead of patching one tick at a time forever. Lives in
   `libavformat`, not Jellyfin.
2. **Jellyfin needs to detect its own `ffmpeg` child dying**, cleanly or not,
   and close the session: mark it closed in session tracking, and write
   `#EXT-X-ENDLIST` (or push a stop event to the client) so playback ends
   with an error instead of hanging forever. This is the one that actually
   matters — even an imperfect fix for (1) still fails occasionally, but (2)
   is what turns "fails occasionally" into "hangs forever with no
   explanation."

## A cheaper mitigation: stop hitting the vulnerable path

The audio-copy path (`-codec:a:0 copy`) is what exposes ffmpeg's weak
discontinuity handling to begin with — the video re-encode (`libx264`) never
showed this failure in either reproduction, because a fresh encode generates
its own clean timestamps regardless of what the input's clock is doing. Audio
only gets copied through when the client tells Jellyfin it can decode the
source codec (AC3) itself.

On the Android TV client, that's controlled by **Settings → Playback →
Advanced → "Bitstream Dolby Digital audio."** Turning it off stops the client
claiming AC3 support, which pushes Jellyfin onto the audio transcode path
instead of copy. Some users report needing to fully exit and reopen the app
for the change to take effect.

Worth knowing before flipping it:

- **Client-specific.** Firefox already always transcodes audio — browsers
  can't bitstream AC3 at all — so this setting only changes anything on the
  Android TV client.
- **Real audio tradeoff, not just a performance one.** With bitstreaming on,
  the Shield passes the original Dolby Digital 5.1 signal straight to a
  receiver/soundbar for native decode. Off, Jellyfin decodes and re-encodes
  it, and based on the pattern in Firefox's own transcode command (`-ac 2`),
  that likely means a stereo downmix instead of true 5.1, not just a codec
  swap.
- **Mitigation, not a fix.** It reduces exposure to this specific trigger. It
  does nothing for the actual bug — Jellyfin still won't notice if `ffmpeg`
  dies for some other reason, and playback would still hang forever rather
  than error out.

Not applied yet. Current state: bitstreaming is on, left alone until the
freeze is frequent enough to be worth the audio quality tradeoff.

## Status

Not fixed, and not fixable from this repo — both halves live upstream, in
`ffmpeg` and in Jellyfin's own process supervision, and the relevant issue is
already closed as won't-fix for lack of data.

Considered and rejected: switching Live TV clients away from Jellyfin
(TVheadend + Kodi/its own web player genuinely sidesteps this, since it never
touches Jellyfin's HLS pipeline, but the existing tuner + guide-data setup
isn't worth giving up for it). Rebuilding a patched `ffmpeg` or forking
Jellyfin server, the same way the GPU driver got built from source in
[gpu-case-study.md](gpu-case-study.md) — technically possible, disproportionate
maintenance burden for one bug.

Planned mitigation, not yet built: a local watchdog polling
`/cache/transcodes` for a stale, process-less session and closing it out
(append `#EXT-X-ENDLIST`, close the session via the API) so a freeze becomes
a fast, visible error instead of an indefinite hang. Doesn't fix the root
cause. Turns "frozen for an hour, unnoticed" into "errors in ~10 seconds,"
which is the part that actually hurts.
