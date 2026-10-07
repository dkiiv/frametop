#!/usr/bin/env bash
# Remote-display POC (M2) toggle: show the Windows PC's desktop as a SteamVR panel.
#   stream.sh on [ftrd-stream options]   start (panel appears 1.5 m ahead, where you're facing)
#   stream.sh off                        stop cleanly (panel gone, Sunshine session ended)
#   stream.sh status                     running? + the last stats line
#   stream.sh log                        follow the log
#   stream.sh pair PIN                   one-time pairing (enter PIN in Sunshine's web UI)
# Works from the SteamOS host (enters the dev container) or inside it. Never touches SteamVR
# itself: stopping only removes our overlay. Log: ~/.cache/frametop-remote-display/stream.log
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
  exec "$HOME/.local/bin/distrobox" enter dev -- "$here/stream.sh" "$@"
fi
bin=$here/build/ftrd-stream
dir=$HOME/.cache/frametop-remote-display
log=$dir/stream.log
mkdir -p "$dir"
running() { pgrep -x ftrd-stream >/dev/null; }

case ${1:-status} in
  on)
    shift
    [ -x "$bin" ] || { echo "not built: remote-display/stream/build.sh (from WSL)"; exit 1; }
    if running; then echo "already on"; exit 0; fi
    setsid nohup "$bin" "$@" >"$log" 2>&1 < /dev/null &
    for _ in $(seq 1 40); do
      sleep 0.25
      grep -q "connection started" "$log" && { echo "on (log: $log)"; exit 0; }
      running || { echo "failed to start:"; tail -5 "$log"; exit 1; }
    done
    echo "starting... (see $log)"
    ;;
  off)
    running || { echo "already off"; exit 0; }
    pkill -INT -x ftrd-stream
    for _ in $(seq 1 40); do sleep 0.25; running || break; done
    if running; then pkill -KILL -x ftrd-stream; echo "off (had to kill)"; else echo "off"; fi
    grep -A6 "^RESULT" "$log" 2>/dev/null
    ;;
  status)
    if running; then echo "on"; grep "^stats" "$log" | tail -1; else echo "off"; fi
    ;;
  log) tail -f "$log" ;;
  pair) [ -n "${2:-}" ] || { echo "usage: stream.sh pair PIN"; exit 2; }; exec "$bin" --pair "$2" ;;
  *) echo "usage: stream.sh on|off|status|log|pair PIN"; exit 2 ;;
esac
