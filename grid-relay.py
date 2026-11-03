#!/usr/bin/env python3
"""Grid relay for the FCT dashboard (Experiment 1b, stage G2).

Runs on the RAN host (REDLAB) with host networking, next to the gNB. It is the only client of the gNB's T tracer
(127.0.0.1:2021, one client at a time) and runs one short capture at a time with grid-trace.py's code:

  GET  /healthz          -> "ok"
  GET  /grid/status      -> {"tracer": bool, "reason": ..., "job": {...}, "last": {...}}       (no token needed)
  GET  /grid/result      -> the last capture: {"kind", "time_utc", "nrb", "rows": [...], "grids": [...]}  (no token)
  POST /grid/capture     -> body {"kind": "snapshot", "slots": 20-80, "prb": N}
                            or   {"kind": "ra", "slots": 20-80, "prb": N, "wait": 10-120}; header X-Relay-Token
                            202 when started; the result appears in /grid/result when the job is "done"

The tracer is on only while the gNB runs with --T_stdout 2 --T_nowait and the port is firewalled
(sudo MODE=on bash infra/exp/exp01b-grid.sh); this relay never changes that. It reads the tracer state from
/proc/net/tcp, so a status request does not take the single tracer connection.
Results hold scheduling values and PRB x symbol energies (whole dB) only, never MAC payloads (grid-trace.py keeps
only sizes). The token is read from a file (a Kubernetes Secret) and compared in constant time. rfsim only.
"""
import hmac
import importlib.util
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("RELAY_BIND", "10.42.0.1")
PORT = int(os.environ.get("RELAY_PORT", "8094"))
TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/etc/grid-relay/token")
TRACE = os.environ.get("GRID_TRACE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "grid-trace.py"))
T_PORT = int(os.environ.get("GRID_T_PORT", "2021"))   # the gNB T tracer (tests use another port)

spec = importlib.util.spec_from_file_location("grid_trace", TRACE)
gt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gt)

LOCK = threading.Lock()                       # one capture at a time (the tracer takes one client)
JOB = {"state": "idle", "kind": None, "since": time.time(), "error": None}
LAST = {"result": None}


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def tracer_listening():
    """True when something listens on TCP port 2021 (IPv4 or IPv6), read from /proc without connecting."""
    for f in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(f) as fh:
                next(fh)
                for line in fh:
                    p = line.split()
                    if p[3] == "0A" and int(p[1].rsplit(":", 1)[1], 16) == T_PORT:
                        return True
        except (OSError, StopIteration, ValueError, IndexError):
            pass
    return False


def compact(c, kind):
    """grid-trace capture -> JSON for the dashboard: rows in time order, grids as whole dB (nrb x 14 ints)."""
    rows = gt.summary(c)
    order = c["order"]
    grids = [{"dir": k[0], "frame": k[1], "slot": k[2],
              "db": [[int(round(v)) for v in r] for r in c["slots"][k]["db"].tolist()]}
             for k in sorted(c["slots"], key=lambda k: order.get(k, 1 << 30))]
    return {"kind": kind, "time_utc": now_iso(), "nrb": c["nrb"], "secs": round(c["secs"], 2),
            "msgs": c["msgs"], "rows": rows, "grids": grids}


def run(kind, slots, prb, wait):
    try:
        c = gt.capture("127.0.0.1", T_PORT, prb, slots, timeout=5.0, ra_wait=wait if kind == "ra" else 0)
        LAST["result"] = compact(c, kind)
        JOB.update(state="done", since=time.time(), error=None)
        print(f"{now_iso()} capture {kind}: {len(LAST['result']['grids'])} grids, {len(LAST['result']['rows'])} rows", flush=True)
    except SystemExit as e:       # grid-trace's refusals (PRB above 106, no random access in time, ...)
        JOB.update(state="failed", since=time.time(), error=str(e))
    except Exception as e:
        JOB.update(state="failed", since=time.time(), error=f"{type(e).__name__}: {e}")
    finally:
        if JOB["state"] == "failed":
            print(f"{now_iso()} capture {kind} failed: {JOB['error']}", flush=True)
        LOCK.release()


def token_ok(given):
    try:
        with open(TOKEN_FILE) as f:
            want = f.read().strip()
    except OSError:
        return False
    return bool(want) and hmac.compare_digest(given.encode(), want.encode())


class H(BaseHTTPRequestHandler):
    def send(self, code, obj, ctype="application/json"):
        b = obj.encode() if isinstance(obj, str) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, "ok", "text/plain")
        if self.path == "/grid/status":
            on = tracer_listening()
            last = LAST["result"]
            return self.send(200, {
                "tracer": on, "reason": None if on else "T tracer off: sudo MODE=on bash infra/exp/exp01b-grid.sh on REDLAB",
                "job": {k: JOB[k] for k in ("state", "kind", "error")} | {"ageS": round(time.time() - JOB["since"], 1)},
                "last": {"kind": last["kind"], "time_utc": last["time_utc"], "grids": len(last["grids"]),
                         "rows": len(last["rows"]), "nrb": last["nrb"]} if last else None,
                "maxPrb": gt.MAX_PRB})
        if self.path == "/grid/result":
            return self.send(200, LAST["result"]) if LAST["result"] else self.send(404, {"error": "no capture yet"})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/grid/capture":
            return self.send(404, {"error": "not found"})
        if not token_ok(self.headers.get("X-Relay-Token", "")):
            return self.send(401, {"error": "token"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            body = json.loads(self.rfile.read(min(n, 4096)) or b"{}")
            kind = body.get("kind")
            slots = int(body.get("slots", 40)); prb = int(body.get("prb", 106)); wait = float(body.get("wait", 90))
        except (ValueError, TypeError):
            return self.send(400, {"error": "bad request"})
        if kind not in ("snapshot", "ra") or not 20 <= slots <= 80 or not 10 <= wait <= 120 or not 1 <= prb <= 273:
            return self.send(400, {"error": "kind snapshot|ra, slots 20-80, wait 10-120 s"})
        if prb > gt.MAX_PRB:
            return self.send(409, {"error": f"{prb} PRB: captures are refused above {gt.MAX_PRB} PRB (the gNB would abort)"})
        if not tracer_listening():
            return self.send(409, {"error": "T tracer off: sudo MODE=on bash infra/exp/exp01b-grid.sh on REDLAB"})
        if not LOCK.acquire(blocking=False):
            return self.send(409, {"error": "a capture is running"})
        JOB.update(state="running", kind=kind, since=time.time(), error=None)
        threading.Thread(target=run, args=(kind, slots, prb, wait), daemon=True).start()
        print(f"{now_iso()} capture {kind} started ({slots} slots, {prb} PRB)", flush=True)
        self.send(202, {"job": "running", "kind": kind})


if __name__ == "__main__":
    print(f"{now_iso()} grid relay on {BIND}:{PORT}, tracer {'on' if tracer_listening() else 'off'}", flush=True)
    ThreadingHTTPServer((BIND, PORT), H).serve_forever()
