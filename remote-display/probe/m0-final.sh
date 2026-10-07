#!/usr/bin/env bash
# M0 sign-off run: decoded frames converted to ABGR8888 on the GPU (--rgb), shown on an overlay,
# headset worn, passthrough on. Run in the dev container on the Frame
# (from WSL: scripts/frame.sh -C remote-display/probe ./m0-final.sh). Saved to ~/.cache/ft-m0/final-<time>.txt.
#
# Schedule (about 2.5 min; panels appear 1.2 m ahead, gone ~3 s between):
#   1  idle baseline, nothing on screen          20 s
#   A  panel: HEVC 1080p60 -> GPU RGB            30 s
#   B  panel: H.264 1080p60 -> GPU RGB           30 s
#   C  panel: HEVC 4K60 -> GPU RGB (stress)      30 s
#   2  idle again                                20 s
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
F=$HOME/.cache/ft-m0
P=build/ftrd-probe
out=$F/final-$(date +%Y%m%d-%H%M%S).txt
[ -x "$P" ] || { echo "build first: remote-display/probe/build.sh" >&2; exit 1; }
for f in fa_hevc_1080.hevc fb_h264_1080.h264 fc_hevc_2160.hevc; do
  [ -f "$F/$f" ] || { echo "missing $F/$f" >&2; exit 1; }
done
step() {  # step NAME "what" seconds args...  (each step is time-boxed so a hang can't stall the run)
  local n=$1 what=$2 secs=$3; shift 3
  printf '\n===== STEP %s  %s  (%s)\n' "$n" "$what" "$(date +%T)"
  timeout -s INT -k 5 "$secs" "$P" "$@" 2>&1 | grep -vE '^(output|capture: decoder|dmabuf: VIDIOC|vr: SteamVR takes)'
  sleep 3
}
{
  echo "M0 final run $(date -Is) on $(uname -n)"
  step 1 "idle baseline" 30 --idle 20
  step A "panel HEVC 1080p -> RGB" 45 "$F/fa_hevc_1080.hevc" --fps 60 --rgb --show
  step B "panel H264 1080p -> RGB" 45 "$F/fb_h264_1080.h264" --fps 60 --rgb --show
  step C "panel HEVC 4K -> RGB" 45 "$F/fc_hevc_2160.hevc" --fps 60 --rgb --loops 3 --show
  step 2 "idle recovery" 30 --idle 20
  echo; echo "done $(date +%T)"
} 2>&1 | tee "$out"
echo "saved $out"
