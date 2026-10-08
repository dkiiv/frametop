#!/usr/bin/env bash
# Remote-display POC toggle: the Windows PC on the Frame, as a SteamVR overlay or as windows that
# float in Frametop panels. Several instances can run at once (one per paired client identity).
#   stream.sh on [-i N] [ftrd-stream options]   start instance N (default 1)
#   stream.sh off [N|all]                       stop instance N (default: all)
#   stream.sh status                            running instances + their last stats line
#   stream.sh log [N]                           follow instance N's log
#   stream.sh pair [-i N] PIN                   pair identity N (enter the PIN in Vibepollo's web UI)
#   stream.sh float [N]                         instance N as a Vibepollo "Remote Monitor" (a virtual
#                                               monitor on the PC) in its own Frametop panel; resizing
#                                               the panel resizes the monitor
#   stream.sh float-all                         every paired identity's monitor (the "Remote PC" entry)
#   stream.sh float-desktop                     the PC's own desktop (its physical monitors), floating
#   stream.sh cleanup                           clear virtual monitors Vibepollo kept after release
#   stream.sh presence                          what the PC agent gets (monitor arrangement)
#   stream.sh install-desktop                   the desktop files ft-float launch needs
# Identity N: keys in ~/.config/frametop-remote-display (N=1) or .../N. Vibepollo gives each paired
# identity one virtual monitor. Instance "desktop" (float-desktop) uses identity 1.
# Works from the SteamOS host (enters the dev container) or inside it.
# Never touches SteamVR itself. Logs: ~/.cache/frametop-remote-display/stream-N.log
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [ ! -e /run/.containerenv ] && [ ! -e /.dockerenv ]; then
  # The Frametop session moves XDG_RUNTIME_DIR to .../frametop; podman needs the real one.
  exec env XDG_RUNTIME_DIR=/run/user/$(id -u) "$HOME/.local/bin/distrobox" enter dev -- "$here/stream.sh" "$@"
fi
bin=$here/build/ftrd-stream
dir=$HOME/.cache/frametop-remote-display
mkdir -p "$dir"
keys() { if [ "$1" = 1 ] || [ "$1" = desktop ]; then echo "$HOME/.config/frametop-remote-display"; else echo "$HOME/.config/frametop-remote-display/$1"; fi; }
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
    FTRD_STATE_FILE=$dir/stream-$n.state setsid nohup "$bin" --keys "$(keys "$n")" "$@" >"$log" 2>&1 < /dev/null &
    echo $! > "$dir/stream-$n.pid"
    # The PC link (remote-display/host): answers the PC agent while any instance runs.
    if [ -f "$HOME/.config/frametop-remote-display/link.key" ] && ! pgrep -f ftrd-presence.py >/dev/null; then
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
    exec "$bin" --keys "$(keys "$n")" --pair "$1" ;;
  float)  # ft-floatd floats the window whose app id matches the desktop file
    exec "$HOME/dev/frametop/float/ft-float" launch "org.frametop.RemoteMonitor${2:-1}" ;;
  float-all)  # every paired identity's monitor, one after the other (the host starts one at a time)
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      pidof_i "$n" >/dev/null && continue
      "$HOME/dev/frametop/float/ft-float" launch "org.frametop.RemoteMonitor$n"
      for _ in $(seq 1 60); do sleep 0.5; grep -q "connection started" "$dir/stream-$n.log" 2>/dev/null && break; done
    done ;;
  float-desktop)
    exec "$HOME/dev/frametop/float/ft-float" launch org.frametop.RemoteDisplay ;;
  presence)
    if pgrep -f ftrd-presence.py >/dev/null; then echo "ftrd-presence running"; else echo "ftrd-presence not running"; fi
    tail -3 "$dir/presence.log" 2>/dev/null
    python3 -c "import importlib.util as u; s=u.spec_from_file_location('p', '$here/ftrd-presence.py'); m=u.module_from_spec(s); s.loader.exec_module(m); import json; print(json.dumps(m.snapshot(), indent=1))" ;;
  cleanup)  # Vibepollo 2.0.0 sometimes keeps a released virtual monitor (its ownership
    # bookkeeping); a short start + release by each paired identity clears it. Monitors flash.
    [ -z "$(for n in $(instances); do pidof_i "$n"; done)" ] || { echo "stop the streams first (stream.sh off)"; exit 1; }
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] && "$bin" --keys "$(keys "$n")" --novr --app-id 2147483502 --seconds 1 >/dev/null 2>&1
    done
    sleep 4
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      "$bin" --keys "$(keys "$n")" --novr --no-yield --app "Remote Monitor" --size 2560x1440 --seconds 3 2>&1 |
        grep -E "^app:|failed|released" | sed "s/^/identity $n: /"
      sleep 3
    done ;;
  install-desktop)  # ~/.local/share/applications
    # One entry in the menus: "Remote PC" (every paired monitor, each in its own panel). The
    # per-monitor and PC-desktop files stay, hidden (NoDisplay), because ft-float launch floats
    # a window by its desktop file.
    apps=$HOME/.local/share/applications
    mkdir -p "$apps"
    rm -f "$apps"/org.frametop.RemoteMonitor*.desktop "$apps"/org.frametop.RemoteDisplay.desktop
    hidden() {  # name id command
      printf '[Desktop Entry]\nType=Application\nName=%s\nExec=sh -c "%s"\nIcon=preferences-desktop-remote-desktop\nTerminal=false\nStartupWMClass=%s\nNoDisplay=true\n' \
        "$1" "$3" "$2" > "$apps/$2.desktop"
    }
    s='$HOME/dev/frametop/remote-display/stream/stream.sh'
    hidden "Remote PC desktop" org.frametop.RemoteDisplay "$s on -i desktop --window"
    for n in 1 2 3 4; do
      [ -f "$(keys "$n")/uniqueid.dat" ] || continue
      hidden "Remote PC $n" "org.frametop.RemoteMonitor$n" \
        "$s on -i $n --window --app 'Remote Monitor' --size 2560x1440 --wl-id org.frametop.RemoteMonitor$n --title 'Remote PC $n'"
    done
    printf '[Desktop Entry]\nType=Application\nName=Remote PC\nComment=Your Windows PC'"'"'s virtual monitors, each in its own panel\nExec=sh -c "%s float-all"\nIcon=preferences-desktop-remote-desktop\nTerminal=false\nCategories=Network;RemoteAccess;\n' \
      "$s" > "$apps/org.frametop.RemotePC.desktop"
    echo "shown: Remote PC; hidden: $(cd "$apps" && grep -l NoDisplay=true org.frametop.Remote*.desktop | tr '\n' ' ')" ;;
  *) echo "usage: stream.sh on [-i N] [opts]|off [N|all]|status|log [N]|pair [-i N] PIN|float [N]|float-all|float-desktop|cleanup|install-desktop"; exit 2 ;;
esac
