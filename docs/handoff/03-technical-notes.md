# 03 — Technical notes

Facts marked **[verified]** were read out of the Frametop repo (paths given) or
are stable public facts. **[measured]** = measured on Curtis's Frame/PC during the
POC (the log entry is named). **[open]** = still unverified. The original brief's
guesses that turned out wrong are struck through and corrected in place.

## The Frame's decode stack [measured, M0: log/2026-10-06-m0-decoder-probe.md]

- SoC **Qualcomm SM8650** (Snapdragon 8 Gen 3), GPU Adreno 750 (Mesa Turnip; GL via
  Zink, GLES via freedreno). Not Panfrost/Venus.
- Hardware decoder: upstream **qcom-iris**, a V4L2 **stateful** M2M decoder at
  `/dev/video22` = **`/dev/video-dec0`** (kernel 6.18). `steamos` has rw (video group);
  works from the `dev` container. `/dev/video0..21` are the camera ISP (tracking and
  passthrough), `/dev/video99` is SteamVR's v4l2loopback webcam.
- Codecs: H.264, HEVC, VP9. **No AV1.** Up to 8192x8192.
- **No VA-API, no Vulkan video** (Turnip exposes no VK_KHR_video_*). V4L2 is the only path.
- Output: NV12 (linear; coded 1920x1088 for 1080p, UV plane at stride*1088 in the same
  buffer), Q08C (UBWC NV12); "AB24" is not linear RGBA. Every capture buffer exports as a
  DMA-BUF (VIDIOC_EXPBUF). Hold a shown buffer until the next one: iris reuses a buffer
  requeued at once.
- **NV12 straight to SteamVR renders green garbage**, although
  `GetDmabufModifiers` lists NV12 and `ImportDmabuf` succeeds. Convert on the GPU to
  **linear ABGR8888** (EGL dmabuf import + samplerExternalOES, BT.709 limited range for
  Sunshine): ~1-2 ms at 1080p, 2-3 ms at 4K; PSNR 50 dB against software decode.
  (Window mode avoids the pass entirely: NV12 goes to KWin, which converts while compositing.)
- Cost, headset worn and passthrough on: 1080p60 decode ~2.5 ms/frame and ~2% of the SoC
  beyond idle; 4K60 HEVC holds 60 fps at ~4.5 ms/frame. 0 compositor drops.

## The display path you're extending [verified]

- `docs/design.md` + `docs/reference.md`: ft-screens (wlroots) hosts nested
  KWin; one KWin window = one screen; frames arrive as **DMA-BUFs** and go to
  SteamVR via `IVRIPCResourceManagerClient::ImportDmabuf` as
  `TextureType_SharedTextureHandle` — no copy, no size limit.
- `screens/vr.cpp` is the reference implementation: `GetDmabufModifiers`
  (negotiates acceptable plane/modifier layouts), `ImportDmabuf`, panel pose
  matrices, mouse-event routing into the panel.
- `screens/handcut.cpp` shows importing *other* producers' dmabufs and
  compositing — closest existing code to "external frame source".
- KWin's nested Wayland backend needs `zwp_linux_dmabuf_v1` v4 with host
  feedback — i.e. the dmabuf vocabulary is already spoken end-to-end on the
  Frame.

**Design implication:** the remote client should end its life as a Wayland
client that submits decoded frames as dmabufs to a new ft-screens output —
exactly like KWin does — OR (faster to prototype) as a standalone SteamVR
overlay app that imports its own dmabufs. The first matches the brief
("behaves like local screens"); the second is the right M1/M2 shortcut since it
touches zero Frametop code.

## Sunshine / Moonlight (the stream) [verified public facts]

- Sunshine (sender, Windows) speaks the Moonlight protocol: RTSP-style
  handshake, then RTP/UDP video (H.264 / HEVC / AV1) + audio + input + control
  channels. It's the sender we want — no porting needed on Windows.
- Moonlight-common(-rust) implements the client protocol; moonlight-common-c is
  the C reference. Both MIT/GPL-family — check licenses before vendoring;
  Frametop is MIT.
- Input back-channel: keyboard/mouse/gamepad events are defined by the protocol
  (the same packets Moonlight sends); Sunshine injects them.
- ~~The Frame's GPU: Panfrost/Venus; V4L2 vs GL/Vulkan decode unknown.~~
  **Resolved (M0):** Qualcomm, V4L2 stateful (qcom-iris); see "The Frame's decode stack".
- License **[verified]**: moonlight-embedded (libgamestream) and moonlight-common-c are
  **GPLv3**. ftrd-stream fetches and links them at build time, so the built client is
  GPLv3 and can't be merged into MIT Frametop. remote-display/README.md, License.

## Decoder budget [measured: resolved]

- The dev's own words (Oct 2026): "definitely doable... so long as you aren't
  streaming multiple 4k displays"; "decoder budget is pretty much separate from
  the standard displays... so long as the decoder isn't overwhelmed."
- Frametop's existing VNC path encodes H.264 **in software on the Frame**
  (~60% of a core, `session/vnc-bridge.sh` comment) — that's the CPU cost the
  new path avoids by decoding instead.
- ~~Measure early ... [open]~~ **Resolved (M0, worn, passthrough on):** 1080p60
  H.264/HEVC at 60.03 fps, 0 drops, ~2% SoC; 4K60 HEVC too; video block ~40 C flat. Live
  (M2-M4): 5120x1440@60 and 2560x1440@90 streams, Frame SoC 6-17% busy; two monitors at once
  fine. A suspended stream closes the decoder (M5).

## Latency budget [measured: see the latest log entry for end-to-end]

- Text-typing comfort needs end-to-end (mouse-move on PC → photon on Frame)
  under ~50–70 ms.
- Measured per stage (M2/M4): host capture+encode 1.6-4.4 ms (RTX 5080, NVENC P1), RTT 1-3 ms
  on the Valve USB adapter, Frame receive→shown 3.8 ms (window mode) / ~7 ms (overlay mode).
- End to end: `ftrd-stream --latency-test N` times Frame input → PC cursor → capture → encode
  → network → decoded frame on the Frame's one clock (no camera); numbers per network path in
  log/2026-10-08-audit.md. Not included: Frame display scan-out and SteamVR compositing
  (~1 frame at 90 Hz, ~11 ms), which only a camera can see. **[open]**: a photon measurement.

## Existing baseline to beat [verified]

`session/remote-desktop.sh` + `session/vnc-bridge.sh`: krdp captures the nested
KWin → software H.264 → FreeRDP → Xvnc → VNC out (Tailscale). It streams the
*Frame's own desktop* out to a viewer — the inverse direction — but it's the
codebase's only network-video code and shows the service/credential patterns
(new password per start, localhost-only, `remote-ctl.sh` toggles).

## The dev's plan (from his Oct 2026 messages, relayed by Curtis)

- V0.3: hand-tracking interaction with frametop displays; maybe gaze nudging
  the 3D mouse.
- A **heavily modified Sunshine streamer** rendering remote displays inside
  frametop "similar to the current displays" — not in the public repo yet.
- He wants **toggle tools + safe restore for gaming** (streams must yield the
  decoder cleanly when a VR game starts).
- Implication: the interface he lands on will likely be a new output type in
  ft-screens. Our POC should keep the decode→dmabuf→panel seam narrow so it can
  be thrown away or rebased when his design goes public. Don't gold-plate.

## Risks, ranked

1. ~~No usable hardware decoder path on the Frame.~~ Resolved M0: qcom-iris works.
2. ~~Decoder contention with passthrough.~~ Resolved M0: none measured.
3. ~~SteamVR rejects the decoder's modifiers.~~ Resolved M0: accepted but NV12 renders
   green; GPU-convert to ABGR8888 (or window mode).
4. ~~Input back-channel edge cases.~~ Resolved M3: absolute mouse, buttons, scroll, keys
   work; keyboard auto-open still open (04-milestones).
5. Upstream churn: dev ships his own version mid-project → our code is a
   spike, not a product. Accept and move on.

## Fork patches to upstream Frametop code [tracking]

- `screens/vr.cpp` MakeChrome: controls' mouse scale = texture size (commit cf893c8 here, and
  branch fix/grab-bar-hit-box). It **duplicates upstream PR #46** (SaberMage, same fix), which
  the maintainer said he'd pull in for the next release; as of 2026-10-08 it isn't in upstream
  `main` or `experimental` yet. When it lands: drop cf893c8 when rebasing onto upstream and
  delete fix/grab-bar-hit-box. Check: `git grep -n SetOverlayMouseScale origin/main --
  screens/vr.cpp` shows a line inside MakeChrome.
- `setup/dev-container.sh`: judges success by what's installed (udisks2's scriptlet fails in a
  rootless container); upstream-worthy, not offered yet (Curtis's call).
