#!/usr/bin/env bash
# multi-test.sh: two Vibepollo Remote Monitors at once from this Frame (two paired identities:
# ~/.config/frametop-remote-display and .../2). Releases both first, starts identity 1, waits
# until it streams, probes the host as identity 2, then starts identity 2. Prints timestamped
# milestones. A1=Desktop makes identity 1 the primary (game) stream, as Vibepollo intends.
# Run in the dev container: scripts/frame.sh -C remote-display/stream ./multi-test.sh
set -uo pipefail
cd "$(dirname "$0")"
K2=$HOME/.config/frametop-remote-display/2
U2=$(cat "$K2/uniqueid.dat")
ts() { while IFS= read -r l; do echo "$(date +%T.%3N) $1 $l"; done; }
keep='server:|released|^app:|failed|capture: NV12|RESULT|  all '
el() { echo "$(echo "$(date +%s.%N) - $1" | bc | cut -c1-5) s"; }

for k in "" "--keys $K2"; do ./build/ftrd-stream $k --novr --app "Disconnect Monitor" --seconds 1 >/dev/null 2>&1; done
sleep 5
log1=$(mktemp)
./build/ftrd-stream --novr --app "${A1:-Remote Monitor}" --size ${S1:-2560x1440} --fps 90 --seconds ${T1:-40} 2>&1 | ts "[1]" > "$log1" &
for _ in $(seq 1 60); do grep -q "capture: NV12\|failed" "$log1" && break; sleep 0.25; done
grep -E "$keep" "$log1"
grep -q "capture: NV12" "$log1" || { echo "[1] never streamed"; wait; exit 1; }
sleep 3
echo "$(date +%T.%3N) [2] starting while [1] streams"
s=$(date +%s.%N)
./build/ftrd-stream --keys "$K2" --novr --app "Remote Monitor" --size ${S2:-1920x1080} --fps 90 --seconds ${T2:-15} 2>&1 | ts "[2]" | grep -E "$keep"
echo "  [2] total: $(el $s)"
wait
grep -E "$keep" "$log1" | tail -3
rm -f "$log1"
