# remote-display/host: the PC side of the Frame link

`ftrd-host.ps1` runs on the Windows PC (PowerShell 5.1, as the logged-in user, no admin) and
asks `ftrd-presence` on the Frame (`remote-display/stream/ftrd-presence.py`, started by
`stream.sh on` whenever a link key is present) how the Frame's virtual monitors are arranged.

## What it does

- **Physical monitors stay on**, held at the saved baseline layout (Vibepollo 2.0.0 shuffles them
  on every virtual monitor start/stop; it doesn't remember the layout).
- **Virtual monitors always sit right of the physical ones**, top-aligned. Moving one elsewhere
  (Display Settings, Vibepollo) gets it put back within a few seconds.
- **Their order follows the Frame.** Every 2 s the agent asks the Frame (UDP 47810: the dongle
  link first, then home Wi-Fi). The Frame answers while a remote-display instance runs, with one
  entry per virtual monitor: its client certificate's SHA-256, stream size, and where its panel
  floats around you (azimuth / elevation from ft-screens). Each entry is matched to a Windows
  display (certificate -> Vibepollo pairing -> the display Vibepollo made for it, from its log;
  stream size as a fallback). Panels become columns left to right by azimuth; panels within 12
  degrees of each other stack, the higher one on top. So a panel left of another is left of it
  in Windows, and windows drag across as they look. Without panel poses (ft-floatd older than
  `list apps`) the monitors make a row in instance order; with no answer at all, the last known
  order is kept (virtual monitors it never heard of keep their current left-to-right order).
- Answers are HMAC-SHA256-signed with a shared key over the agent's random nonce; the agent
  ignores anything else.

Nothing here switches monitors off, and a silent Frame changes nothing: no answer just means the
arrangement stays as it is.

## Setup

1. Copy `ftrd-host.ps1` to the PC (e.g. `C:\ProgramData\ftrd\`).
2. With the physical monitors arranged as you like: `ftrd-host.ps1 -Setup` (makes
   `%LOCALAPPDATA%\ftrd\link.key`, saves `baseline.json`). Re-save later with `-SaveBaseline`.
3. Copy the key to the Frame: `~/.config/frametop-remote-display/link.key` (mode 600).
4. Start it at logon: a Startup-folder shortcut to
   `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\ftrd\ftrd-host.ps1" -Run`.

`ftrd-host.ps1 -Status` shows the displays, the baseline and the Frame's answer; `-Restore` puts
the physical monitors back at the baseline now. Log: `%LOCALAPPDATA%\ftrd\ftrd-host.log`.
On the Frame, `stream.sh presence` shows what the agent gets.
