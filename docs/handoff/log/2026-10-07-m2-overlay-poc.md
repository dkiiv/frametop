# 2026-10-07 — M2: standalone overlay POC — DONE (demo passed)

Done:
- `remote-display/stream/ftrd-stream` (C++, built in the dev container by `build.sh`):
  Sunshine (Moonlight protocol) -> qcom-iris V4L2 decode -> GPU NV12->ABGR8888 (EGL dmabuf
  import, BT.709 limited) -> SteamVR overlay panel. Standalone, throwaway: no ft-screens, no input.
- Protocol: moonlight-embedded's `libgamestream` (pairing + app launch over HTTPS) and its
  `moonlight-common-c` submodule (RTSP/RTP/FEC/control), both **GPLv3**, fetched by `build.sh`
  at a pinned commit into `build/third_party` (git-ignored, and `scripts/sync.sh` leaves
  `build/` alone). Never committed; the binary is a local POC, not distributed. Only the
  needed files are compiled (no mDNS discovery, so no Avahi).
- Container packages added (installed + listed in `setup/dev-container.sh`): openssl-devel
  libcurl-devel expat-devel libuuid-devel.
- Shared code moved to `remote-display/common/rdcore.h` (decoder, GPU convert, SteamVR,
  stats); the M0 probe now includes it too.
- `remote-display/stream/stream.sh on|off|status|log|pair PIN` — toggle from the SteamOS host
  or the container; `on` survives the SSH session; `off` removes the overlay, ends the
  Sunshine session and prints the RESULT; it never touches SteamVR.
- Pairing: one-time `stream.sh pair <PIN>`, PIN typed by Curtis into Sunshine's web UI.
  Client cert/key live on the Frame only (`~/.config/frametop-remote-display`, mode 600).
- Connects to Sunshine at **10.35.78.22** (PC end of the Valve USB adapter; see the M1 log).

Measured — headless (`--novr`): a decoded frame matched a Windows screenshot (same layout,
correct colours, not flipped; small text crisp at native resolution).

Measured — demo, headset ON, passthrough ON: 5120x1440 HEVC 50 Mb/s, 60 fps requested, 533 s:

| metric                                               | value                         |
|------------------------------------------------------|-------------------------------|
| frames shown / lost / IDR requests / decode errors   | 22914 / **0** / 0 / 0         |
| frame rate (Sunshine skips unchanged frames)         | 32-60 fps per 5 s, mean 43    |
| Sunshine host processing (capture+encode, 5080)      | median 4.4 ms, p99 4.8        |
| RTT (moonlight-common-c estimate, dongle link)       | 1-3 ms                        |
| Frame: first packet in -> texture to SteamVR         | **median 7.2 ms, p99 10.1**   |
|   of which decode / GPU convert                      | 4.6 (p99 5.0) / 1.8 ms        |
| SteamVR compositor                                   | 90.2 Hz, 2 drops in 533 s (both in the first 10 s), GPU 2.17 ms |
| Frame SoC busy                                       | 16.5% of 8 cores              |

Estimated motion-to-photon (no camera measurement): host 4.4 + RTT/2 ~1.5 + Frame 7.2 +
compositor ~1 frame (11 ms) + capture wait (<=16.7 ms at 60 fps) ~= 25-40 ms.

Curtis's report (panel 2.4 m wide, 1.5 m ahead, flat):
1. Text readable in the centre; less readable towards the far left/right.
2. Size/distance good; the taskbar clock is not very readable.
3. No real lag; it noticeably feels like 60 Hz.
4. No stutter dragging windows (60 fps choppiness only).
5. Passthrough fine.

Analysis:
- Edges: a flat 2.4 m panel at 1.5 m puts its edges ~39 deg off-axis and ~1.9 m away, so text
  there is ~25% smaller in angle and foreshortened (~0.78), on top of lens fall-off. A curved
  panel (M4: Frametop's curve) fixes the geometry part.
- Small text: 5120 px across ~77 deg is ~66 px/deg, well above what the headset resolves,
  so 100%-scaled UI text is downsampled. Options: Windows scaling 125-150% for VR use, a wider
  curved panel, or a lower-resolution virtual display for the panel.
- 60 Hz feel: the PC monitor runs at **240 Hz** (CurrentRefreshRate 239); the client asked for
  60. `--fps 90` (headset rate) is a one-flag test; 5120x1440@90 ~= 664 Mpx/s, under the
  M0-measured iris throughput (4K HEVC flat-out 416 fps ~= 3.4 Gpx/s).

Broke / notes:
- On `off`, moonlight-common-c logs "Control stream connection failed: 4" during teardown:
  harmless (we stopped it).
- Windows PowerShell refuses `-File` on a `\\wsl$` path (execution policy); use
  `-EncodedCommand` for scripted Windows commands from WSL.

Vibepollo (Nonary's Apollo/Sunshine fork, which the Frametop dev used in testing) — looked at,
not adopted yet: see the decision in the session report; the short version is it adds nothing
for streaming the existing ultrawide (M2/M3), but its per-client virtual displays at the
requested resolution and "Remote Monitor" (extra independently streamed displays) map
directly onto M4 and the second-display backlog item. It is protocol-compatible, so
ftrd-stream should work against it unchanged.

Next: M3 — input back-channel (Frametop pointer -> LiSendMousePositionEvent, keyboard ->
LiSendKeyboardEvent). Cheap first: try `stream.sh on --fps 90`.

Needs: Curtis's call on Vibepollo timing (now vs at M4); headset time for M3 testing.
