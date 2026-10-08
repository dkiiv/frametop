# remote-display/host: the PC side (layout keeper)

`ftrd-host.ps1` runs on the Windows PC (Windows PowerShell 5.1, as the logged-in user, no admin).
Install: `powershell -ExecutionPolicy Bypass -File ftrd-host.ps1 -Install` (see ../README.md).

## What it does

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
- **Optionally removes a virtual monitor Vibepollo left behind** (after the Frame has reported
  no monitors for 30 s), with a Vibepollo API token in `vibepollo.token` (scope
  `POST /api/display/terminate_virtual`). Without the token it logs and leaves it.

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
ftrd-host.ps1 -Install        save the physical layout; run now and at every logon (Startup folder)
ftrd-host.ps1 -Uninstall      stop it and remove it from logon
ftrd-host.ps1 -SaveBaseline   save the current physical layout as the one to keep
ftrd-host.ps1 -Restore        put the saved physical layout back now
ftrd-host.ps1 -Status         displays, saved layout, agent, and what the Frame reports
```

Files: `%LOCALAPPDATA%\ftrd\` (`ftrd-host.ps1`, `baseline.json`, `frame.txt`, `vibepollo.token`,
`ftrd-host.log`). On the Frame, `stream.sh presence` shows what the agent gets.
