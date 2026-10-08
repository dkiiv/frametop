# remote-display/host: the PC side of the Frame link

`ftrd-host.ps1` runs on the Windows PC (PowerShell 5.1, as the logged-in user, no admin) and
talks to `ftrd-presence` on the Frame (`remote-display/stream/ftrd-presence.py`, started by
`stream.sh on` whenever a link key is present).

## What it does

- **Heartbeat.** Every second the agent pings the Frame (UDP 47810: the dongle link first, then
  home Wi-Fi). The Frame answers only while at least one remote-display instance runs, with one
  entry per virtual monitor: its client certificate's SHA-256, stream size, and where its panel
  floats around you (azimuth / elevation from ft-screens). Answers are signed with a shared key
  (HMAC-SHA256 over the agent's random nonce and the reply), so nothing else on the network can
  drive the PC's displays.
- **Arrangement.** Each entry is matched to a Windows display (certificate -> Vibepollo pairing
  -> the display Vibepollo made for it, from its log; stream size as a fallback). Panels become
  columns left to right by azimuth; panels within 12 degrees of each other stack, the higher one
  on top. So a panel left of another is left of it in Windows, and windows drag across as they
  look. Without panel poses (ft-floatd older than `list apps`), the monitors make a row in
  instance order.
- **Observe mode (default).** Physical monitors stay on, at the saved baseline layout (which also
  undoes Vibepollo 2.0.0's layout shuffling); the virtual monitors sit right of them, arranged as
  above.
- **Control mode** (`-Control`, or a file `control.on` in the data folder). While the Frame shows
  monitors, the physical monitors are taken off the desktop and the virtual monitor nearest
  straight ahead becomes the primary, so every window is on a monitor you can see from the Frame.
- **Fail-safe.** No answer for `TimeoutSeconds` (5 s), or the Frame reporting no monitors: the
  physical monitors come back at the baseline layout, and (with an API token) Vibepollo is asked
  to remove its virtual monitors. A guard process restores them too if the agent itself dies
  while they're off; at its next start the agent restores if it finds them off. Win+P -> Extend
  brings them back whatever happens.

## Setup

1. Copy `ftrd-host.ps1` to the PC (e.g. `C:\ProgramData\ftrd\`).
2. With the physical monitors arranged as you like: `ftrd-host.ps1 -Setup` (makes
   `%LOCALAPPDATA%\ftrd\link.key`, saves `baseline.json`). Re-save later with `-SaveBaseline`.
3. Copy the key to the Frame: `~/.config/frametop-remote-display/link.key` (mode 600).
4. Start it at logon: a Startup-folder shortcut to
   `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\ftrd\ftrd-host.ps1" -Run`.
5. Optional: a Vibepollo API token (web UI, API tokens; scope `POST /api/display/terminate_virtual`)
   in `%LOCALAPPDATA%\ftrd\vibepollo.token`, so a vanished Frame's virtual monitors go too.

`ftrd-host.ps1 -Status` shows the displays, the baseline, the mode and the Frame's answer;
`-Restore` gives the physical monitors back now. Log: `%LOCALAPPDATA%\ftrd\ftrd-host.log`.
On the Frame, `stream.sh presence` shows what the agent gets.
