#!/usr/bin/env python3
"""Experiment 16 client: sends JPEG frames to the MEC server and times each round trip.

Runs in the temporary pod on REDLAB (host network). With --dev oaitun_ue1 every byte goes through the 5G UE tunnel
(SO_BINDTODEVICE, needs root in the pod); with --dev "" it uses the direct bench LAN (reference).
One keep-alive connection per frame size; frames are sent one after another (the next one after the answer), so the
latency is not inflated by the client's own queue. Prints one CSV line per frame:
  label,size,i,bytes,ok,total_ms,server_ms,inf_ms,net_ms,n_det,t_wall
total_ms = request sent to response received (wall clock); net_ms = total_ms - server_ms (network both ways).
Standard library only (Python 3.8+).
"""
import argparse, json, socket, time

ap = argparse.ArgumentParser()
ap.add_argument("--host", default="10.42.0.3")
ap.add_argument("--port", type=int, default=8500)
ap.add_argument("--dev", default="oaitun_ue1")
ap.add_argument("--sizes", default="360,720,1080")
ap.add_argument("--n", type=int, default=100)
ap.add_argument("--max-s", type=float, default=60.0, help="time limit per size")
ap.add_argument("--timeout", type=float, default=10.0)
ap.add_argument("--label", default="cell")
a = ap.parse_args()


def connect():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if a.dev:
        s.setsockopt(socket.SOL_SOCKET, 25, a.dev.encode())  # 25 = SO_BINDTODEVICE
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.settimeout(a.timeout)
    s.connect((a.host, a.port))
    return s


def request(s, method, path, body=b""):
    s.sendall(("%s %s HTTP/1.1\r\nHost: edge\r\nContent-Type: image/jpeg\r\nContent-Length: %d\r\n\r\n"
               % (method, path, len(body))).encode() + body)
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = s.recv(65536)
        if not d:
            raise ConnectionError("closed")
        buf += d
    head, rest = buf.split(b"\r\n\r\n", 1)
    status = int(head.split(b" ", 2)[1])
    n = 0
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.strip().lower() == b"content-length":
            n = int(v)
    while len(rest) < n:
        d = s.recv(65536)
        if not d:
            raise ConnectionError("closed")
        rest += d
    return status, rest[:n]


for size in [int(x) for x in a.sizes.split(",")]:
    s = None
    try:
        s = connect()
        st, img = request(s, "GET", "/frame?h=%d" % size)
        assert st == 200 and img[:2] == b"\xff\xd8", "no frame"
    except Exception as e:
        print("%s,%d,-1,0,0,,,,,,%.3f  # frame fetch failed: %s" % (a.label, size, time.time(), e), flush=True)
        continue
    t_end = time.time() + a.max_s
    i = 0
    while i < a.n and time.time() < t_end:
        t0 = time.perf_counter()
        try:
            if s is None:
                s = connect()
            st, body = request(s, "POST", "/infer", img)
            tot = (time.perf_counter() - t0) * 1e3
            r = json.loads(body)
            assert st == 200, r
            print("%s,%d,%d,%d,1,%.3f,%.3f,%.3f,%.3f,%d,%.3f" % (a.label, size, i, len(img), tot, r["server_ms"],
                  r["inf_ms"], tot - r["server_ms"], r["n"], time.time()), flush=True)
        except Exception:
            tot = (time.perf_counter() - t0) * 1e3
            print("%s,%d,%d,%d,0,%.3f,,,,,%.3f" % (a.label, size, i, len(img), tot, time.time()), flush=True)
            try:
                s.close()
            except Exception:
                pass
            s = None
        i += 1
    if s:
        s.close()
