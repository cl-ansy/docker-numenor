# What to acquire to avoid transcoding

Client-side codec/container support for the clients actually in use: Firefox,
Chrome, and an Nvidia Shield (Android TV). Written up after spending a day
diagnosing Live TV transcode issues that kept tracing back to what a given
client can and can't play natively - see
[live-tv-freeze-case-study.md](live-tv-freeze-case-study.md) for that.

Revisit this once hardware transcode is actually confirmed working (see
[gpu-case-study.md](gpu-case-study.md)) - it makes source codec choice matter
much less, since even a full mismatch becomes a cheap hardware transcode
instead of an expensive software one.

## Video codecs

| Codec | Firefox | Chrome | Shield |
|---|---|---|---|
| H.264/AVC | Direct play | Direct play | Direct play |
| H.265/HEVC | Always transcodes | Conditional - needs a hardware HEVC decoder on Windows/Linux/ChromeOS; generally works on macOS/Android where the OS handles it | Direct play (hw decode, incl. 10-bit/HDR) |
| VP9 | Direct play | Direct play | Direct play |
| AV1 | Direct play | Direct play | Model-dependent - older Shield generations lack AV1 hardware decode |
| MPEG-2 | Always transcodes | Always transcodes | Inconsistent, per the Live TV case study |
| VC-1 | Always transcodes | Always transcodes | Direct play, generally |

Firefox has no HEVC decoder at all, on any platform - not a hardware gap, a
policy one; it was never shipped due to licensing. Chrome's HEVC support is
real but conditional on the OS/GPU actually providing hardware decode - it is
not a flat yes the way H.264 is.

## Audio codecs

| Codec | Firefox | Chrome | Shield |
|---|---|---|---|
| AAC | Direct play | Direct play | Direct play |
| Opus | Direct play | Direct play | Direct play |
| AC3 (Dolby Digital) | Always transcodes | Always transcodes | Passthrough if "Bitstream Dolby Digital audio" is on, else decoded |
| E-AC3 (DD+) | Always transcodes | Always transcodes | Passthrough depends on receiver/HDMI chain |
| DTS / DTS-HD MA | Always transcodes | Always transcodes | Passthrough less consistently supported than AC3 |
| TrueHD / Atmos | Always transcodes | Always transcodes | Passthrough depends heavily on receiver + cabling |
| FLAC | Usually transcodes | Direct play | Direct play |

Neither browser supports AC3 or DTS at all - confirmed for Chrome via its own
issue tracker, still open. Audio codec choice barely matters for CPU load
either way: audio transcoding is cheap regardless of what's being converted,
unlike video.

## Containers

| Container | Firefox | Chrome | Shield |
|---|---|---|---|
| MKV | Cheap remux, not a transcode, if codecs inside are compatible | Same | Native direct play |
| MP4 | Direct play if codecs compatible | Same | Direct play |
| WebM | Direct play | Direct play | Direct play |
| AVI | Usually needs work | Usually needs work | Depends on codec inside |

## Subtitles

| Type | Behavior |
|---|---|
| SRT / text-based (ASS/SSA) | Overlaid by the player, no transcode |
| PGS / VOBSUB (image-based, Blu-ray/DVD) | Forces a full video transcode if burn-in is needed - same category of problem as HEVC on Firefox, just for subtitles instead of video |

## Bottom line

**H.264 video + MKV container** direct-plays on every client above,
regardless of audio track. Avoid PGS/VOBSUB-only releases when a text
subtitle option exists. Audio codec isn't worth optimizing for - it
transcodes cheaply either way.
