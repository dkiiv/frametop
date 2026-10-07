# 2026-10-07 — M4 part 1: window mode (stream as a Frametop floating window) — WORKS

Done:
- M5 item added (Curtis): lasers off during VR games like Frametop's screens (the M3 overlay's
  MakeOverlaysInteractiveIfVisible takes controllers from a scene app).
- ftrd-stream `--window [WxH]` (stream/wlwin.h): a Wayland client of the Frametop desktop
  (nested KWin, socket /run/user/1000/frametop/wayland-0). Each decoder capture buffer (NV12,
  linear) is wrapped once as a wl_buffer (linux-dmabuf) and attached as is: no copy, no GPU pass
  in our process; KWin converts while compositing. A buffer goes back to the decoder on
  wl_buffer.release. wp_viewporter scales to the window size. wl_pointer -> absolute mouse /
  buttons / hi-res scroll; wl_keyboard evdev -> Windows VK + modifier bits; keys and buttons are
  released on leave and exit. Server-side decorations (KWin title bar). App id
  org.frametop.RemoteDisplay.
- `stream.sh float` = `ft-float launch org.frametop.RemoteDisplay` (desktop file installed by
  `stream.sh install-desktop`): ft-floatd floats it on its own panel, so move/resize/curve/pins/
  profiles come from Frametop unchanged.
- Fixes on the way: podman (distrobox enter) failed inside the Frametop session because the
  session moves XDG_RUNTIME_DIR to .../frametop (stream.sh resets it); the client now exits
  cleanly when the desktop goes away (before: KWin never released buffers -> the decoder
  starved: 4398 lost / 2673 IDR in 142 s).
- **Frametop bug found and fixed (screens/vr.cpp MakeChrome)**: SteamVR hit-tests an overlay by
  its *mouse scale's* aspect, not its texture's. Chrome had the default 1x1 mouse scale, so the
  256x24 grab bar caught the laser in a ~square box (0.39 m wide -> ~0.43 m tall), reaching
  ~19 cm (~150 px) up into the bottom of the panel above it: Curtis couldn't reach the Windows
  taskbar icons above the bar. Affects every Frametop panel (screens too). Fix: mouse scale =
  texture size for every control. Upstream-worthy on its own.
  Tools: stream/hitprobe.cpp (rays at a frametop.float.N panel's bottom centre, reports hits),
  stream/hitaspect.cpp (throwaway 256x24 overlay: default mouse scale -> 0.3975 m tall hit,
  256x24 -> 0.035 m; drawn 0.0375 m). The probe needs the headset awake: SteamVR doesn't
  hit-test overlays that aren't drawn (standby).

Measured / verified:
- Window mode, 30 s: 3.8 ms Frame-side median (p99 5.4) vs ~6.5-7 ms in overlay mode (no
  convert step), 0 lost; Frame SoC 7.8 % busy.
- Worn, Curtis: colours correct, text sharp; move and resize work; clicks and drags work;
  smooth as before. Taskbar: before the fix, icons above the bar unreachable (flat and curved);
  after, reachable in both. hitprobe after the fix: the bar is hit only 3-6 cm below the panel's
  edge (where it is drawn); before, from 12 cm below to beyond 10 cm above.
- Keyboard: Frametop's keyboard (opened with `vrkeyboard show` on @ft_screens) typed
  "hello123! Hi" (Shift works), Tab, Backspace into Windows.

Open:
- Frametop's keyboard doesn't open by itself for this window (no Wayland text-input; Windows
  fields can't signal it). Curtis can map a controller button to toggle it (Frametop Input
  Settings), as for Chromium/Electron apps. A Sunshine/Vibepollo-side focus signal would be
  needed for auto-open; not in scope.
- Wrist pinning untested (second controller away).

Next (M4 part 2): Vibepollo on the PC (Curtis: installer + UAC + web login), re-pair, check
window mode unchanged, then virtual displays sized to the panel; resizing the window ->
request a matching host display.
