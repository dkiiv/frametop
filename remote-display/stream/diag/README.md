# remote-display/stream/diag: tools from the POC's investigations

Not needed to use Remote PC. Kept because the logs in docs/handoff/log refer to them.

- `hitprobe.cpp`: casts rays at a `frametop.float.N` panel's bottom edge and reports where
  SteamVR hits it (found the grab bar's oversized hit box; M4).
- `hitaspect.cpp`: throwaway overlay showing that SteamVR hit-tests by mouse scale, not texture
  shape (M4).
- `https-probe.sh`: polls the host's HTTPS port while a stream runs (found libgamestream's kept-open
  TLS connection that stalled Vibepollo for every other client; M4).
- `multi-test.sh`: two Remote Monitors at once from two paired identities, with timings (M4).

Build the .cpp tools in the dev container like ftrd-stream (openvr.h from build/include, link
SteamVR's libopenvr_api); the scripts run in the dev container from this directory.
