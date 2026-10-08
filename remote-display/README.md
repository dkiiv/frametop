# Remote PC: your Windows PC's monitors in Frametop

Remote PC shows your Windows PC on the Steam Frame as extra monitors: virtual monitors that
exist only while you use them, each in its own Frametop panel. Move, resize and curve the panels
like any Frametop window; resizing a panel resizes its monitor on the PC. Point and click with
the controllers, type with Frametop's keyboard. Your physical monitors stay on, and the virtual
ones sit to their right in Windows, in the same order as the panels around you, so a window
dragged off the right edge of the left panel comes in on the right panel.

Status: a proof of concept on the dkiiv/frametop fork (branch `remote-display-poc-handoff`),
not part of Frametop. It works day to day on one setup (RTX 5080, Vibepollo 2.0.0); expect rough
edges elsewhere.

## What you need

- A Steam Frame with Frametop installed (see the main README), on this fork's branch:
  ```
  cd ~/frametop
  git remote add dkiiv https://github.com/dkiiv/frametop.git
  git fetch dkiiv && git checkout -b remote-display dkiiv/remote-display-poc-handoff
  ./install.sh
  ```
  (It carries two small Frametop changes Remote PC relies on: `ft-float list apps` and the
  grab-bar hit-box fix. Restart the Frametop desktop afterwards.)
- A Windows 10/11 PC with a GPU that can encode HEVC (NVIDIA, AMD or Intel), on the same network
  as the Frame. Valve's USB Wi-Fi adapter for the PC gives the lowest latency (about 3 ms here),
  but home Wi-Fi works.
- [Vibepollo](https://github.com/Nonary/Vibepollo/releases) 2.0.0 on the PC (a Sunshine fork
  that makes a virtual monitor per paired device). It replaces Sunshine if you have it.

## Set it up (once)

### On the PC

1. Install Vibepollo (`VibepolloSetup-v2.0.0.exe`). Open https://localhost:47990 and create
   the web UI login it asks for.
2. Note the PC's IP address (`ipconfig`, the adapter on the Frame's network). With Valve's USB
   adapter you can skip this.
3. Optional but recommended: the layout keeper. In PowerShell (as yourself, no admin):
   ```
   $f = "$env:TEMP\ftrd-host.ps1"
   irm https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/host/ftrd-host.ps1 -OutFile $f
   powershell -ExecutionPolicy Bypass -File $f -Install
   ```
   With your physical monitors arranged as you like them. It saves that layout, keeps it (Vibepollo
   2.0.0 shuffles it whenever a virtual monitor comes or goes) and places the virtual monitors to
   the right in the panels' order. It starts at every logon. Details: [host/README.md](host/README.md).

### On the Frame

In the Frametop desktop, open Konsole (or SSH in) and run:
```
~/frametop/remote-display/stream/stream.sh setup [PC address] [number of monitors]
```
for example `stream.sh setup 192.168.1.20 2`. Leave out the address with Valve's USB adapter;
monitors default to 2 (up to 4). The first run builds the client (a few minutes). Then, for each
monitor, it shows a PIN: on the PC, open https://localhost:47990 → PIN, enter it, and name the
device as it says ("Frame monitor 1", ...).

Vibepollo gives full rights only to the first device it pairs. For monitors 2 and up, open the
web UI → Clients, and give each "Frame monitor N" the Launch and input (mouse, keyboard)
permissions.

To type, map a controller button to Frametop's keyboard in Frametop Input Settings (any button
but the system "..." button, which belongs to SteamVR).

## Use it

- **Open:** Steam button → **+** → **Remote PC**. Your monitors open one after the other, each
  in its own panel (a dark panel first, the picture a few seconds later).
- **Arrange:** move the panels where you want them. About 10 seconds after you let go, Windows
  rearranges its virtual monitors to match (left/right, and above/below for stacked panels);
  your screens may blink once.
- **Resize:** resize a panel; once you let go, the picture freezes for about 5 seconds while
  the PC's monitor changes size.
- **VR games:** when a VR game starts, the panels step aside (the stream pauses, the PC keeps
  the monitors and their windows); they come back a second or two after the game ends.
- **Close:** close the panels. The virtual monitors disappear from Windows, and windows on them
  move to your physical monitors.

Moving windows from your physical monitors onto a virtual one: Win+Shift+Left/Right, or drag.

## When something's off

- **A virtual monitor stays in Windows after you closed everything** (Vibepollo 2.0.0 sometimes
  keeps one): on the Frame, `stream.sh cleanup` (your monitors flash a few times). Or let the
  layout keeper do it: create a Vibepollo API token (web UI → API tokens, scope
  `POST /api/display/terminate_virtual`) and save it as `%LOCALAPPDATA%\ftrd\vibepollo.token`.
- **Your physical monitors are rearranged or at a lower refresh rate:** the layout keeper fixes
  that within seconds; without it, fix it in Display Settings. `ftrd-host.ps1 -Restore` puts the
  saved layout back now; re-save with `-SaveBaseline` after changing it on purpose.
- **Physical monitors dark:** Win+P → Extend. (This happened with Vibepollo's "Desktop" app, which
  makes its virtual screen the only display; Remote PC refuses to start that app.)
- **A panel stays dark:** `stream.sh status` and `stream.sh log N` on the Frame show what the
  stream is doing; `ftrd-host.ps1 -Status` on the PC shows the displays and what the Frame reports.

## Limits (for now)

- No sound (it stays on the PC).
- Stepping aside for VR games is tested only with a simulated game so far.
- Frametop's keyboard doesn't open by itself when you click a text field on the PC; use the
  mapped button.
- One paired device per virtual monitor, up to 4 (Vibepollo).
- Vibepollo 2.0.0 shuffles the physical monitors at each virtual monitor start/stop (the layout
  keeper puts them back) and its first start sometimes fails and is retried, so opening takes a
  few seconds and your screens blink.

## How it fits together

- `stream/ftrd-stream`: the client (moonlight-common-c, fetched at build time): decodes on the
  Frame's hardware decoder, hands frames to Frametop's compositor as a Wayland window (zero copy),
  sends pointer and keys back. `stream/stream.sh` starts/stops instances, pairs, installs the
  menu entry. `stream/ftrd-presence.py` tells the PC where the panels are, signed with the
  pairing key.
- `host/ftrd-host.ps1`: the PC side (layout keeper).
- `probe/`: the decoder survey from the start of the project; `stream/diag/`: investigation tools.
- The project's history, measurements and decisions: `docs/handoff/` (milestones and dated logs).
