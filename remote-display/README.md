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

You need a Steam Frame and a Windows 10/11 PC with a GPU that can encode HEVC (NVIDIA, AMD or
Intel), on the same network. Valve's USB Wi-Fi adapter for the PC gives the lowest latency (about
3 ms here), but home Wi-Fi works.

## Set it up (once): from the PC

### 1. On the PC (a few minutes)

Open PowerShell (Start → type `powershell` → Enter) and paste:
```
irm https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/host/install.ps1 | iex
```
Click **Yes** when Windows asks. It installs [Vibepollo](https://github.com/Nonary/Vibepollo)
2.0.0 (the streaming host: a Sunshine fork that makes a virtual monitor per device; it replaces
Sunshine if you have it), and a small Remote PC helper that pairs the Frame for you and keeps
your monitor layout in order. It shows the login it made for Vibepollo's own settings page; you
rarely need it (`ftrd-host -ShowLogin` in PowerShell shows it again). Arrange your physical monitors the
way you like them before you run it: that's the layout the helper keeps.

### 2. On the Frame, from the PC over SSH (about 15 minutes, mostly downloading)

Everything on the Frame runs from the PC's PowerShell over SSH (Windows 10/11 has `ssh`
built in), so you only put the headset on at the end.

**Once, in the headset: turn SSH on.** No commands needed: in Steam's settings, turn on
developer mode; then, in the developer settings, set the account password. That turns SSH on;
log in as `steamos` with that password. You also need the Frame's address, `FRAME` below: its IP
address on your Wi-Fi (the network's details in Steam's settings, or your router's list of
devices), or `HOSTNAME.local` with the Frame's hostname (Windows finds that on the local network).
Keep the Frame on its charger or stand while installing: it goes to sleep after a while without
input (after the install, Frametop Display Settings → Power can keep it awake while plugged in).

**Install Frametop with Remote PC:**
```
ssh -t steamos@FRAME "curl -fsSL https://raw.githubusercontent.com/dkiiv/frametop/remote-display-poc-handoff/remote-display/get.sh | bash"
```
Enter the `steamos` password, then press Enter at the installer's questions to take the
defaults; at the end, answer **y** to restart SteamVR. It's the same installer as Frametop's own
(see the main [README](../README.md) for what the questions mean). The `-t` matters: without it
the questions can't reach you. If the connection drops or something fails, run the same line
again; it picks up where it stopped.

**Pair** (within 30 minutes of step 1):
```
ssh -t steamos@FRAME "~/frametop/remote-display/stream/stream.sh setup"
```
It finds your PC and pairs two monitors with it (`setup 3` for three, up to 4), nothing to type:
within 30 minutes of step 1 the PC agrees by itself. Later, the PC asks first (a window on its
screen: click Yes; or run `ftrd-host -AllowPairing` before).

### 3. In the headset

Launch a program → Desktop, then Steam button → **+** → **Remote PC**: your monitors open.
(Skipped the pairing above? Then the first click on Remote PC opens a window that does it.)

To type, map a controller button to Frametop's keyboard in Frametop Input Settings (any button
but the system "..." button, which belongs to SteamVR).

## Use it

- **Open:** Steam button → **+** → **Remote PC**. Your monitors open one after the other, each
  in its own panel (a dark panel first, the picture a few seconds later).
- **Arrange:** move the panels where you want them. About 10 seconds after you let go, Windows
  rearranges its virtual monitors to match (left/right, and above/below for stacked panels);
  your screens may blink once.
- **Main display:** to make a virtual monitor Windows' main display, use Windows' own Settings →
  Display → "Make this my main display". It stays the main display (also when the monitor is
  re-made after a resize or a VR game) until you pick another one; when you close it, Windows
  goes back to your physical one.
- **Resize:** resize a panel; once you let go, the picture freezes for about 5 seconds while
  the PC's monitor changes size.
- **VR games:** when a VR game starts, the panels step aside (the stream pauses, the PC keeps
  the monitors and their windows); they come back a second or two after the game ends.
- **Close:** close the panels. The virtual monitors disappear from Windows, and windows on them
  move to your physical monitors.

Moving windows from your physical monitors onto a virtual one: Win+Shift+Left/Right, or drag.
After a reboot of either device nothing needs redoing: open Remote PC again (the PC has to be on
and logged in).

## When something's off

- **"Can't find your PC":** Remote PC looks for the PC you paired every time it opens (where it
  was last time, on the Frame's own hotspot, by network discovery, then by a quick scan), so a
  new address doesn't matter. This means the PC is off or asleep, Vibepollo isn't running, or the
  two aren't on the same network.
- **Your physical monitors are rearranged or at a lower refresh rate:** Vibepollo 2.0.0 shuffles
  them when virtual monitors come and go; the helper puts them back within seconds. After
  changing your layout on purpose: `ftrd-host -SaveBaseline`.
- **A virtual monitor stays in Windows after you closed everything** (Vibepollo 2.0.0 sometimes
  keeps one, listed as screen 3, 4...): `ssh -t steamos@FRAME ~/frametop/remote-display/stream/stream.sh cleanup`
  releases each monitor. Don't use Vibepollo's "terminate virtual displays" for it: that also
  stops its display driver, and every Remote PC monitor then fails ("The composed display
  topology did not apply") until Vibepollo's service is restarted (Services → Vibepollo /
  ApolloService → Restart, or restart the PC).
- **Physical monitors dark:** Win+P → Extend. (This happened with Vibepollo's "Desktop" app, which
  makes its virtual screen the only display; Remote PC never starts that app.)
- **A panel stays dark:** `ssh steamos@FRAME ~/frametop/remote-display/stream/stream.sh status`
  (and `... stream.sh log 1`) shows what the stream is doing; on the PC,
  `ftrd-host -Status` shows the displays and what the Frame reports, and
  `%LOCALAPPDATA%\ftrd\ftrd-host.log` what the helper did.
- **Set up again** (another PC, more monitors): the pairing line above again (`setup 3` for
  three monitors, up to 4; `setup ADDRESS` if your network blocks discovery).

## Uninstall

- **PC:** in PowerShell, `ftrd-host -Uninstall` (it asks whether
  to remove Vibepollo too).
- **Frame:** Frametop's uninstaller removes Remote PC with it: `ssh -t steamos@FRAME
  ~/frametop/uninstall.sh`, restart the headset, run it again (see [Uninstall](../README.md#uninstall)
  in the main README).

## Limits (for now)

- No sound (it stays on the PC).
- Stepping aside for VR games is tested only with a simulated game so far.
- Frametop's keyboard doesn't open by itself when you click a text field on the PC; use the
  mapped button.
- One paired device per virtual monitor, up to 4 (Vibepollo).
- Vibepollo 2.0.0 shuffles the physical monitors at each virtual monitor start/stop (the helper
  puts them back) and its first start sometimes fails and is retried, so opening takes a few
  seconds and your screens blink.

## How it fits together

- `stream/ftrd-stream`: the client (moonlight-common-c, fetched at build time): decodes on the
  Frame's hardware decoder, hands frames to Frametop's compositor as a Wayland window (zero copy),
  sends pointer and keys back. `stream/stream.sh` starts/stops instances, sets up and pairs,
  installs the menu entry. `stream/ftrd-find-pc.py` finds the paired PC. `stream/ftrd-presence.py`
  answers the PC helper: the panels' positions (signed with the pairing key) and, during setup,
  the pairing PIN.
- `host/ftrd-host.ps1`: the PC side (install, pairing, layout keeper); `host/install.ps1` is the
  one-liner's bootstrap. Details: [host/README.md](host/README.md).
- `get.sh`: the Frame's one-liner (clone this branch, run install.sh, which builds Remote PC).
- `probe/`: the decoder survey from the start of the project; `stream/diag/`: investigation tools.
- The project's history, measurements and decisions: `docs/handoff/` (milestones and dated logs).
