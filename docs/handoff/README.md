# Remote-display POC — agent handoff

You are a Hermes agent picking up a side project on the user's WSL machine. This
directory is your briefing. Read all four files before touching code.

**Who you work for:** Curtis (dkiiv). Terse, decisive, hates faked progress.
Report honestly when blocked. He owns the Steam Frame and the Windows PC; you
never have either physically — the headset is his eyes, so anything visual needs
him to confirm it.

**What this project is:** prove that a Windows PC's desktop can be streamed over
the network into Frametop's VR displays on a Valve Steam Frame, as a panel that
behaves like Frametop's local screens. The Frametop dev is building this himself
(modified Sunshine streamer, "preliminary numbers" say it's doable); this POC is
Curtis's way of exploring it in parallel and being a useful beta partner. Do NOT
publish results publicly or open upstream issues/PRs about this without asking
Curtis first — it overlaps the dev's in-flight work.

**Files here:**

| File | Contents |
|---|---|
| `01-project-brief.md` | Goal, scope, non-goals, hard constraints |
| `02-environment.md` | Hosts, SSH, build container, repo layout |
| `03-technical-notes.md` | The display path, Sunshine/Moonlight protocol, decoder budget, verified facts vs open questions |
| `04-milestones.md` | M0–M5 plan with acceptance criteria; log progress in `log/` |

**Ground rules (from upstream AGENTS.md, binding here too):**

- The Frame may be in use. Never kill/restart `gamescope`, `steam`, `vrserver`,
  `vrcompositor`, or the Frametop desktop without asking Curtis first.
- No host `sudo`, no `steamos-readonly disable`, no reboots without explicit
  approval. The installers ask; you ask.
- Never copy `.netrc`, SSH keys, Steam config, or the `.env` password off the
  Frame or into any repo. Nothing secret gets committed, ever.
- Edit on the PC only; `scripts/sync.sh` overwrites `~/dev/frametop` wholesale.
- When you finish a work session, append a dated entry to `log/` and push it, so
  the next session (agent or human) can pick up cold.
