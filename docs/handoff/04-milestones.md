# 04 — Milestones

**Status (2026-10-08):** M0–M4 and M6 done. **M5 not done:** its acceptance criterion, the
worn test with a real VR game, is unverified (postponed by Curtis; audit item 1). End-to-end
latency measured (log/2026-10-08-audit.md: input->decoded frame median 13 ms on the Valve
adapter, 19 ms on home Wi-Fi).
Open: the items under "Open items to revisit", comparing with the Frametop dev's design (M4),
and the backlog (audio, auto-reconnect, codec bake-off). User guide: remote-display/README.md.

Each milestone ends with: (a) something verifiable, (b) a `log/` entry, (c) a
push. Stop and ask Curtis when a milestone says ASK. Do not run ahead of a
blocked milestone by guessing.

## M0 — Decoder feasibility spike (do this first; ~1 session)

Goal: answer "can the Frame hardware-decode a 1080p60 HEVC/H.264 stream while
passthrough is running, and can the decoded frames leave the decoder as
DMA-BUFs?"

- [x] On the Frame (dev container or host), enumerate decode APIs:
      `v4l2-ctl --list-devices`, `ls /dev/video*`, `vainfo`/`vulkaninfo`
      (video decode profiles), mesa driver in use (`glxinfo`/`dri`), presence
      of any vendor MPP/codec libs.
- [x] Play a 1080p60 test file (download one to the Frame) with every
      hardware-ish path you found; record fps + CPU% + whether frames exit as
      dmabuf (e.g. `ffprobe -hwaccel` variants, `mpv --vo=gpu --hwdec=...`).
- [x] Repeat while the headset is worn (passthrough active) — Curtis wears it.
- [x] Write the numbers into `log/`.

**Gate:** if no path holds 1080p60 with headroom → STOP, report to Curtis,
project pivots to "document why + what Valve would need to expose".

## M1 — Sunshine sender on Windows (ASL: needs Curtis at the PC)

- [x] Curtis installs Sunshine on the Windows PC (or agent via SSH if set up).
- [x] Verify a stock Moonlight client (phone/laptop app) streams the PC fine —
      proves encoder/network before Frame variables enter.
- [x] Note GPU encoder used (NVENC/AMF/QuickSync), codec, latency numbers.

## M2 — Standalone overlay POC (the demo)

Goal: Windows desktop visible as a SteamVR overlay panel on the Frame.
Deliberately NOT wired into ft-screens yet — standalone app, throwaway.

- [x] Skeleton: receive Sunshine/Moonlight stream (vendor moonlight-common or
      hand-roll the RTSP handshake + RTP for ONE fixed config).
- [x] Decode via the M0-winning path → dmabuf.
- [x] Import via OpenVR `IVRIPCResourceManagerClient::ImportDmabuf`
      (copy the pattern from `screens/vr.cpp`; build like the pointer driver
      if it must run on the host, else in-container overlay).
- [x] Toggle script: start/stop the stream overlay without touching SteamVR.
- [x] ASK Curtis: put it on, report quality/latency; iterate codec/bitrate.

## M3 — Input back-channel

- [x] Map Frametop pointer (the 3D-mouse dot / controller laser ray → panel UV)
      to Moonlight absolute-mouse packets; clicks + wheel.
- [x] Keyboard: reuse Frametop's VR keyboard / input relay output as the key
      event source into Moonlight keyboard packets.
- [x] Cursor: hide Windows cursor, draw ours (or accept double cursor for POC).

## M4 — Behaves like a local screen

**Requirement (Curtis, 2026-10-07):** multiple *virtual* displays, not only mirrors of
physical monitors on the PC. Plan: switch the host from stock Sunshine to Vibepollo (Nonary's
Apollo/Sunshine fork, which the Frametop dev also tested) at the start of M4 for its built-in
per-client virtual displays at the client's requested resolution and "Remote Monitor" extra
streams. Same Moonlight protocol, so ftrd-stream should carry over. The PC's standalone
MikeTheTech "Virtual Display Driver" was removed on 2026-10-07 to avoid conflicts (package
backed up on the PC); Virtual Desktop's own "Virtual Desktop Monitor" stays (Virtual
Desktop Streamer uses it).

- [x] Remote stream as a floating Frametop window (Wayland client of the Frametop desktop,
      dmabufs straight to KWin): move/resize/curve/pins come from Frametop. `stream.sh float N`.
- [x] Resolution renegotiation when the panel is resized: window mode + Vibepollo Remote
      Monitor reconnects at the window's size (~5 s); the PC's virtual monitor takes it.
- [x] Several virtual monitors at once (one per paired identity, up to 4 in Vibepollo).
- [ ] This is where you compare against the dev's design when it lands —
      rebase or throw away, his call via Curtis. (Waiting on the dev.)

### Known limitations (host: Vibepollo 2.0.0) — expected to be fixed upstream; revisit if not
- Vibepollo doesn't remember the PC's monitor layout (confirmed by the Frametop dev). With
  Curtis's layout (ultrawide primary at 0,0, 1080p below it) its first Remote Monitor start fails
  ("composed display topology did not apply") and leaves Windows' default arrangement.
  Workarounds: ftrd-stream releases and retries (backing off); remote-display/host/ftrd-host.ps1
  (M6) restores the layout whenever it's wrong. Monitors visibly rearrange for a few seconds at
  each start/resize.
- With two clients, Vibepollo sometimes keeps one virtual monitor after both released
  ("Deferring virtual display cleanup..."); `stream.sh cleanup` (a start+release by each
  identity) clears it, or ftrd-host.ps1 with a Vibepollo API token.
- Vibepollo's "Desktop" app makes its virtual screen the PC's ONLY display (physical monitors
  dark; twice in this project). ftrd-stream refuses it (FTRD_ALLOW_DESKTOP=1 to force); its
  default app is "Remote Monitor".
- Each extra virtual monitor needs its own paired identity, with Launch + input permissions
  granted by hand in the web UI (Vibepollo gives full permissions only to the first pairing).
- Untested: Vibepollo's `remote_monitor_disconnect_on_stream_end` setting, pre-release builds.

## M5 — Yield to games (the dev's "toggle + safe restore")

### Open items to revisit (from M4 part 1, 2026-10-07)
- [ ] Frametop's keyboard doesn't open by itself for the stream window (no Wayland
      text-input; Windows fields can't signal focus). Today: a mapped controller button
      (Frametop Input Settings, keyboard toggle) or `vrkeyboard show` on @ft_screens. Better:
      a host-side focus signal (Vibepollo/Sunshine) -> auto-open. Note: the controller's
      system ("...") button can't be mapped (Frametop maps every button but that one; it's
      SteamVR's dashboard toggle) — Curtis tried it on 2026-10-07; use another button.
- [x] Wrist pinning of the stream window works (Curtis, 2026-10-07).
- [x] Upstream the grab-bar hit-box fix: branch fix/grab-bar-hit-box on the fork (on upstream
      main), PR link handed to Curtis. Upstream PR #46 (SaberMage, same fix, opened earlier the
      same day) was already pulled in by the maintainer "for the next release", so ours is a
      duplicate unless he wants it for the record.
- [ ] Lowest-row pointer diagnostics stay behind FTRD_POINTER_DEBUG=1; drop when no longer
      useful.

- [x] Detect VR game focus (ft-screens "state"); suspend stream + release decoder cleanly on
      game start (headless: 0.1 s, decoder closed, 0 kB/s). Worn test with a real game pending.
- [x] **Lasers off during VR games, like Frametop's screens** (Curtis, 2026-10-07): window mode
      (the default now) is a Frametop panel, so Frametop's own in-game rules apply; overlay mode
      hides its panel and keyboard button while yielding, so nothing takes the controllers.
      Worn test with a real game pending (with the yield test above).
- [x] Restore on game exit without a SteamVR restart (headless: 1.4 s via Vibepollo's Resume).
- [x] Measure: does a suspended stream actually free the decoder budget? (decoder fd closed)

## M6 — PC link (Curtis, 2026-10-07)

- [x] The Frame tells the PC how its virtual monitors are arranged (signed answers);
      remote-display/host/README.md.
- [x] Virtual monitors held right of the physical ones, in the Frame's order (tested: one moved
      left of the ultrawide was put back in ~12 s, in Frame order).
- [x] Panel poses live (ft-floatd `list apps`); worn: Curtis stacked the panels and Windows
      stacked the monitors with one change (20:29); deadzone + settle after his "too sensitive".
- [x] No key to copy: the Frame signs with its Vibepollo pairing key, the PC checks it against
      Vibepollo's certificate; the PC finds the Frame by broadcast.
- [x] New-user path: remote-display/README.md, `stream.sh setup`, `ftrd-host.ps1 -Install`, one
      "Remote PC" menu entry.
- Dropped on Curtis's call: taking the physical monitors off and the heartbeat fail-safe (he
  moves windows with Win+Shift+arrows instead).

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
