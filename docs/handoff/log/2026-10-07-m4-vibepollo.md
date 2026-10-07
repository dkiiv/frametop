# 2026-10-07 — M4 part 2: Vibepollo host, virtual displays — one works, two at once don't (yet)

Done:
- PC host is now **Vibepollo 2.0.0** (installed by Curtis, replaced Sunshine; same install dir
  C:\Program Files\Sunshine, service "ApolloService"; web UI https://localhost:47990).
  Vibepollo adds two apps: "Remote Monitor" (a per-client virtual display at the client's
  requested size) and "Remote Input".
- Pairing: two client identities on the Frame (a Vibepollo virtual display is per paired
  client): `~/.config/frametop-remote-display` (steamFrame) and `.../2` (steamFrame-2,
  `--keys`). NOTE: Vibepollo gives full permissions only to the first paired client; later
  ones get list+view only (Launch and input must be granted in the web UI, Clients page).
  steamFrame-2 now has list/view/launch, no input.
- ftrd-stream: `--app "Remote Monitor"` releases this client's retained monitor first
  (Vibepollo keeps it after the stream and then lists only "Resume"/"Disconnect Monitor";
  Resume can't change the size), clears libgamestream's currentGame (else it "resumes"), and
  launches afresh at `--size`. `--app-id N` launches a hidden control (e.g. 2147483502 =
  Disconnect Monitor). An unknown `--app` prints the host's list.
- stream/multi-test.sh: two identities, timestamped milestones (A1=Desktop for a primary
  game stream).

Measured:
- Remote Monitor, one client: Windows gets a new virtual monitor (DISPLAY33/34) beside the
  physical ones at exactly the requested size: 2560x1440 -> 2.4 ms host, 1920x1080 -> 1.6 ms;
  0 lost. Re-request at a new size (release + launch) ~3 s to first frame. Physical layout
  untouched (moved temporarily during one run, restored at the end).
- Two at once: **did not work**. Both RM+RM and Desktop+RM: the second client blocks in
  gs_init until the first stream ends, then starts (so displays exist side by side only
  sequentially). While any stream runs, the host's HTTPS port 47984 doesn't answer curl at
  all (15 s timeouts, even for the streaming client; plain HTTP 47989 answers in 50 ms). The
  release notes say up to 4 Moonlight clients should work as Remote Monitors beside a primary
  stream; unknown whether this is moonlight-embedded-specific or a 2.0.0 regression.
- **Incident (13:41-13:52)**: Desktop (identity 1, 2560x1440) + Remote Monitor (identity 2)
  left Vibepollo believing a client display session was still owned: it made its virtual
  display the *only* Windows display (physical monitors off) and its recovery monitor re-applied
  that every ~12 s, even after both clients disconnected. Recovery: SetDisplayConfig(EXTEND)
  every 2 s (a hidden keeper script) to keep the physical screens visible, an elevated
  `Restart-Service ApolloService` (Curtis clicked UAC), then the small monitor moved back to
  (1622,1440). Final layout verified: 5120x1440 primary at 0,0, 1920x1080 at 1622,1440.
  Lesson: don't run the "Desktop" app at a non-native size together with Remote Monitor
  clients; Desktop at another size switches Windows to a virtual display exclusively.

Open:
- Multiple simultaneous virtual displays (Curtis's requirement) blocked on the host. Options:
  report to Vibepollo upstream (logs need scrubbing: client UUIDs, device IDs, host name);
  try Nonary's Moonlight fork / moonlight-qt from the Frame to see if the stall is client-side;
  fall back to one virtual display per stream sequentially.
- Remote-monitor retention: `remote_monitor_disconnect_on_stream_end` (Vibepollo setting)
  would make the release step unnecessary.
