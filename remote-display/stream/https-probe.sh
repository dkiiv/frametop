#!/usr/bin/env bash
# https-probe.sh: while one Remote Monitor stream runs (identity 1), poll the host's HTTPS
# GameStream port every 2 s (2 s timeout, identity 2's cert) and print when it answers.
# Shows whether 47984 stalls for the whole stream, a window after launch, or periodically.
set -uo pipefail
cd "$(dirname "$0")"
K1=$HOME/.config/frametop-remote-display; K2=$K1/2
H=${HOST:-10.35.78.22}
probe() {
  local s c
  s=$(date +%s.%N)
  c=$(curl -sk -o /dev/null -m 2 -w "%{http_code}" --cert "$K2/client.pem" --key "$K2/key.pem" \
      "https://$H:47984/serverinfo?uniqueid=$(cat "$K2/uniqueid.dat")")
  printf "%s https %s %.2fs\n" "$(date +%T)" "$c" "$(echo "$(date +%s.%N) - $s" | bc)"
}
for k in "" "--keys $K2"; do ./build/ftrd-stream $k --novr --app-id 2147483502 --seconds 1 >/dev/null 2>&1; done
sleep 3
echo "-- idle"; probe; probe
./build/ftrd-stream --novr --app "${A1:-Remote Monitor}" --size ${S1:-2560x1440} --fps 90 --seconds ${T1:-40} > /tmp/hp1.log 2>&1 &
pid=$!
t0=$(date +%s)
while kill -0 $pid 2>/dev/null; do
  m=$(grep -oE "^app:|capture: NV12|RESULT" /tmp/hp1.log | tail -1)
  echo "-- +$(( $(date +%s) - t0 ))s stream: ${m:-connecting}"
  probe
  sleep 1
done
echo "-- after"; probe; probe
grep -E "^app:|failed|  all " /tmp/hp1.log
