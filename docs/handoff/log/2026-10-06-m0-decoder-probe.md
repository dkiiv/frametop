# 2026-10-06/07 — M0: decoder feasibility probe — PASSED

Verdict (2026-10-07 09:36): **M0 PASSED.** With the headset worn and passthrough on, the Frame
hardware-decodes 1080p60 H.264/HEVC (and 4K60 HEVC) at full rate, ~2-4.5 ms per frame,
~4-6% of one core, with 0 compositor drops; frames leave the decoder as DMA-BUFs; converted
once on the GPU (~1-2 ms) to ABGR8888 they display correctly in a SteamVR overlay (Curtis:
"it all looks great"). The one trap: do NOT hand SteamVR NV12 directly (renders green garbage).
Read the sections below in order; the last section is the sign-off.

Done:
- Decode stack identified (all on the SteamOS host; nothing needed installing):
  - SoC: Qualcomm SM8650 (Snapdragon 8 Gen 3), GPU Adreno 750 (Mesa Turnip 26.3-devel,
    GL via Zink). 03-technical-notes guessed "Panfrost/Venus": wrong, it's Qualcomm.
  - Hardware decoder: upstream `qcom-iris` V4L2 **stateful** M2M decoder,
    `/dev/video22` (symlink `/dev/video-dec0`), kernel 6.18. Bitstreams: H264, HEVC, VP9
    (**no AV1**). Capture formats: NV12, NV21, Q08C (UBWC NV12), AB24, QC24. Up to 8192x8192.
    User `steamos` has rw via ACL/video group; works from the `dev` container too.
  - Vulkan video decode: none (Turnip exposes no VK_KHR_video_*). VA-API: none. V4L2 is the path.
  - Host ffmpeg 7.0 has `h264_v4l2m2m`/`hevc_v4l2m2m`; GStreamer 1.24 has `v4l2h264dec`/`v4l2h265dec`.
  - `/dev/video0..21` = camera ISP (msm_vfe, used by SteamVR tracking/passthrough,
    `XRServiceLoopTh`), separate from the iris video block. `/dev/video99` = SteamVR v4l2loopback.
- `remote-display/probe/ftrd-probe` (C++, built in the dev container by `build.sh`):
  feeds an Annex-B stream to iris one access unit at a time, paced like a live stream, holds
  the shown buffer, exports capture buffers with VIDIOC_EXPBUF, optionally imports them into
  SteamVR (`--vr`) and shows them on an overlay (`--show`), samples SteamVR compositor frame
  timing, and reports latency / drops / CPU / thermals.
- Test streams (made on WSL with x264/x265, zerolatency, no B-frames, GOP 600 = Sunshine-like),
  copied to the Frame at `~/.cache/ft-m0/` (NOT in the repo; regenerate with the commands in
  "How to reproduce" below). The `s3..s6` files have a burned-in step label, frame counter,
  a white bar that sweeps the width once per second, and RED/GREEN/BLUE swatches.

Measured (headset in STANDBY — displays off, no passthrough; SteamVR running):

Correctness: hardware NV12 output is **bit-identical** to software decode (framemd5, 300/300
frames) for H.264 1080p, HEVC 1080p and HEVC 2160p.

Throughput, unpaced (host ffmpeg, `-f null`, includes a copy to system memory):

| stream                   | iris v4l2m2m | software (8 cores) |
|--------------------------|-------------:|-------------------:|
| H.264 1080p60 20 Mb/s    | 750 fps      | 649 fps (~0.5 core per 60 fps) |
| H.264 1080p60 50 Mb/s    | 386 fps      | 355 fps            |
| HEVC  1080p60 20 Mb/s    | 591 fps      | 148 fps            |
| HEVC  2160p60 40 Mb/s    | 416 fps      | 193 fps            |

Paced at 60 fps (ftrd-probe, latency = AU queued -> decoded frame dequeued):

| stream / capture fmt     | fps   | drops | median | p99   | max   | probe CPU | SoC busy |
|--------------------------|-------|-------|--------|-------|-------|-----------|----------|
| H.264 1080p 20M / NV12   | 60.03 | 0     | 2.48ms | 3.39  | 7.90  | 1.4% core | 5.6%     |
| H.264 1080p 50M / NV12   | 60.03 | 0     | 3.84   | 4.72  | 10.83 | 4.5%      | 5.7%     |
| HEVC  1080p 20M / NV12   | 60.03 | 0     | 2.75   | 3.37  | 8.55  | 5.5%      | 6.0%     |
| H.264 1080p 20M / Q08C   | 60.03 | 0     | 2.46   | 3.43  | 7.48  | 1.5%      | 5.5%     |
| HEVC  2160p 40M / NV12   | 60.07 | 0     | 4.57   | 5.11  | 22.84 | 2.8%      | 5.2%     |

(idle SoC baseline with SteamVR in standby: ~5-9% busy.) No input stalls, no output gaps
> 1.5 frames, video-block temperature flat (~39-41 C). No reorder delay: with a no-B-frame
stream, frame N comes out ~2.5 ms after AU N goes in.

DMA-BUF: VIDIOC_EXPBUF works on every capture buffer (NV12 1080p: one 3,133,440-byte dmabuf,
stride 1920, coded 1920x1088, visible 1920x1080; UV plane at offset 1920*1088).

SteamVR: `GetDmabufModifiers(VRApplication_Overlay)` accepts, for **both ABGR8888 and NV12**:
`0x0` (LINEAR) and `0x0500000000000001` (DRM_FORMAT_MOD_QCOM_COMPRESSED = UBWC). So the
decoder's NV12 (linear) or Q08C (UBWC) can go to SteamVR as-is: **no colour-conversion pass**.
`ImportDmabuf` returned success for decoder NV12 (linear) and Q08C (UBWC) buffers.
Caveat: import success may be lazy; correct pixels on the overlay are UNCONFIRMED until
Curtis sees step 3/4 of the worn run.

Broke / surprises:
- "AB24" capture is NOT linear RGBA on this driver: bytesused 4,210,688 vs 8,355,840 for real
  1920x1088 RGBA; alpha bytes almost never 255; reported bytesperline 1920 (pixels, not
  bytes). It looks UBWC-compressed. Worn-run step 5 tries it as ABGR8888+UBWC; may be garbage.
  NV12 is the safe path.
- If the app requeues each capture buffer immediately, iris reuses the SAME buffer every
  frame (1 of 8 used). Any display path must hold the on-screen buffer until the next one is
  shown (ftrd-probe `--show` does), or the decoder overwrites what the compositor is reading.
- With the headset in standby, the SteamVR compositor only produces frames in a ~6 s burst
  when a client connects, so compositor stats in standby are meaningless (~575 frames,
  6 drops every run). Only the worn run's compositor numbers count.
- ffmpeg's v4l2m2m wrapper drops timestamps on raw Annex-B input; `framemd5` then silently
  keeps 2 frames unless `-fps_mode passthrough`. (Cost me one false alarm.)

## Worn run — 2026-10-07 09:05, headset ON, passthrough ON (`~/.cache/ft-m0/worn-20261007-090512.txt` on the Frame)

| step | what                      | decode                                   | compositor @90 Hz      | SoC busy |
|------|---------------------------|------------------------------------------|------------------------|----------|
| 1    | idle baseline             | -                                        | 0 dropped, GPU 2.89 ms | 19.6%    |
| 2    | H.264 1080p60 decode only | 60.03 fps, median 2.42 ms, p99 3.33      | 0 dropped              | 17.1%    |
| 3    | panel HEVC 1080p NV12     | 60.03 fps, p99 11.97, 3 gaps (max 43 ms) | **52 dropped**         | 19.3%    |
| 4    | panel H.264 1080p Q08C    | 60.03 fps, median 2.38, p99 2.75         | 0 dropped              | 15.3%    |
| 5    | panel H.264 AB24 as UBWC  | FAILED (see Broke)                       | -                      | -        |
| 6    | panel HEVC 2160p NV12     | 60.02 fps, median 4.39, p99 4.89         | 0 dropped              | 18.0%    |
| 7    | idle recovery             | -                                        | 0 dropped              | 19.1%    |

Decode gate: **passes**. With passthrough on, iris holds 1080p60 and even 4K60 with ~2.5-4.5 ms
per frame, ~2% of one core, and decoding alone costs the compositor nothing (step 2 = step 1).
Step 3's 52 dropped compositor frames are unexplained (first panel of the run? HEVC NV12?);
steps 4 and 6 with panels up had 0.

Curtis's visual report (steps 3, 4, 6): panel appears, right size, frame counter visibly
incrementing, no tearing at the border, passthrough fine — BUT the picture is **green only**
(no red/blue anywhere, swatches included) with heavy "dying GPU" artifacts inside. Same for
linear NV12 and UBWC Q08C. => Handing NV12 dmabufs straight to SteamVR does NOT render
correctly, even though GetDmabufModifiers lists NV12 and ImportDmabuf succeeds. Either SteamVR
samples NV12 without a YCbCr conversion, or the plane layout we pass is wrong (Q08C certainly
needs more than one plane). Step 5 (AB24 as ABGR8888+UBWC): vrcompositor rejected it
(`CreateImageWithFlags: failed to create vulkan image (-1000158000)` =
VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT, "Got a NULL handle back when importing
a DMA-BUF"); ftrd-probe then retried the import every frame, each retry blocking in SteamVR's
shared-fd handshake, so the step hung until killed at 09:12 (probe bug: cache failures).
vrserver/vrcompositor never restarted (same PIDs throughout).

Remote view: `/dev/video99` is SteamVR's virtual webcam (`v4l2cam --output=99`), black when
idle — not a headset mirror. `vrcmd --screenshot` exists; untested.

## Fix: convert on the GPU, hand SteamVR ABGR8888 (2026-10-07 09:20-09:31, headset off)

- `ftrd-probe --rgb`: each decoded NV12 buffer is imported into EGL (GBM platform, GLES2,
  GL_RENDERER "FD750" = freedreno) with `EGL_LINUX_DMA_BUF_EXT`, 2 planes from the one dmabuf
  (UV at stride*1088), BT.601 limited-range hint (`--csc 709` for Sunshine's usual matrix),
  sampled via `samplerExternalOES` into a ring of 3 linear ABGR8888 GBM buffers — the exact
  format every Frametop panel already gives SteamVR. glFinish, then the decoder buffer goes
  straight back to the decoder (no hold needed any more).
- Headless proof: frame 75 read back with glReadPixels vs ffmpeg software decode of the same
  frame: **PSNR 49.98 dB** (r 50.1 / g 47.2 / b 49.4) = identical within rounding; checked
  visually too (colours, text, swatches). So the decoder buffer and our plane layout are
  right; **SteamVR's own NV12 import is what renders green garbage** on this build, even
  though GetDmabufModifiers lists NV12. Don't hand it YUV.
- Cost: convert median 1.2 ms (1080p), 2.0-2.9 ms (4K) per frame incl. glFinish; decode still
  60.03 fps, probe 4.7% of a core. SteamVR ImportDmabuf accepts the converted buffers.
- Probe fixes: a failed import is cached, never retried (the step-5 hang); compositor drops
  are now listed with timestamps (to explain step 3's 52 drops on the next worn run).
- `remote-display/probe/m0-final.sh` (dry-run clean with headset off): idle 20 s, then panels
  A HEVC 1080p / B H.264 1080p / C HEVC 4K, all via --rgb, 30 s each, idle 20 s. Test
  streams `fa_/fb_/fc_*` in `~/.cache/ft-m0/` are labelled "A/B/C ... -> GPU RGB".

## Sign-off run — 2026-10-07 09:33, headset ON, passthrough ON (`~/.cache/ft-m0/final-20261007-093332.txt`)

| step | what                 | decode                           | gaps>1.5f | convert med/p99 | compositor (2826 frames) | SoC busy |
|------|----------------------|----------------------------------|-----------|-----------------|--------------------------|----------|
| 1    | idle                 | -                                | -         | -               | 0 dropped                | 13.0%    |
| A    | HEVC 1080p60 -> RGB  | 60.03 fps, med 1.94 ms, p99 2.90 | 1 (27 ms) | 0.98 / 4.06 ms  | 0 dropped                | 15.1%    |
| B    | H.264 1080p60 -> RGB | 60.03 fps, med 2.41 ms, p99 2.80 | 0         | 1.19 / 3.11 ms  | 0 dropped                | 14.9%    |
| C    | HEVC 4K60 -> RGB     | 60.01 fps, med 4.44 ms, p99 4.97 | 1 (31 ms) | 1.85 / 4.51 ms  | 1 dropped (at 1.5 s, panel appearing) | 15.7% |

Curtis: all three panels look great — correct colours, clean picture, passthrough fine. The
testsrc2 fine checkerboard (bottom right) looked grey/fuzzy: expected — a 1920 px panel 1.2 m
wide puts several panel pixels per display pixel, so ~8 px checker detail averages out. Text
legibility vs panel size/distance is an M2 question. The first worn run's 52 drops in step 3 did
not reproduce; the only drop this time was at panel appearance, so treat it as a show-time
transient (watch for it in M2).

Facts for M2 (decided by M0):
- Path: V4L2 stateful iris decode (NV12, linear, 1920x1088 coded, UV at stride*1088) ->
  EGL dmabuf import (samplerExternalOES, BT.601/709 limited-range hint) -> GLES draw into
  linear ABGR8888 GBM buffers (ring of 3) -> SteamVR ImportDmabuf -> overlay. Code:
  `remote-display/probe/ftrd-probe.cpp` (`--rgb --show`).
- Use H.264 or HEVC (no AV1 on iris). Ask Sunshine for no B-frames; then decode adds ~2.5 ms.
- Sunshine typically sends BT.709 for HD: use `--csc 709` (the test files are 601).
- Budget left: one 1080p60 stream costs ~2% of the SoC beyond idle. The backlog's "second
  display" is clearly possible on decode grounds; 4K60 works too.

Next: M1 — Sunshine on the Windows PC + a stock Moonlight client to prove encoder/network.
Start by asking Curtis: GPU model of the PC, and whether he'll install Sunshine himself or set
up SSH (OpenSSH Server) so the agent can.

Needs: Curtis at the Windows PC for M1.

Next (superseded): Curtis wears the headset with passthrough on; agent runs
`scripts/frame.sh -C remote-display/probe ./m0-worn.sh` and records the RESULT blocks +
Curtis's visual report here, then decides the M0 gate.

Needs: Curtis — wear the headset, passthrough on, ~4 minutes, report what each panel looks like.

How to reproduce:
```
remote-display/probe/build.sh                                  # builds in the dev container
scripts/frame.sh -C remote-display/probe 'build/ftrd-probe ~/.cache/ft-m0/h264_1080p60_20M.h264 --fps 60'
# test stream (WSL): 1080p60 H.264 20 Mb/s, Sunshine-like
ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=60,noise=alls=10:allf=t" -t 30 -pix_fmt yuv420p \
  -c:v libx264 -preset veryfast -tune zerolatency -profile:v high -bf 0 -g 600 \
  -b:v 20M -maxrate 20M -bufsize 1M h264_1080p60_20M.h264
```
