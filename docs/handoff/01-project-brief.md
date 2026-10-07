# 01 — Project brief

## Goal

Stream a Windows 11 PC's screen (one or more displays) over the LAN into the
Valve Steam Frame, rendered **inside Frametop as a display panel** — same look,
feel, and controls as Frametop's local screens (move, resize, curve, pin to
wrist). Latency and image quality good enough to read text and drive a mouse.

This is a **proof of concept**, not a product. Success = a working demo Curtis
can put on his head, plus notes on what breaks.

## Why it might work (the core insight)

Frametop already draws each local screen by importing a **DMA-BUF** into SteamVR
as a shared texture (`screens/vr.cpp` → `IVRIPCResourceManagerClient::ImportDmabuf`
→ `TextureType_SharedTextureHandle`), with no copy and no size limit. A remote
display is the same problem with one extra stage in front:

```
Windows PC (Sunshine: capture + NVENC/AMF encode)
        │  RTP/UDP, H.264/HEVC/AV1 (Moonlight protocol)
        ▼
Frame client: receive → hardware-decode → DMA-BUF
        │  (the new code)
        ▼
Frametop panel: ImportDmabuf → SteamVR overlay   (already exists)
```

The decode-to-DMA-BUF-to-overlay path is the whole project. Everything else
(handshake, input back-channel, settings) is plumbing around it.

## Scope — v1 (the POC)

- ONE remote display, one stream, into ONE Frametop panel.
- Video one way; mouse + keyboard back to the PC.
- Fixed resolution/codec chosen by you during bring-up; auto-tune is out of scope.
- Runs from a command / a simple toggle script. No polished UI.

## Non-goals (explicitly out)

- Multiple simultaneous 4K displays (the dev himself says the decoder can't).
- Replacing the dev's Sunshine fork or shipping anything to end users.
- HDR, 120Hz, surround audio, gamepad passthrough, app-switcher integration.
- Anything that needs root on the Frame beyond what Frametop's installers
  already do with Curtis's approval.

## Hard constraints

- **Frame is aarch64, read-only root, no compilers on the host.** Build inside
  the `dev` distrobox (Fedora 44). Ship binaries that run in the container, or
  statically-linked host binaries (the SteamVR driver is the one host-built
  piece — see `pointer/driver/build.sh` for the pattern).
- **Decoder budget is shared** with passthrough and gamescope. Measure it; don't
  assume headroom. This is the make-or-break number.
- **You cannot see the headset.** Every visual result needs Curtis. Build the
  loop so he can flip the stream on/off and report, and instrument the client to
  log fps / dropped frames / decode latency so his reports are quantified.
- **Don't step on the dev.** This is exploratory. No upstream PRs/issues about
  the remote-display work without Curtis's go-ahead.

## Definition of done (POC)

1. Windows desktop visible in a Frametop panel at ≥1080p, ≥30fps.
2. Mouse on the Frame moves the Windows cursor; keyboard types into Windows.
3. A toggle turns the stream on and off without crashing SteamVR or the desktop.
4. `log/` has: the decoder-budget numbers, the latency you measured, and a
   candid "would I use this" writeup.
