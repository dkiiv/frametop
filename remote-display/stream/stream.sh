#!/usr/bin/env bash
# Remote-display POC toggle: the Windows PC on the Frame, as a SteamVR overlay or as windows that
# float in Frametop panels. Several instances can run at once (one per paired client identity).
#   stream.sh on [-i N] [ftrd-stream options]   start instance N (default 1)
#   stream.sh off [N|all]                       stop instance N (default: all)
#   stream.sh status                            running instances + their last stats line
#   stream.sh log [N]                           follow instance N's log
#   stream.sh setup [monitors] [PC address]     first-time setup: find the PC, build, pair, menu entry
#   stream.sh pair [-i N] PIN                   pair identity N (enter the PIN in Vibepollo's web UI)
#   stream.sh float [N]                         instance N as a Vibepollo "Remote Monitor" (a virtual
#                                               monitor on the PC) in its own Frametop panel; resizing
#                                               the panel resizes the monitor
#   stream.sh open                              the "Remote PC" entry: float-all, or setup in a terminal first
#   stream.sh float-all                         every paired identity's monitor
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
  # "Remote PC" in the menu: the monitors, or the first time, setup in a terminal window.
  if [ "${1:-}" = open ]; then
    if [ -f "$HOME/.config/frametop-remote-display/uniqueid.dat" ]; then exec "$0" float-all; fi
    run="'$here/stream.sh' setup && '$here/stream.sh' float-all; echo; echo 'This window closes in a minute.'; sleep 60"
    for t in konsole xterm; do
      command -v $t >/dev/null && exec $t -e bash -c "$run"
    done
    notify-send -a "Remote PC" "Remote PC" "Set it up first: run $here/stream.sh setup in a terminal" 2>/dev/null
    exit 1
  fi
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
# The PC's current address: ftrd-find-pc.py finds the PC paired at setup by its Vibepollo id
# (last address, the Frame's hotspot, mDNS, a scan); nothing to type.
pchost() { python3 "$here/ftrd-find-pc.py" 2>/dev/null; }
hostopt() { case " $* " in *" --host "*) ;; *) [ -n "${PCHOST:-}" ] && echo "--host $PCHOST" ;; esac; }
say() {  # a message where the user is: the terminal, else a desktop notification
  echo "$*"
  [ -t 1 ] || notify-send -a "Remote PC" "Remote PC" "$*" 2>/dev/null || true
}
case ${1:-} in on|pair|cleanup)
  if [ -f "$conf/host" ] || [ -f "$conf/host-id" ]; then
    PCHOST=$(pchost) || { say "Can't find your PC: is it on and awake, with Vibepollo running, on the Frame's network?"; exit 1; }
  fi ;;
esac
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
  setup)  # first-time setup: stream.sh setup [monitors (1-4, default 2)] [PC address (default: found)]
    shift
    h=; count=2
    for a in "$@"; do case $a in [1-4]) count=$a ;; *) h=$a ;; esac; done
    if [ -z "$h" ]; then
      echo "== looking for your PC (Vibepollo) on the network..."
      mapfile -t pcs < <(python3 "$here/ftrd-find-pc.py" --list)
      if [ ${#pcs[@]} -eq 0 ]; then
        echo "No PC with Vibepollo found. Is it installed and running, and is the PC on the Frame's"
        echo "network (or Valve's USB adapter plugged in)? You can also give its address: stream.sh setup ADDRESS"
        exit 1
      elif [ ${#pcs[@]} -eq 1 ]; then h=${pcs[0]%% *}
      else
        echo "Several PCs found:"; i=1; for l in "${pcs[@]}"; do echo "  $i) $(echo "$l" | cut -d' ' -f1-2)"; i=$((i + 1)); done
        read -r -p "Which one? [1] " c; c=${c:-1}; h=$(echo "${pcs[$((c - 1))]}" | cut -d' ' -f1)
      fi
    fi
    case $count in [1-4]) ;; *) echo "monitors: 1 to 4"; exit 2 ;; esac
    mkdir -p "$conf"; chmod 700 "$conf"
    python3 "$here/ftrd-find-pc.py" --remember "$h" >/dev/null ||
      { echo "no Vibepollo answering at $h (is it installed and running? same network?)"; exit 1; }
    echo "== PC: $h"
    # The PC helper (remote-display/host, ftrd-host.ps1 -Install) approves the pairing: it asks
    # ftrd-presence, which hands it the PIN from pairing.json.
    if ! pgrep -f "ftrd-presenc[e].py" >/dev/null; then
      setsid nohup python3 "$here/ftrd-presence.py" >>"$dir/presence.log" 2>&1 < /dev/null &
    fi
    helper() { [ -f "$dir/ping.txt" ] && [ $(( $(date +%s) - $(cut -d' ' -f1 "$dir/ping.txt") )) -lt 15 ]; }
    for n in $(seq 1 "$count"); do
      k=$(keys "$n")
      if [ -f "$k/uniqueid.dat" ] && "$bin" --keys "$k" --host "$h" --check >/dev/null 2>&1; then
        echo "== monitor $n: already paired"; continue
      fi
      pin=$(printf '%04d' $((RANDOM % 10000)))
      printf '{"name": "Frame monitor %s", "pin": "%s"}\n' "$n" "$pin" > "$dir/pairing.json"
      echo
      echo "== monitor $n: pairing (PIN $pin)"
      echo "   With the Remote PC helper on the PC, this happens by itself in a few seconds (or it asks"
      echo "   you on the PC's screen). Without it: on the PC, open https://localhost:47990 -> PIN,"
      echo "   enter $pin and name it \"Frame monitor $n\"."
      mkdir -p "$k"; chmod 700 "$k"
      "$bin" --keys "$k" --host "$h" --pair "$pin" | grep -v "^pairing:" || { rm -f "$dir/pairing.json"; echo "pairing failed; run setup again"; exit 1; }
      rm -f "$dir/pairing.json"
      if [ "$n" -gt 1 ] && ! helper; then
        echo "   Vibepollo gives full rights only to the first device: in the web UI -> Clients, give"
        echo "   \"Frame monitor $n\" the Launch and input (mouse, keyboard) permissions too."
      fi
    done
    "$0" install-desktop >/dev/null
    echo
    echo "== done. Remote PC is in the Steam menu (Steam button -> +)."
    helper || echo "   Tip: the PC helper (remote-display/host) places the monitors as on the Frame and pairs for you." ;;
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
    printf '[Desktop Entry]\nType=Application\nName=Remote PC\nComment=Your Windows PC'"'"'s virtual monitors, each in its own panel\nExec=sh -c "%s open"\nIcon=preferences-desktop-remote-desktop\nTerminal=false\nCategories=Network;RemoteAccess;\n' \
      "$s" > "$apps/org.frametop.RemotePC.desktop"
    echo "shown: Remote PC; hidden: $(cd "$apps" && grep -l NoDisplay=true org.frametop.Remote*.desktop | tr '\n' ' ')" ;;
  *) echo "usage: stream.sh on [-i N] [opts]|off [N|all]|status|log [N]|setup [N] [PC]|pair [-i N] PIN|open|float [N]|float-all|cleanup|install-desktop"; exit 2 ;;
esac
