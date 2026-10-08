#!/usr/bin/env python3
"""ftrd-find-pc: find the paired Windows PC (Vibepollo) on the network; no addresses to type.

Prints the PC's current address. The PC is recognised by Vibepollo's unique id (from its
unauthenticated /serverinfo), saved at setup, so its address may change freely. Places to look,
fastest first, stopping at the first match:
  1. the address that worked last time;
  2. devices on the Frame's own hotspot (Valve's USB Wi-Fi adapter on the PC): its DHCP leases;
  3. mDNS: Vibepollo announces itself as _nvstream._tcp (how Moonlight finds hosts);
  4. a quick scan of the Frame's local /24 networks for Vibepollo's port 47989 (when mDNS is
     blocked).
  ftrd-find-pc.py            the saved PC's address (exit 1 if not found)
  ftrd-find-pc.py --list     every Vibepollo host found, "address hostname uniqueid" per line
  ftrd-find-pc.py --remember ADDRESS   save the PC at ADDRESS as the one to find (setup)
Files: ~/.config/frametop-remote-display/host (last address), host-id (the PC's unique id).
"""
import concurrent.futures as cf
import ipaddress, os, re, socket, struct, subprocess, sys, time, urllib.request

CONF = os.path.expanduser("~/.config/frametop-remote-display")
PORT = 47989
LEASES = ["/var/run/softap_dnsmasq.leases", "/run/host/var/run/softap_dnsmasq.leases",
          "/run/host/run/softap_dnsmasq.leases"]


def read(name):
    try:
        return open(os.path.join(CONF, name)).read().strip()
    except OSError:
        return ""


def write(name, value):
    os.makedirs(CONF, mode=0o700, exist_ok=True)
    with open(os.path.join(CONF, name), "w") as f:
        f.write(value + "\n")


def serverinfo(ip, timeout=0.8):
    """(hostname, uniqueid) if a GameStream host (Vibepollo/Sunshine) answers at ip, else None."""
    try:
        with urllib.request.urlopen(f"http://{ip}:{PORT}/serverinfo", timeout=timeout) as r:
            xml = r.read(65536).decode(errors="replace")
    except Exception:
        return None
    uid = re.search(r"<uniqueid>([^<]+)</uniqueid>", xml)
    if not uid:
        return None
    host = re.search(r"<hostname>([^<]*)</hostname>", xml)
    return (host.group(1) if host else "?"), uid.group(1)


def hotspot_clients():
    for path in LEASES:
        try:
            # dnsmasq leases: expiry mac ip hostname clientid
            return [l.split()[2] for l in open(path) if len(l.split()) >= 3]
        except OSError:
            continue
    return []


def _name(buf, i):
    labels, jumped, end = [], False, None
    while True:
        n = buf[i]
        if n == 0:
            i += 1
            break
        if n & 0xC0 == 0xC0:
            if not jumped:
                end = i + 2
            i, jumped = ((n & 0x3F) << 8) | buf[i + 1], True
            continue
        labels.append(buf[i + 1:i + 1 + n].decode(errors="replace"))
        i += 1 + n
    return ".".join(labels), (end if jumped else i)


def mdns(wait=1.5, service="_nvstream._tcp.local"):
    """Addresses of hosts answering an mDNS query for the service (Vibepollo: _nvstream._tcp)."""
    q = struct.pack(">HHHHHH", 0, 0, 1, 0, 0, 0)
    for part in service.split("."):
        q += bytes([len(part)]) + part.encode()
    q += b"\x00" + struct.pack(">HH", 12, 0x8001)  # PTR, unicast response wanted
    found = set()
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)
        s.settimeout(0.3)
        s.sendto(q, ("224.0.0.251", 5353))
        until = time.monotonic() + wait
        while time.monotonic() < until:
            try:
                buf, (src, _) = s.recvfrom(9000)
            except socket.timeout:
                continue
            try:  # keep only answers about _nvstream; take their A records, else the sender
                _, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", buf[:12])
                i = 12
                for _ in range(qd):
                    _, i = _name(buf, i)
                    i += 4
                relevant, addrs = False, []
                for _ in range(an + ns + ar):
                    name, i = _name(buf, i)
                    rtype, _, _, rdlen = struct.unpack(">HHIH", buf[i:i + 10])
                    i += 10
                    if service.split(".")[0] in name:
                        relevant = True
                    if rtype == 1 and rdlen == 4:
                        addrs.append(socket.inet_ntoa(buf[i:i + 4]))
                    i += rdlen
                if relevant:
                    found.update(addrs or [src])
            except Exception:
                continue
    except OSError:
        pass
    finally:
        s.close()
    return sorted(found)


def local_nets():
    try:
        out = subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True, timeout=3).stdout
    except Exception:
        return []
    nets = []
    for m in re.finditer(r"^\d+:\s+(\S+)\s+inet\s+([\d.]+)/(\d+)", out, re.M):
        dev, ip, plen = m.group(1), m.group(2), int(m.group(3))
        if dev == "lo" or plen < 16 or plen >= 31:
            continue
        nets.append((ip, ipaddress.ip_network(f"{ip}/{max(plen, 24)}", strict=False)))
    return nets


def scan(timeout=0.3):
    """Addresses on the local networks with port 47989 open."""
    def open_(ip):
        try:
            with socket.create_connection((ip, PORT), timeout=timeout):
                return ip
        except OSError:
            return None
    ips = [str(h) for own, net in local_nets() for h in net.hosts() if str(h) != own]
    with cf.ThreadPoolExecutor(64) as ex:
        return [ip for ip in ex.map(open_, ips) if ip]


def candidates():
    """Places to look, as lazily evaluated groups (fastest first)."""
    yield [read("host")] if read("host") else []
    yield hotspot_clients()
    yield mdns()
    yield scan()


def find(uid):
    seen = set()
    for group in candidates():
        group = [ip for ip in group if ip and ip not in seen]
        seen.update(group)
        with cf.ThreadPoolExecutor(16) as ex:
            for ip, info in zip(group, ex.map(serverinfo, group)):
                if info and info[1] == uid:
                    return ip
    return None


def main():
    args = sys.argv[1:]
    if args[:1] == ["--list"]:
        seen, found = set(), []
        for group in candidates():
            group = [ip for ip in group if ip and ip not in seen]
            seen.update(group)
            with cf.ThreadPoolExecutor(16) as ex:
                found += [(ip, i) for ip, i in zip(group, ex.map(serverinfo, group)) if i]
        uids = set()
        for ip, (host, uid) in found:
            if uid not in uids:
                uids.add(uid)
                print(ip, host, uid)
        return 0 if found else 1
    if args[:1] == ["--remember"] and len(args) == 2:
        info = serverinfo(args[1], timeout=3)
        if not info:
            print(f"no Vibepollo answering at {args[1]}", file=sys.stderr)
            return 1
        write("host", args[1]), write("host-id", info[1])
        print(args[1], info[0], info[1])
        return 0
    uid = read("host-id")
    if not uid:  # set up before the finder existed: trust the saved address
        if read("host"):
            print(read("host"))
            return 0
        print("not set up: stream.sh setup", file=sys.stderr)
        return 1
    ip = find(uid)
    if not ip:
        print("the PC isn't answering (off, asleep, Vibepollo stopped, or another network)", file=sys.stderr)
        return 1
    if ip != read("host"):
        write("host", ip)
    print(ip)
    return 0


if __name__ == "__main__":
    sys.exit(main())
