# 04 — Milestones

Each milestone ends with: (a) something verifiable, (b) a `log/` entry, (c) a
push. Stop and ask Curtis when a milestone says ASK. Do not run ahead of a
blocked milestone by guessing.

## M0 — Decoder feasibility spike (do this first; ~1 session)

Goal: answer "can the Frame hardware-decode a 1080p60 HEVC/H.264 stream while
passthrough is running, and can the decoded frames leave the decoder as
DMA-BUFs?"

- [ ] On the Frame (dev container or host), enumerate decode APIs:
      `v4l2-ctl --list-devices`, `ls /dev/video*`, `vainfo`/`vulkaninfo`
      (video decode profiles), mesa driver in use (`glxinfo`/`dri`), presence
      of any vendor MPP/codec libs.
- [ ] Play a 1080p60 test file (download one to the Frame) with every
      hardware-ish path you found; record fps + CPU% + whether frames exit as
      dmabuf (e.g. `ffprobe -hwaccel` variants, `mpv --vo=gpu --hwdec=...`).
- [ ] Repeat while the headset is worn (passthrough active) — Curtis wears it.
- [ ] Write the numbers into `log/`.

**Gate:** if no path holds 1080p60 with headroom → STOP, report to Curtis,
project pivots to "document why + what Valve would need to expose".

## M1 — Sunshine sender on Windows (ASL: needs Curtis at the PC)

- [ ] Curtis installs Sunshine on the Windows PC (or agent via SSH if set up).
- [ ] Verify a stock Moonlight client (phone/laptop app) streams the PC fine —
      proves encoder/network before Frame variables enter.
- [ ] Note GPU encoder used (NVENC/AMF/QuickSync), codec, latency numbers.

## M2 — Standalone overlay POC (the demo)

Goal: Windows desktop visible as a SteamVR overlay panel on the Frame.
Deliberately NOT wired into ft-screens yet — standalone app, throwaway.

- [ ] Skeleton: receive Sunshine/Moonlight stream (vendor moonlight-common or
      hand-roll the RTSP handshake + RTP for ONE fixed config).
- [ ] Decode via the M0-winning path → dmabuf.
- [ ] Import via OpenVR `IVRIPCResourceManagerClient::ImportDmabuf`
      (copy the pattern from `screens/vr.cpp`; build like the pointer driver
      if it must run on the host, else in-container overlay).
- [ ] Toggle script: start/stop the stream overlay without touching SteamVR.
- [ ] ASK Curtis: put it on, report quality/latency; iterate codec/bitrate.

## M3 — Input back-channel

- [ ] Map Frametop pointer (the 3D-mouse dot / controller laser ray → panel UV)
      to Moonlight absolute-mouse packets; clicks + wheel.
- [ ] Keyboard: reuse Frametop's VR keyboard / input relay output as the key
      event source into Moonlight keyboard packets.
- [ ] Cursor: hide Windows cursor, draw ours (or accept double cursor for POC).

## M4 — Behaves like a local screen

- [ ] Remote stream as a proper ft-screens output (Wayland client submitting
      dmabufs, like KWin) so move/resize/curve/pin-wrist all come free.
- [ ] Resolution/refresh renegotiation when the panel is resized.
- [ ] This is where you compare against the dev's design when it lands —
      rebase or throw away, his call via Curtis.

## M5 — Yield to games (the dev's "toggle + safe restore")

- [ ] Detect VR game focus (Frametop already knows — see `power/`, session
      docs); suspend stream + release decoder cleanly on game start.
- [ ] Restore on game exit without a SteamVR restart.
- [ ] Measure: does a suspended stream actually free the decoder budget?

## Backlog / nice-to-haves

- Second display (only if M0 numbers say the decoder laughs at one 1080p).
- AV1 vs HEVC vs H.264 quality/latency bake-off table.
- Audio (Sunshine sends Opus; Frame output path unknown) — POC is silent.
- Auto-reconnect on network drop.

## Report template for log/ entries

```
# YYYY-MM-DD — <milestone>: <slug>
Done:      bullet list of what now works
Measured:  fps / latency / CPU% / decoder API used — real numbers
Broke:     what failed and the exact error
Next:      the single next action, with the command to start it
Needs:     anything only Curtis can do (wear headset, touch Windows PC, approve)
```
