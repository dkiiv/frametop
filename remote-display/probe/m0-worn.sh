#!/usr/bin/env bash
# M0 worn-headset run: decoder load + overlay display while passthrough is on.
# Run in the dev container on the Frame (from WSL: scripts/frame.sh -C remote-display/probe ./m0-worn.sh).
# Test streams live in ~/.cache/ft-m0 (made on WSL; see docs/handoff/log). Every step prints a
# RESULT block; the whole run is also saved to ~/.cache/ft-m0/worn-<time>.txt.
#
# Schedule (about 3.5 min; a panel appears 1.2 m ahead in steps 3-6, gone between steps):
#   1  idle baseline, nothing on screen                         30 s
#   2  H.264 1080p60 decode, nothing on screen (decoder load)   30 s
#   3  panel: HEVC 1080p60, NV12 linear                         30 s
#   4  panel: H.264 1080p60, Q08C (UBWC)                        30 s
#   5  panel: H.264 1080p60, AB24 as UBWC (may be garbage)      30 s
#   6  panel: HEVC 4K60, NV12 linear (stress)                   30 s
#   7  idle again (recovery)                                    30 s
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
F=$HOME/.cache/ft-m0
P=build/ftrd-probe
out=$F/worn-$(date +%Y%m%d-%H%M%S).txt
[ -x "$P" ] || { echo "build first: remote-display/probe/build.sh" >&2; exit 1; }
for f in h264_1080p60_20M.h264 s3_hevc_1080.hevc s4_h264_1080.h264 s5_h264_1080.h264 s6_hevc_2160.hevc; do
  [ -f "$F/$f" ] || { echo "missing $F/$f" >&2; exit 1; }
done

step() {  # step N "what" args...
  local n=$1 what=$2; shift 2
  printf '\n===== STEP %s  %s  (%s)\n' "$n" "$what" "$(date +%T)"
  "$P" "$@" 2>&1 | grep -vE '^(output|capture: decoder|dmabuf: VIDIOC)'
  sleep 3
}
{
  echo "M0 worn run $(date -Is) on $(uname -n)"
  step 1 "idle baseline" --idle 30
  step 2 "decode only, no panel" "$F/h264_1080p60_20M.h264" --fps 60 --vr
  step 3 "panel HEVC NV12" "$F/s3_hevc_1080.hevc" --fps 60 --fmt nv12 --show
  step 4 "panel H264 Q08C" "$F/s4_h264_1080.h264" --fps 60 --fmt q08c --show
  step 5 "panel H264 AB24-as-UBWC" "$F/s5_h264_1080.h264" --fps 60 --fmt ab24 --mod ubwc --show
  step 6 "panel HEVC 4K NV12" "$F/s6_hevc_2160.hevc" --fps 60 --fmt nv12 --loops 3 --show
  step 7 "idle recovery" --idle 30
  echo; echo "done $(date +%T)"
} 2>&1 | tee "$out"
echo "saved $out"
