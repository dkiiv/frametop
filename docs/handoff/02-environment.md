# 02 — Environment

You (the agent) run on **Curtis's WSL machine**. The Frame is reached over SSH.
Nothing here is secret except the Frame password, which lives in
`~/frametop/.env` (`steamos_root_pwd=...`) and must never be committed, logged,
or copied anywhere else.

## Hosts

| Host | What it is | How you reach it |
|---|---|---|
| `DESKTOP-5GH4MUU` (WSL2, Ubuntu) | Your home. Repo checkout, editing, builds are orchestrated from here. | you live here |
| `frame` (10.0.0.253) | Valve Steam Frame, SteamOS (VR variant), aarch64, dev mode on, sshd on. | `ssh frame` (alias in `~/.ssh/config`, key `~/.ssh/id_ed25519`) |
| Windows PC | The stream **source** (Sunshine goes here). Same LAN. Not set up yet. | TBD — Curtis sets up SSH or runs commands himself |

Note: `ssh frame '<cmd>'` is non-interactive; `~/.local/bin` is NOT on PATH, so
`distrobox`/`podman` need `PATH=$HOME/.local/bin:$PATH` in the command string.

## Repos

- Upstream: `https://github.com/DeeJanuz/frametop` (MIT). Active daily.
- Curtis's fork: `https://github.com/dkiiv/frametop`. This handoff lives on its
  `remote-display-poc-handoff` branch.
- WSL checkout: `~/frametop` (cloned from upstream). Set up the fork:
  ```
  cd ~/frametop
  git remote add fork https://github.com/dkiiv/frametop.git
  git fetch fork
  git checkout remote-display-poc-handoff   # this branch
  ```
- Frame copy: `~/dev/frametop` — a one-way mirror of the WSL checkout via
  `scripts/sync.sh`. **Edit on WSL only.** The Frame's Frametop install itself
  lives at `~/frametop` on the Frame (installed by `install.sh` from WSL).

## The Frame at a glance (what Frametop gives you)

- `dev` distrobox (Fedora 44 toolbox, aarch64) = the only build environment.
  Enter: `ssh frame 'PATH=$HOME/.local/bin:$PATH distrobox enter dev -- <cmd>'`.
  Package list / source of truth: `setup/dev-container.sh`.
- Frametop desktop: nested KWin inside `ft-screens` (wlroots compositor), each
  KWin window shown as a SteamVR panel. Session: `session/frametop-session.sh`.
- Existing remote path (the baseline you're beating): `session/remote-desktop.sh`
  + `session/vnc-bridge.sh` — krdp captures KWin, H.264 **software-encoded**
  (~60% of a core), re-served as VNC. Read these before designing the new path.
- Diagnostics: `scripts/doctor.sh`, `scripts/report.sh` (writes a redacted
  report file), `journalctl --user` for the `frametop-*` services.

## Frametop dev workflow (from AGENTS.md — binding)

```
scripts/doctor.sh                  # is the Frame reachable and ready?
scripts/sync.sh                    # WSL -> ~/dev/frametop (one-way, --delete)
scripts/frame.sh '<cmd>'           # run in the dev container on the Frame
scripts/frame.sh -C <dir> '<cmd>'  # same, in a repo subfolder
scripts/frame.sh --host '<cmd>'    # run on the SteamOS host
```

- Host has read-only root, no compilers. Container-built binaries run **in the
  container**; only the SteamVR driver is built to run on the host
  (`pointer/driver/build.sh` shows how: static libstdc++, older-glibc target).
- Container packages you add must go into `setup/dev-container.sh`'s list.
- Program names ≤ 15 chars (pgrep -x truncates at 15).
- Never copy `.netrc`, SSH keys, or Steam config off the Frame.

## Working agreement with Curtis

- He wears the headset; you never see it. Ask him to run the toggle and report;
  instrument the client so "it felt laggy" becomes "median frame age 41 ms,
  3 drops in 10 s".
- Ask before: restarting SteamVR/vrserver/gamescope/steam/desktop, host sudo,
  anything that puts the headset in a weird state while he's wearing it.
- After every session: append `log/YYYY-MM-DD-<slug>.md` (what you did, what
  broke, what's next), commit, push to the fork. He (or the next agent) reads
  `log/` newest-first to resume.
