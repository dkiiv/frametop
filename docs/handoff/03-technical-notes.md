# 03 — Technical notes

Facts marked **[verified]** were read out of the Frametop repo (paths given) or
are stable public facts. **[open]** = measure/verify yourself; don't trust them.

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
- The Frame's GPU: vendor ARM SoC with a hardware video block exposed through
  Mesa (Panfrost/Venus stack) — whether it exposes a **V4L2 stateful decoder**
  or only GL/Vulkan decode is the single most important unknown. **[open]**

## Decoder budget [partially verified]

- The dev's own words (Oct 2026): "definitely doable... so long as you aren't
  streaming multiple 4k displays"; "decoder budget is pretty much separate from
  the standard displays... so long as the decoder isn't overwhelmed."
- Frametop's existing VNC path encodes H.264 **in software on the Frame**
  (~60% of a core, `session/vnc-bridge.sh` comment) — that's the CPU cost the
  new path avoids by decoding instead.
- Measure early: run `ffmpeg`/`mpv` hardware-decoding a 1080p60 HEVC file on the
  Frame while passthrough is active; watch thermal/fps. If a file decode can't
  hold 60fps with passthrough on, a live stream won't either. **[open]**

## Latency budget [open]

- Text-typing comfort needs end-to-end (mouse-move on PC → photon on Frame)
  under ~50–70 ms. Typical Moonlight LAN numbers: 10–20 ms encode, 5–10 ms
  network, 5–15 ms decode, +compositor. The Frame adds SteamVR overlay
  compositing — unknown. Instrument with a phone-camera photo of a latency
  overlay (e.g. `displayfd`-style test pattern on Windows vs Frame screen).

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

1. **No usable hardware decoder path on the Frame** (no V4L2 M2M / no dmabuf
   output from the decoder). Fallback: CPU-decode 1080p (AV1/HEVC too slow,
   H.264 maybe) — POC becomes "can't, here's the data". Measure this FIRST.
2. Decoder contention with passthrough causes stutter/thermal issues.
3. SteamVR overlay import rejects the decoder's modifiers (measure with
   `GetDmabufModifiers` early).
4. Input back-channel edge cases (relative vs absolute mouse; Sunshine expects
   Moonlight's absolute pointer packets — map Frametop's panel-space coords).
5. Upstream churn: dev ships his own version mid-project → our code is a
   spike, not a product. Accept and move on.
