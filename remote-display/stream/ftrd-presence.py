#!/usr/bin/env python3
"""ftrd-presence: the Frame's half of the PC link (remote-display/host/README.md).

While at least one remote-display instance runs, answer the PC agent's queries with what the
Frame shows: one entry per virtual monitor, with the stream size and where its panel floats
around you, so the agent can arrange Windows' virtual monitors the same way (right of the
physical ones). With no instance left it answers "no monitors" for a few seconds and exits.

  Request  (PC -> Frame, UDP 47810):  FTRD2 PING <nonce hex>
  Reply    (Frame -> PC):             FTRD2 <json>\\n<cert sha256 hex> <signature hex>
The signature is RSA-SHA256 over nonce + json with this Frame's Vibepollo pairing key (identity
1's key.pem), so the PC agent checks it against the certificate Vibepollo already trusts: no
extra key to copy.

While `stream.sh setup` pairs a monitor it writes ~/.cache/frametop-remote-display/pairing.json
({"name", "pin"}); then the reply is `FTRD2-PAIR {"name", "pin", "frame"}` (nothing to sign
with yet): the PIN the pairing request waits for. The PC agent hands it to Vibepollo (after
asking, outside its pairing window). Each ping is noted in ping.txt, so setup can tell the
PC helper is there.

State comes from the instances' FTRD_STATE_FILEs (~/.cache/frametop-remote-display/
stream-N.state, written by ftrd-stream), panel poses from ft-screens (@ft_screens "get N",
"head") and which panel holds which window from ft-floatd (@frametop_float "list apps").
"""
import base64, hashlib, json, math, os, socket, subprocess, sys, time

PORT = int(os.environ.get("FTRD_PRESENCE_PORT", "47810"))
CACHE = os.path.expanduser("~/.cache/frametop-remote-display")
KEYDIR = os.path.expanduser("~/.config/frametop-remote-display")
LINGER = 8.0  # seconds of "no monitors" answers after the last instance stops


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def ask(name, text, timeout=0.3):
    """One request on an abstract unix datagram socket (ft-screens, ft-floatd)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        s.bind("")  # autobind, for the reply
        s.settimeout(timeout)
        s.sendto(text.encode(), "\0" + name)
        return s.recv(65536).decode(errors="replace")
    except OSError:
        return ""
    finally:
        s.close()


def cert_sha256(keys):
    """SHA-256 of the client certificate (DER), which Vibepollo stores for the pairing."""
    try:
        pem = open(os.path.join(keys, "client.pem")).read()
    except OSError:
        return ""
    body = "".join(l for l in pem.splitlines() if l and not l.startswith("-----"))
    return hashlib.sha256(base64.b64decode(body)).hexdigest()


def instances():
    out = []
    for f in sorted(os.listdir(CACHE)) if os.path.isdir(CACHE) else []:
        if not (f.startswith("stream-") and f.endswith(".state")):
            continue
        try:
            st = json.load(open(os.path.join(CACHE, f)))
            os.kill(int(st["pid"]), 0)
        except (OSError, ValueError, KeyError):
            continue
        st["instance"] = f[len("stream-"):-len(".state")]
        out.append(st)
    return out


def panels():
    """app id -> ft-screens number of the panel it floats on."""
    reply = ask("frametop_float", "list apps")
    found = {}
    if reply.startswith("ok"):
        for item in reply.split()[1:]:
            parts = item.split(":")
            if len(parts) >= 3 and parts[1].isdigit():
                found[":".join(parts[2:])] = int(parts[1])
    return found


def pose(n):
    """(x, y, z) of panel n's centre in the room, or None."""
    r = ask("ft_screens", f"get {n}").split()
    if len(r) < 4 or r[0] != "ok":
        return None
    try:
        return float(r[1]), float(r[2]), float(r[3])
    except ValueError:
        return None


def head():
    r = ask("ft_screens", "head").split()
    if len(r) >= 5 and r[0] == "ok":
        try:
            return float(r[1]), float(r[2]), float(r[3]), float(r[4])
        except ValueError:
            pass
    return None


def snapshot():
    insts = instances()
    where = panels() if insts else {}
    h = head() if insts else None
    mons = []
    for st in insts:
        m = {"instance": st["instance"], "cert_sha256": cert_sha256(st.get("keys", "")), "app": st.get("app", ""),
             "w": st.get("w", 0), "h": st.get("h", 0), "suspended": bool(st.get("suspended")),
             "busy": bool(st.get("busy"))}
        n = where.get(st.get("wl_id", ""))
        p = pose(n) if n else None
        if p and h:
            dx, dy, dz = p[0] - h[0], p[1] - h[1], p[2] - h[2]
            # Azimuth: degrees to the right of where you face (ft-screens' head yaw is in degrees,
            # positive when turned left; forward is -z); elevation: degrees up.
            az = math.degrees(math.atan2(dx, -dz)) + h[3]
            az = (az + 180) % 360 - 180
            el = math.degrees(math.atan2(dy, math.hypot(dx, dz)))
            m.update(panel=n, az=round(az, 1), el=round(el, 1))
        mons.append(m)
    return mons


PAIRING = os.path.join(CACHE, "pairing.json")


def pairing():
    """The pairing in progress (setup), if any and fresh."""
    try:
        if time.time() - os.path.getmtime(PAIRING) > 300:
            return None
        p = json.load(open(PAIRING))
        return {"name": str(p["name"]), "pin": str(p["pin"]), "frame": socket.gethostname()}
    except (OSError, ValueError, KeyError):
        return None


def sign(data):
    r = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.path.join(KEYDIR, "key.pem")],
                       input=data, capture_output=True, timeout=5)
    return r.stdout.hex() if r.returncode == 0 else ""


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", PORT))
    except OSError as e:
        sys.exit(f"ftrd-presence: port {PORT}: {e} (already running?)")
    s.settimeout(1.0)
    log(f"listening on UDP {PORT}")
    last_seen = time.monotonic()
    cache, cache_t = [], 0.0
    while True:
        now = time.monotonic()
        if now - cache_t > 0.5:
            cache, cache_t = snapshot(), now
            if cache or pairing():
                last_seen = now
        if not cache and now - last_seen > LINGER:
            log("no instances or pairing left; exiting")
            return
        try:
            data, peer = s.recvfrom(512)
        except socket.timeout:
            continue
        parts = data.decode(errors="replace").split()
        if len(parts) != 3 or parts[0] != "FTRD2" or parts[1] != "PING":
            continue
        try:
            nonce = bytes.fromhex(parts[2])
        except ValueError:
            continue
        if not 8 <= len(nonce) <= 64:
            continue
        try:
            with open(os.path.join(CACHE, "ping.txt"), "w") as f:
                f.write(f"{time.time():.0f} {peer[0]}\n")
        except OSError:
            pass
        pair = pairing()
        if pair:
            s.sendto(("FTRD2-PAIR " + json.dumps(pair, separators=(",", ":"))).encode(), peer)
            continue
        cert = cert_sha256(KEYDIR)
        if not cert:
            continue
        body = json.dumps({"v": 2, "t": time.time(), "monitors": cache}, separators=(",", ":"))
        sig = sign(nonce + body.encode())
        if sig:
            s.sendto(f"FTRD2 {body}\n{cert} {sig}".encode(), peer)


if __name__ == "__main__":
    main()
