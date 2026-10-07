#!/usr/bin/env bash
# Build ftrd-stream (remote-display POC M2) in the dev container on the Frame:
# remote-display/stream/build/ftrd-stream. Runs in the container (links SteamVR's libopenvr_api by rpath).
#
# Third-party code is fetched at a pinned commit into build/third_party (git-ignored, and
# scripts/sync.sh leaves build/ alone), never committed: moonlight-embedded (GPLv3) for
# libgamestream (pairing / app launch over HTTPS) and its moonlight-common-c submodule (GPLv3)
# for the stream itself. Only the pieces we need are compiled (no mDNS discovery, so no Avahi).
# Container packages: openssl-devel libcurl-devel expat-devel libuuid-devel (setup/dev-container.sh).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
"$root/scripts/sync.sh" >/dev/null
exec "$root/scripts/frame.sh" -C remote-display/stream 'set -e
mkdir -p build/include build/obj
me=build/third_party/moonlight-embedded
pin=f32e415aea6797d261d6b470dcf8bf18727341c2
if [ ! -f $me/.pin-$pin ]; then
  rm -rf $me
  git clone -q https://github.com/moonlight-stream/moonlight-embedded.git $me
  git -C $me checkout -q $pin
  git -C $me submodule update -q --init --recursive third_party/moonlight-common-c
  touch $me/.pin-$pin
fi
# Close every HTTPS connection after its request (libgamestream does so only on FreeBSD).
# Otherwise curl keeps the TLS connection of the launch request open for the whole stream, and
# the GameStream HTTPS server of Vibepollo 2.0.0 stops answering anyone (incl. a second client)
# while that idle connection is open.
if ! grep -q "ftrd: always forbid reuse" $me/libgamestream/http.c; then
  sed -i "s|^#ifdef __FreeBSD__\$|#if 1 /* ftrd: always forbid reuse (was __FreeBSD__) */|" $me/libgamestream/http.c
fi
grep -q "ftrd: always forbid reuse" $me/libgamestream/http.c || { echo "http.c patch failed"; exit 1; }
openvr=v2.15.6
[ -f build/include/openvr-$openvr ] || { curl -fsSL "https://raw.githubusercontent.com/ValveSoftware/openvr/$openvr/headers/openvr.h" -o build/include/openvr.h && touch build/include/openvr-$openvr; }
mcc=$me/third_party/moonlight-common-c
defs="-DNDEBUG -DHAS_SOCKLEN_T -DHAS_FCNTL=1 -DHAS_IOCTL=1 -DHAS_POLL=1 -DHAS_GETADDRINFO=1 -DHAS_GETNAMEINFO=1 -DHAS_GETHOSTBYNAME_R=1 -DHAS_GETHOSTBYADDR_R=1 -DHAS_INET_PTON=1 -DHAS_INET_NTOP=1 -DHAS_MSGHDR_FLAGS=1"
inc="-I$mcc/src -I$mcc/reedsolomon -I$mcc/enet/include -I$me/libgamestream"
objs=
for c in $mcc/src/*.c $mcc/enet/*.c $mcc/reedsolomon/rs.c $me/libgamestream/client.c $me/libgamestream/http.c $me/libgamestream/mkcert.c $me/libgamestream/xml.c; do
  case $c in */win32.c) continue ;; esac
  o=build/obj/$(echo $c | tr / _ | sed "s/\.c$/.o/")
  [ $o -nt $c ] || gcc -std=gnu11 -O2 -w -fPIC $defs $inc -c $c -o $o
  objs="$objs $o"
done
# Wayland protocols for window mode (--window): generated client code
mkdir -p build/proto
wp=/usr/share/wayland-protocols
for x in $wp/stable/xdg-shell/xdg-shell.xml $wp/stable/linux-dmabuf/linux-dmabuf-v1.xml \
         $wp/stable/viewporter/viewporter.xml $wp/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml; do
  n=$(basename $x .xml)
  [ build/proto/$n-client-protocol.h -nt $x ] || wayland-scanner client-header $x build/proto/$n-client-protocol.h
  [ build/proto/$n-protocol.c -nt $x ] || wayland-scanner private-code $x build/proto/$n-protocol.c
  [ build/obj/proto_$n.o -nt build/proto/$n-protocol.c ] || gcc -O2 -fPIC -c build/proto/$n-protocol.c -o build/obj/proto_$n.o
  objs="$objs build/obj/proto_$n.o"
done
g++ -std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers -Wno-unused-function -DFTRD_VR -DFTRD_GL -Ibuild/include -Ibuild/proto $inc \
  $(pkg-config --cflags libdrm egl glesv2 gbm wayland-client) -include cstdarg -o build/ftrd-stream ftrd-stream.cpp $objs \
  $(pkg-config --libs egl glesv2 gbm libcurl openssl expat uuid wayland-client) -lpthread \
  -L/opt/steamvr/bin/linuxarm64 -lopenvr_api -Wl,-rpath,/opt/steamvr/bin/linuxarm64
echo "built remote-display/stream/build/ftrd-stream"'
