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
      rebase or throw away, his call via Curtis.

### Known limitations (host: Vibepollo 2.0.0) — expected to be fixed upstream; revisit if not
- Vibepollo doesn't remember the PC's monitor layout (confirmed by the Frametop dev). With
  Curtis's layout (ultrawide primary at 0,0, 1080p below it) its first Remote Monitor start fails
  ("composed display topology did not apply") and leaves Windows' default arrangement.
  Workarounds: ftrd-stream releases and retries (up to 3x); a user-level watcher on the PC
  (Startup folder, outside the repo; notes in ~/.local/share/ftrd on WSL) restores the layout
  whenever it's wrong, during and after sessions. Monitors visibly rearrange for a few seconds
  at each start/resize.
- With two clients, Vibepollo sometimes keeps one virtual monitor after both released
  ("Deferring virtual display cleanup..."); a start+release by each identity clears it.
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
- [ ] Wrist pinning of the stream window untested (second controller was away).
- [ ] Upstream the grab-bar hit-box fix (commit "screens: set controls' mouse scale...") to
      Frametop as its own PR.
- [ ] Lowest-row pointer diagnostics stay behind FTRD_POINTER_DEBUG=1; drop when no longer
      useful.

- [ ] Detect VR game focus (Frametop already knows — see `power/`, session
      docs); suspend stream + release decoder cleanly on game start.
- [ ] **Lasers off during VR games, like Frametop's screens** (Curtis, 2026-10-07): the
      panel sets `MakeOverlaysInteractiveIfVisible` (M3), which takes the controllers away
      from a running scene app. Clear it (and the keyboard button's) while a game runs; only
      the 3D mouse or the dashboard should reach the panel then (see screens/vr.cpp's
      outside_games mode and UpdateAim).
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
