#!/usr/bin/env python3
"""N2 capture service for the FCT dashboard (D3: message flow).

Runs on the RAN host (FCT0173) with host networking. tshark watches SCTP
port 38412 and decodes NGAP and NAS-5GS; this service keeps the last
messages in memory and serves them as JSON. It never stores packets to disk.
"""
import collections
import itertools
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8091"))
IFACE = os.environ.get("CAPTURE_IFACE", "any")
GNB_IP = os.environ.get("GNB_IP", "10.0.129.7")
KEEP = int(os.environ.get("KEEP_MESSAGES", "1000"))

MESSAGES = collections.deque(maxlen=KEEP)
SEQ = itertools.count(1)
LOCK = threading.Lock()
STATUS = {"running": False, "since": None, "error": None}
SACK_RE = re.compile(r"^(SACK \([^)]*\)\s*,\s*)+")


def run_tshark():
    cmd = ["tshark", "-l", "-n", "-i", IFACE, "-f", "sctp port 38412", "-Y", "ngap",
           "-T", "fields", "-E", "separator=\t", "-E", "quote=n",
           "-e", "frame.time_epoch", "-e", "ip.src", "-e", "ip.dst",
           "-e", "_ws.col.Protocol", "-e", "_ws.col.Info"]
    while True:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            STATUS.update(running=True, since=time.time(), error=None)
            for line in p.stdout:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 5:
                    continue
                ts, src, dst, proto, info = parts[:5]
                src, dst = src.split(",")[0], dst.split(",")[0]
                text = SACK_RE.sub("", info).strip()
                if not text:
                    continue
                with LOCK:
                    MESSAGES.append({
                        "seq": next(SEQ),
                        "t": float(ts),
                        "dir": "ul" if src == GNB_IP else "dl",
                        "src": src, "dst": dst,
                        "proto": proto,
                        "msg": text,
                    })
            err = p.stderr.read()[-300:]
            STATUS.update(running=False, error=f"tshark exited {p.wait()}: {err.strip()}")
        except Exception as e:
            STATUS.update(running=False, error=f"{type(e).__name__}: {e}")
        time.sleep(3)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/messages"):
            after = 0
            if "after=" in self.path:
                try:
                    after = int(self.path.split("after=")[1].split("&")[0])
                except ValueError:
                    after = 0
            with LOCK:
                items = [m for m in MESSAGES if m["seq"] > after]
                last = MESSAGES[-1]["seq"] if MESSAGES else 0
            body = json.dumps({"status": STATUS, "last": last, "messages": items[-500:]}).encode()
            code = 200
        elif self.path == "/healthz":
            body, code = (b"ok", 200) if STATUS["running"] else (b"tshark not running", 503)
        else:
            body, code = b"Not found", 404
        self.send_response(code)
        self.send_header("Content-Type", "application/json" if code == 200 and body[:1] == b"{" else "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    threading.Thread(target=run_tshark, daemon=True).start()
    print(f"n2-capture on :{PORT}, iface={IFACE}, gNB={GNB_IP}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
