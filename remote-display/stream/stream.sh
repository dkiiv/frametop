#!/usr/bin/env bash
# Remote-display POC toggle: the Windows PC on the Frame, as a SteamVR overlay or as windows that
# float in Frametop panels. Several instances can run at once (one per paired client identity).
#   stream.sh on [-i N] [ftrd-stream options]   start instance N (default 1)
#   stream.sh off [N|all]                       stop instance N (default: all)
#   stream.sh status                            running instances + their last stats line
#   stream.sh log [N]                           follow instance N's log
#   stream.sh setup [PC address] [monitors]     first-time setup: build, pair, menu entry (remote-display/README.md)
#   stream.sh pair [-i N] PIN                   pair identity N (enter the PIN in Vibepollo's web UI)
#   stream.sh float [N]                         instance N as a Vibepollo "Remote Monitor" (a virtual
#                                               monitor on the PC) in its own Frametop panel; resizing
#                                               the panel resizes the monitor
#   stream.sh float-all                         every paired identity's monitor (the "Remote PC" entry)
#   stream.sh cleanup                           clear virtual monitors Vibepollo kept after release
#   stream.sh presence                          what the PC agent gets (monitor arrangement)
#   stream.sh install-desktop                   the desktop files ft-float launch needs
# Identity N: keys in ~/.config/frametop-remote-display (N=1) or .../N. Vibepollo gives each paired
# identity one virtual monitor.
# Works from the SteamOS host (enters the dev container) or inside it.
# Never touches SteamVR itself. Logs: ~/.cache/frametop-remote-display/stream-N.log
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../.." && pwd)
if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
  # First-time setup builds first (build.sh enters the container itself).
  if [ "${1:-}" = setup ] && [ ! -x "$here/build/ftrd-stream" ]; then
    echo "== building ftrd-stream (first time: a few minutes)"
    "$here/build.sh" || exit 1
  fi
  # The Frametop session moves XDG_RUNTIME_DIR to .../frametop; podman needs the real one.
  exec env XDG_RUNTIME_DIR=/run/user/$(id -u) "$HOME/.local/bin/distrobox" enter dev -- "$here/stream.sh" "$@"
fi
bin=$here/build/ftrd-stream
dir=$HOME/.cache/frametop-remote-display
mkdir -p "$dir"
conf=$HOME/.config/frametop-remote-display
pchost() { cat "$conf/host" 2>/dev/null; }  # the PC's address (stream.sh setup), else ftrd-stream's default
hostopt() { case " $* " in *" --host "*) ;; *) h=$(pchost); [ -n "$h" ] && echo "--host $h" ;; esac; }
keys() { if [ "$1" = 1 ]; then echo "$HOME/.config/frametop-remote-display"; else echo "$HOME/.config/frametop-remote-display/$1"; fi; }
pidof_i() { local p; p=$(cat "$dir/stream-$1.pid" 2>/dev/null) || return 1; kill -0 "$p" 2>/dev/null && echo "$p"; }
instances() { for f in "$dir"/stream-*.pid; do [ -e "$f" ] || continue; n=${f##*/stream-}; echo "${n%.pid}"; done; }

case ${1:-status} in
  on)
    shift
    n=1
    if [ "${1:-}" = -i ]; then n=$2; shift 2; fi
    [ -x "$bin" ] || { echo "not built: remote-display/stream/build.sh (from WSL)"; exit 1; }
    if pidof_i "$n" >/dev/null; then echo "instance $n already on"; exit 0; fi
    log=$dir/stream-$n.log
    # Window mode: the Frametop desktop's own Wayland socket (the nested KWin).
    case " $* " in *" --window"*)
      export WAYLAND_DISPLAY=${FTRD_WAYLAND:-/run/user/$(id -u)/frametop/wayland-0}
      [ -S "$WAYLAND_DISPLAY" ] || { echo "no Frametop desktop socket at $WAYLAND_DISPLAY"; exit 1; } ;;
    esac
    # shellcheck disable=SC2046
    FTRD_STATE_FILE=$dir/stream-$n.state setsid nohup "$bin" --keys "$(keys "$n")" $(hostopt "$@") "$@" >"$log" 2>&1 < /dev/null &
    echo $! > "$dir/stream-$n.pid"
    # The PC link (remote-display/host): answers the PC agent while any instance runs.
    if [ -f "$(keys 1)/key.pem" ] && ! pgrep -f ftrd-presence.py >/dev/null; then
      setsid nohup python3 "$here/ftrd-presence.py" >"$dir/presence.log" 2>&1 < /dev/null &
    fi
    for _ in $(seq 1 80); do
      sleep 0.25
      grep -q "connection started" "$log" && { echo "instance $n on (log: $log)"; exit 0; }
      pidof_i "$n" >/dev/null || { echo "instance $n failed to start:"; tail -5 "$log"; rm -f "$dir/stream-$n.pid"; exit 1; }
    done
    echo "instance $n starting... (see $log)"
    ;;
  off)
    which=${2:-all}
    [ "$which" = all ] && which=$(instances)
    [ -n "$which" ] || { echo "already off"; exit 0; }
    for n in $which; do
      p=$(pidof_i "$n") || { rm -f "$dir/stream-$n.pid"; continue; }
      kill -INT "$p"
      for _ in $(seq 1 60); do sleep 0.25; kill -0 "$p" 2>/dev/null || break; done
      if kill -0 "$p" 2>/dev/null; then kill -KILL "$p"; echo "instance $n off (had to kill)"; else echo "instance $n off"; fi
      rm -f "$dir/stream-$n.pid"
      grep -A7 "^RESULT" "$dir/stream-$n.log" 2>/dev/null | sed 's/^/  /'
    done
    ;;
  status)
    any=
    for n in $(instances); do
      if pidof_i "$n" >/dev/null; then any=1; echo "instance $n on: $(grep "^stats" "$dir/stream-$n.log" | tail -1)"; fi
    done
    [ -n "$any" ] || echo "off"
    ;;
  log) tail -f "$dir/stream-${2:-1}.log" ;;
  pair)
    shift; n=1
    if [ "${1:-}" = -i ]; then n=$2; shift 2; fi
    [ -n "${1:-}" ] || { echo "usage: stream.sh pair [-i N] PIN"; exit 2; }
    mkdir -p "$(keys "$n")"; chmod 700 "$(keys "$n")"
    # shellcheck disable=SC2046
    exec "$bin" --keys "$(keys "$n")" $(hostopt) --pair "$1" ;;
  setup)  # first-time setup: stream.sh setup [PC address] [monitors (1-4, default 2)]
    shift
    h=${1:-$(pchost)}; count=${2:-2}
    if [ -z "$h" ]; then
      if ping -c1 -W1 10.35.78.22 >/dev/null 2>&1; then h=10.35.78.22  # the PC end of Valve's USB Wi-Fi adapter
      else echo "usage: stream.sh setup PC-ADDRESS [MONITORS]   (the PC's IP address: ipconfig on the PC)"; exit 2; fi
    fi
    case $count in [1-4]) ;; *) echo "monitors: 1 to 4"; exit 2 ;; esac
    mkdir -p "$conf"; chmod 700 "$conf"; echo "$h" > "$conf/host"
    echo "== PC: $h"
    curl -sk --max-time 5 "https://$h:47984/serverinfo" >/dev/null 2>&1 || curl -s --max-time 5 "http://$h:47989/serverinfo" >/dev/null 2>&1 ||
      { echo "no Vibepollo answering at $h (is it installed and running? same network?)"; exit 1; }
    for n in $(seq 1 "$count"); do
      k=$(keys "$n")
      if [ -f "$k/uniqueid.dat" ] && "$bin" --keys "$k" --host "$h" --check >/dev/null 2>&1; then
        echo "== monitor $n: already paired"; continue
      fi
      pin=$(printf '%04d' $((RANDOM % 10000)))
      echo
      echo "== monitor $n: pair it. On the PC, open https://localhost:47990 -> PIN, enter $pin, name it \"Frame monitor $n\"."
      mkdir -p "$k"; chmod 700 "$k"
      "$bin" --keys "$k" --host "$h" --pair "$pin" | grep -v "^pairing:" || { echo "pairing failed; run stream.sh setup again"; exit 1; }
      if [ "$n" -gt 1 ]; then
        echo "   Vibepollo gives full rights only to the first device: in the web UI -> Clients, give"
        echo "   \"Frame monitor $n\" the Launch and input (mouse, keyboard) permissions too."
      fi
    done
    "$0" install-desktop >/dev/null
    echo
    echo "== done. In the headset: Steam button -> + -> Remote PC."
    echo "   On the PC, for monitors placed as on the Frame: ftrd-host.ps1 -Install (remote-display/host)." ;;
  float)  # ft-floatd floats the window whose app id matches the desktop file
    exec "$root/float/ft-float" launch "org.frametop.RemoteMonitor${2:-1}" ;;
  float-all)  # every paired identity's monitor, one after the other (the host starts one at a time)
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      pidof_i "$n" >/dev/null && continue
      "$root/float/ft-float" launch "org.frametop.RemoteMonitor$n"
      for _ in $(seq 1 60); do sleep 0.5; grep -q "connection started" "$dir/stream-$n.log" 2>/dev/null && break; done
    done ;;
  presence)
    if pgrep -f ftrd-presence.py >/dev/null; then echo "ftrd-presence running"; else echo "ftrd-presence not running"; fi
    tail -3 "$dir/presence.log" 2>/dev/null
    python3 -c "import importlib.util as u; s=u.spec_from_file_location('p', '$here/ftrd-presence.py'); m=u.module_from_spec(s); s.loader.exec_module(m); import json; print(json.dumps(m.snapshot(), indent=1))" ;;
  cleanup)  # Vibepollo 2.0.0 sometimes keeps a released virtual monitor (its ownership
    # bookkeeping); a short start + release by each paired identity clears it. Monitors flash.
    [ -z "$(for n in $(instances); do pidof_i "$n"; done)" ] || { echo "stop the streams first (stream.sh off)"; exit 1; }
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] && "$bin" --keys "$(keys "$n")" $(hostopt) --novr --app-id 2147483502 --seconds 1 >/dev/null 2>&1
    done
    sleep 4
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      "$bin" --keys "$(keys "$n")" $(hostopt) --novr --no-yield --app "Remote Monitor" --size 2560x1440 --seconds 3 2>&1 |
        grep -E "^app:|failed|released" | sed "s/^/identity $n: /"
      sleep 3
    done ;;
  install-desktop)  # ~/.local/share/applications
    # One entry in the menus: "Remote PC" (every paired monitor, each in its own panel). The
    # per-monitor files stay, hidden (NoDisplay), because ft-float launch floats a window by its
    # desktop file.
    apps=$HOME/.local/share/applications
    mkdir -p "$apps"
    rm -f "$apps"/org.frametop.RemoteMonitor*.desktop "$apps"/org.frametop.RemoteDisplay.desktop
    hidden() {  # name id command
      printf '[Desktop Entry]\nType=Application\nName=%s\nExec=sh -c "%s"\nIcon=preferences-desktop-remote-desktop\nTerminal=false\nStartupWMClass=%s\nNoDisplay=true\n' \
        "$1" "$3" "$2" > "$apps/$2.desktop"
    }
    s="$here/stream.sh"
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      hidden "Remote PC $n" "org.frametop.RemoteMonitor$n" \
        "$s on -i $n --window --app 'Remote Monitor' --size 2560x1440 --wl-id org.frametop.RemoteMonitor$n --title 'Remote PC $n'"
    done
    printf '[Desktop Entry]\nType=Application\nName=Remote PC\nComment=Your Windows PC'"'"'s virtual monitors, each in its own panel\nExec=sh -c "%s float-all"\nIcon=preferences-desktop-remote-desktop\nTerminal=false\nCategories=Network;RemoteAccess;\n' \
      "$s" > "$apps/org.frametop.RemotePC.desktop"
    echo "shown: Remote PC; hidden: $(cd "$apps" && grep -l NoDisplay=true org.frametop.Remote*.desktop | tr '\n' ' ')" ;;
  *) echo "usage: stream.sh on [-i N] [opts]|off [N|all]|status|log [N]|setup [PC] [N]|pair [-i N] PIN|float [N]|float-all|cleanup|install-desktop"; exit 2 ;;
esac
