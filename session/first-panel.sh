#!/bin/bash
# Plasma's very first start in this desktop (no saved layout yet) can make its default
# taskbar on one of the spare outputs that hold floating windows (seen: screen 8 of
# 1 screen + 8 spare outputs), where nobody sees it. fix-panels.py repairs that, but the
# session runs it before Plasma starts, and on the first start there's nothing saved to
# repair yet: the taskbar only came back at the desktop's next start.
#
# This runs from the session's autostart (inside Plasma, on its D-Bus) only when Plasma
# started without a saved layout. It waits for Plasma to save one; if a panel is on a
# screen this desktop doesn't have, it stops plasmashell (which saves its layout on the
# way out), moves the panel with fix-panels.py, and starts plasmashell again: the
# desktop's wallpaper and taskbar blink once, apps stay open.
#   first-panel.sh SCREENS
here=$(dirname "$(readlink -f "$0")")
screens=${1:-}
file=$XDG_CONFIG_HOME/plasma-org.kde.plasma.desktop-appletsrc
log() { echo "$(date +%T) $*"; }

for _ in $(seq 1 90); do
  grep -q '^plugin=org.kde.panel$' "$file" 2>/dev/null && break
  sleep 1
done
sleep 3  # let Plasma finish placing what it made
if python3 "$here/fix-panels.py" ${screens:+--screens "$screens"} --check >/dev/null 2>&1; then
  log "taskbar is on a screen; nothing to do"; exit 0
fi
log "taskbar made on a spare output: $(python3 "$here/fix-panels.py" ${screens:+--screens "$screens"} --check 2>&1 | paste -sd ' ')"
kquitapp6 plasmashell >/dev/null 2>&1
for _ in $(seq 1 40); do
  qdbus6 org.kde.plasmashell >/dev/null 2>&1 || break
  sleep 0.5
done
python3 "$here/fix-panels.py" ${screens:+--screens "$screens"}
setsid kstart plasmashell >/dev/null 2>&1 < /dev/null &
log "plasmashell restarted"
