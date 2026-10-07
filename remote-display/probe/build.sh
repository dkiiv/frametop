#!/usr/bin/env bash
# Build ftrd-probe (the M0 decoder probe for the remote-display POC) in the dev container on
# the Frame: remote-display/probe/build/ftrd-probe. Runs in the container (it links SteamVR's
# libopenvr_api by rpath, like ft-screens). OpenVR header pinned to the same version as
# screens/build.sh, for IVRIPCResourceManagerClient (ImportDmabuf).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
"$root/scripts/sync.sh" >/dev/null
exec "$root/scripts/frame.sh" -C remote-display/probe 'set -e; mkdir -p build/include
openvr=v2.15.6
[ -f build/include/openvr-$openvr ] || { curl -fsSL "https://raw.githubusercontent.com/ValveSoftware/openvr/$openvr/headers/openvr.h" -o build/include/openvr.h && touch build/include/openvr-$openvr; }
g++ -std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers -DFTRD_VR -Ibuild/include \
  -DFTRD_GL $(pkg-config --cflags libdrm egl glesv2 gbm) -o build/ftrd-probe ftrd-probe.cpp \
  $(pkg-config --libs egl glesv2 gbm) \
  -L/opt/steamvr/bin/linuxarm64 -lopenvr_api -Wl,-rpath,/opt/steamvr/bin/linuxarm64
echo "built remote-display/probe/build/ftrd-probe"'
