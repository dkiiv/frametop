# remote-display/host: the PC side (install, pairing, layout keeper)

`ftrd-host.ps1` runs on the Windows PC (Windows PowerShell 5.1, as the logged-in user).
Install with the one-liner in ../README.md (`install.ps1` downloads `ftrd-host.ps1` into
`%LOCALAPPDATA%\ftrd` and runs `-Install`).

## -Install

1. Vibepollo 2.0.0, if missing: downloaded from its GitHub release, checked against its SHA-256,
   installed silently (`/quiet`; the one UAC prompt).
2. A login for Vibepollo's web page, if it has none yet (user `admin`, a random password, shown
   once and kept encrypted for `-ShowLogin`); with an existing login, it asks for it once. With
   it, an API token for this helper only, scoped to `POST /api/pin`, `GET /api/clients/list`,
   `POST /api/clients/update` and `POST /api/display/terminate_virtual`; kept encrypted for this
   Windows user (DPAPI). The login itself isn't kept unless this script made it.
3. The current physical layout saved as the one to keep; the helper started now and at every
   logon (Startup folder); pairing open for 30 minutes.

## Pairing

`stream.sh setup` on the Frame starts a Moonlight pairing request with a random PIN and has
`ftrd-presence` answer this helper's pings with `FTRD2-PAIR {name, pin}`. The helper gives that
PIN to Vibepollo (`/api/pin`), without asking while pairing is open (30 minutes after `-Install`,
15 after `-AllowPairing`), otherwise after a Yes in a window on the PC's screen. Vibepollo gives
full rights only to the first device it pairs, so the helper then adds list/view/launch, mouse,
keyboard and controller to the new device (`/api/clients/update`). Before pairing nothing can be
signed, so the PIN request itself isn't authenticated: that's why it's only automatic in the
window right after you ran the installer.

## What it does while running

- **Keeps your physical monitors as you set them up.** `-Install` saves their layout
  (`baseline.json`); whenever Vibepollo 2.0.0 shuffles them (it does at every virtual monitor
  start/stop) or drops the refresh rate, the agent puts them back. It never switches a monitor
  on or off.
- **Puts the virtual monitors to the right of the physical ones**, top-aligned, in the order of
  the Frame's panels: columns left to right by direction, panels above each other stacked.
  Moving a virtual monitor elsewhere in Display Settings gets it put back.
- **Waits for things to settle.** A new arrangement is taken once the panels have stood still
  for 4 s, and only when clear-cut (neighbouring panels at least 8 degrees apart; turning your
  head changes nothing). Windows is changed only when its displays have been unchanged for 5 s
  and no monitor is starting or resizing, and only for what differs (usually one monitor's
  position).
- **Has the Frame release a virtual monitor Vibepollo left behind**: when the Frame reports no
  monitors but one is still attached (3 s, displays settled), its pings say `FTRD2 PING <nonce>
  leftover`, and the Frame's ftrd-presence (which answers for 20 s after the last monitor
  closes) runs `stream.sh cleanup` once: a short start + release per identity. Not Vibepollo's
  `terminate_virtual`: that also shuts its virtual display driver down until the service
  restarts.
- **Starts without a window**: the Startup shortcut runs it through `conhost.exe --headless`
  (`powershell -WindowStyle Hidden` alone leaves an empty window where Windows Terminal is the
  default console).

## The link to the Frame

Every second the agent asks the Frame (UDP 47810) what it shows. `ftrd-presence` on the Frame
(started by `stream.sh` with the first monitor, gone a few seconds after the last) answers with
one entry per monitor: its pairing certificate's hash, size, and the panel's direction and
height from where you are. The answer is signed (RSA-SHA256 over the agent's random nonce and
the answer) with the Frame's Vibepollo pairing key, and the agent checks it against the
certificate Vibepollo already trusts, so there's nothing to copy between the two and nothing
else on the network can move your displays. The Frame is found by broadcasting on the PC's
networks and remembered (`frame.txt`); `-Frame ADDRESS` overrides. No answer just means "keep
things as they are". Each entry is matched to its Windows display through Vibepollo's pairing
list and log (the stream size as a fallback).

## Commands

```
ftrd-host.ps1 -Install        everything above
ftrd-host.ps1 -AllowPairing   let a Frame pair without asking, for 15 minutes
ftrd-host.ps1 -ShowLogin      the Vibepollo web page login -Install made
ftrd-host.ps1 -Uninstall      remove this helper and its data; asks about Vibepollo (-RemoveVibepollo)
ftrd-host.ps1 -SaveBaseline   save the current physical layout as the one to keep
ftrd-host.ps1 -Restore        put the saved physical layout back now
ftrd-host.ps1 -Status         displays, saved layout, agent, and what the Frame reports
```

Files: `%LOCALAPPDATA%\ftrd\` (`ftrd-host.ps1`, `baseline.json`, `frame.txt`, `pair-until`,
`vibepollo.token.dpapi`, `vibepollo-login.dpapi`, `ftrd-host.log`). On the Frame, `stream.sh presence` shows what the agent gets.
