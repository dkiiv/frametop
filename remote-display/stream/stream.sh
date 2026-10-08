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
#   stream.sh float-desktop                     the PC's own desktop (its physical monitors), floating
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
    setsid nohup "$bin" --keys "$(keys "$n")" "$@" >"$log" 2>&1 < /dev/null &
    echo $! > "$dir/stream-$n.pid"
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
  float-desktop)
    exec "$HOME/dev/frametop/float/ft-float" launch org.frametop.RemoteDisplay ;;
  install-desktop)  # ~/.local/share/applications
    apps=$HOME/.local/share/applications
    mkdir -p "$apps"
    cp "$here/org.frametop.RemoteDisplay.desktop" "$apps/"
    for n in 1 2 3 4; do
      cat > "$apps/org.frametop.RemoteMonitor$n.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Remote PC monitor $n (POC)
Comment=Frametop remote-display POC: a virtual monitor on the Windows PC (Vibepollo Remote Monitor), floating
Exec=sh -c "\$HOME/dev/frametop/remote-display/stream/stream.sh on -i $n --window --app 'Remote Monitor' --size 2560x1440 --wl-id org.frametop.RemoteMonitor$n --title 'Remote PC $n'"
Icon=preferences-desktop-remote-desktop
Terminal=false
Categories=Network;RemoteAccess;
StartupWMClass=org.frametop.RemoteMonitor$n
EOF
    done
    echo "installed $apps/org.frametop.RemoteDisplay.desktop and org.frametop.RemoteMonitor{1..4}.desktop" ;;
  *) echo "usage: stream.sh on [-i N] [opts]|off [N|all]|status|log [N]|pair [-i N] PIN|float [N]|float-desktop|install-desktop"; exit 2 ;;
esac
