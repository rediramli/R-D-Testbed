#!/usr/bin/env python3
"""FlexRIC relay for the FCT dashboard (Experiment 12, near-RT RIC).

Runs as the second container of the flexric-ric pod on REDLAB (host network, next to the nearRT-RIC and the gNB).
It runs the FlexRIC KPM monitor xApp (xapp_kpm_moni, E42 to the RIC on 127.0.0.1:36422), parses its output and
reports the RIC, E2 and KPM state. It sends nothing to the gNB itself and accepts no commands.

  GET /healthz  -> "ok"                                              (no token)
  GET /status   -> JSON: RIC endpoints, E2 associations, xApp state, last KPM values per UE   (X-Relay-Token)
  GET /metrics  -> Prometheus text of the same values             (X-Relay-Token or Authorization: Bearer)

E2 state comes from the kernel (/proc/net/sctp, shared through host networking): the RIC's listening endpoints and the
established associations on port 36421. The xApp asserts when no E2 node is connected and keeps its subscription to
the gNB it saw at start, so the relay starts it only while an E2 association exists and restarts it when indications
stop (gNB restarted) or it exits. The token is read from a file (a Kubernetes Secret) and compared in constant time.
"""
import hmac
import json
import os
import re
import signal
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("RELAY_BIND", "10.42.0.1")
PORT = int(os.environ.get("RELAY_PORT", "8095"))
TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/etc/ric-relay/token")
XAPP = os.environ.get("XAPP_CMD", "/usr/local/bin/xapp_kpm_moni -c /etc/flexric/flexric.conf -p /usr/local/lib/flexric/").split()
E2_PORT, E42_PORT = 36421, 36422
STALE = float(os.environ.get("STALE_SECONDS", "10"))     # the xApp asks for a report every 1000 ms
UE_TTL = float(os.environ.get("UE_TTL_SECONDS", "30"))   # forget a UE that is no longer reported
COMMIT_FILE = "/usr/local/share/flexric/FLEXRIC_COMMIT"
SCTP_STATE = {"3": "established"}                         # /proc/net/sctp/assocs ST column: SCTP_STATE_ESTABLISHED (3)

# KPM measurements (TS 28.552 names) kept per UE -> (JSON key, Prometheus metric, unit)
UE_MEAS = {
    "DRB.UEThpDl": ("thpDlKbps", "flexric_kpm_ue_thp_dl_kbps"),
    "DRB.UEThpUl": ("thpUlKbps", "flexric_kpm_ue_thp_ul_kbps"),
    "RRU.PrbTotDl": ("prbDlPct", "flexric_kpm_ue_prb_tot_dl_percent"),
    "RRU.PrbTotUl": ("prbUlPct", "flexric_kpm_ue_prb_tot_ul_percent"),
    "DRB.PdcpSduVolumeDL": ("pdcpVolDlMb", "flexric_kpm_ue_pdcp_sdu_volume_dl_mbit"),
    "DRB.PdcpSduVolumeUL": ("pdcpVolUlMb", "flexric_kpm_ue_pdcp_sdu_volume_ul_mbit"),
    "DRB.RlcSduDelayDl": ("rlcDelayDlUs", "flexric_kpm_ue_rlc_sdu_delay_dl_us"),
}
IND_RE = re.compile(r"^\s*(\d+) KPM ind_msg latency = (-?\d+)")
UE_RE = re.compile(r"^UE ID type = ([^,]+), \w+ = (\d+)")
VAL_RE = re.compile(r"^([A-Za-z0-9_.]+) = (-?[\d.]+)")
NODES_RE = re.compile(r"^Connected E2 nodes = (\d+)")

LOCK = threading.Lock()
S = {"pid": None, "started": None, "starts": 0, "exits": [], "nodes": None, "subscribed": 0, "indications": 0,
     "last_ind": None, "latency_us": None, "ues": {}, "cell": {}, "error": None, "start": time.time()}


def sctp_table(name):
    """Rows of /proc/net/sctp/<name> as dicts keyed by the header (addresses after the fixed columns)."""
    try:
        with open("/proc/net/sctp/" + name) as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    head = lines[0].split() if lines else []
    rows = []
    for ln in lines[1:]:
        p = ln.split()
        rows.append(dict(zip(head, p), _raw=p))
    return rows


def ric_endpoints():
    """Listening SCTP endpoints on the E2 / E42 ports with their local addresses."""
    out = []
    for r in sctp_table("eps"):
        if r.get("LPORT") in (str(E2_PORT), str(E42_PORT)):
            i = r["_raw"].index(r["LPORT"])
            out.append({"port": int(r["LPORT"]), "addrs": r["_raw"][i + 3:]})   # LPORT UID INODE LADDRS...
    return out


def e2_associations():
    """Established SCTP associations whose local port is the E2 port (one per connected E2 node)."""
    out = []
    for r in sctp_table("assocs"):
        if r.get("LPORT") == str(E2_PORT) and SCTP_STATE.get(r.get("ST")) == "established":
            raw = r["_raw"]
            i = raw.index("<->") if "<->" in raw else len(raw)
            out.append({"local": raw[raw.index(r["LPORT"]) + 2:i], "remote": raw[i + 1:i + 2]})
    return out


def parse_line(line, cur):
    """Feed one xApp output line; cur holds the UE block being read."""
    now = time.time()
    m = IND_RE.match(line)
    if m:
        with LOCK:
            S["indications"] += 1
            S["last_ind"] = now
            S["latency_us"] = int(m.group(2))
        cur.clear()
        return
    m = UE_RE.match(line)
    if m:
        cur.clear()
        cur["id"] = m.group(2)
        cur["type"] = m.group(1)
        return
    m = NODES_RE.match(line)
    if m:
        with LOCK:
            S["nodes"] = int(m.group(1))
        return
    if "Successfully subscribed to RAN_FUNC_ID 2" in line:
        with LOCK:
            S["subscribed"] += 1
        return
    m = VAL_RE.match(line)
    if not m:
        return
    name, val = m.group(1), float(m.group(2))
    with LOCK:
        if name in UE_MEAS and cur.get("id"):
            u = S["ues"].setdefault(cur["id"], {"amfUeNgapId": cur["id"], "idType": cur.get("type")})
            u[UE_MEAS[name][0]] = val
            u["t"] = now
        elif name == "RRC.ConnMean":
            S["cell"]["rrcConnMean"] = val
            S["cell"]["t"] = now


def run_xapp():
    """Start the xApp once, read its output until it exits or goes stale. Returns why it ended."""
    p = subprocess.Popen(XAPP, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace", bufsize=1)
    with LOCK:
        S.update(pid=p.pid, started=time.time(), nodes=None, subscribed=0, last_ind=None, error=None)
        S["starts"] += 1
    print(time.strftime("%FT%TZ", time.gmtime()), "xApp started, pid", p.pid, flush=True)
    stale = threading.Event()

    def watch():
        while p.poll() is None:
            time.sleep(1)
            with LOCK:
                ref = S["last_ind"] or S["started"]
            if time.time() - ref > STALE + (5 if S["last_ind"] is None else 0):
                stale.set()
                p.send_signal(signal.SIGINT)        # clean unsubscribe, as Ctrl-C
                for _ in range(50):
                    if p.poll() is not None:
                        return
                    time.sleep(0.1)
                p.kill()
                return
    threading.Thread(target=watch, daemon=True).start()
    cur = {}
    tail = []
    for line in p.stdout:
        line = line.rstrip("\n")
        tail = (tail + [line])[-5:]
        parse_line(line, cur)
    rc = p.wait()
    why = "no KPM indication for %.0f s" % STALE if stale.is_set() else "exit %s: %s" % (rc, " | ".join(tail[-2:]))
    with LOCK:
        S["pid"] = None
        S["error"] = why
        S["exits"] = (S["exits"] + [{"t": time.time(), "why": why}])[-10:]
    print(time.strftime("%FT%TZ", time.gmtime()), "xApp ended:", why, flush=True)


def supervisor():
    while True:
        if e2_associations():
            try:
                run_xapp()
            except Exception as e:      # e.g. binary missing: report it, retry
                with LOCK:
                    S["error"] = "cannot start the xApp: %s" % e
            time.sleep(5)
        else:
            with LOCK:
                S["error"] = "waiting for an E2 node (no SCTP association on port %d)" % E2_PORT
            time.sleep(2)


def commit():
    try:
        with open(COMMIT_FILE) as f:
            return f.read().strip()
    except OSError:
        return None


def status():
    eps = ric_endpoints()
    assocs = e2_associations()
    now = time.time()
    with LOCK:
        ues = [dict(u, ageS=round(now - u["t"], 1)) for u in S["ues"].values() if now - u["t"] <= UE_TTL]
        for u in ues:
            u.pop("t", None)
        last = S["last_ind"]
        return {
            "ric": {"listening": sorted({e["port"] for e in eps}) == [E2_PORT, E42_PORT],
                    "endpoints": eps,
                    "loopbackOnly": bool(eps) and all(a == "127.0.0.1" for e in eps for a in e["addrs"]),
                    "commit": commit()},
            "e2": {"associations": len(assocs), "peers": assocs, "nodes": S["nodes"]},
            "xapp": {"name": "xapp_kpm_moni", "running": S["pid"] is not None, "pid": S["pid"], "starts": S["starts"],
                     "subscriptions": S["subscribed"], "indications": S["indications"],
                     "lastIndicationAgeS": round(now - last, 1) if last else None, "latencyUs": S["latency_us"],
                     "error": S["error"], "exits": S["exits"][-3:]},
            "ues": sorted(ues, key=lambda u: u["amfUeNgapId"]),
            "cell": {k: v for k, v in S["cell"].items() if k != "t"} if S["cell"].get("t", 0) > now - UE_TTL else {},
            "time": now,
        }


def metrics():
    s = status()
    L = []

    def g(name, help_, v, labels=""):
        if v is None:
            return
        if not any(x.startswith("# HELP " + name + " ") for x in L):
            L.append("# HELP %s %s" % (name, help_))
            L.append("# TYPE %s gauge" % name)
        L.append("%s%s %s" % (name, labels, float(v)))
    g("flexric_ric_listening", "1 if the nearRT-RIC listens on the E2 and E42 ports", int(s["ric"]["listening"]))
    g("flexric_ric_loopback_only", "1 if every RIC endpoint is bound to 127.0.0.1", int(s["ric"]["loopbackOnly"]))
    g("flexric_e2_associations", "Established SCTP associations on the E2 port (E2 nodes)", s["e2"]["associations"])
    g("flexric_e2_nodes", "E2 nodes the KPM xApp saw at its start", s["e2"]["nodes"])
    x = s["xapp"]
    g("flexric_xapp_running", "1 while the KPM monitor xApp runs", int(x["running"]))
    g("flexric_xapp_starts", "KPM xApp starts since the relay started", x["starts"])
    g("flexric_kpm_indications", "KPM indications received since the relay started", x["indications"])
    g("flexric_kpm_last_indication_age_seconds", "Seconds since the last KPM indication", x["lastIndicationAgeS"])
    g("flexric_kpm_latency_us", "Latency of the last KPM indication (xApp receive - collect start)", x["latencyUs"])
    for u in s["ues"]:
        lab = '{ue="%s"}' % u["amfUeNgapId"]
        for meas, (key, name) in UE_MEAS.items():
            g(name, "KPM %s of the UE (latest report)" % meas, u.get(key), lab)
    g("flexric_kpm_rrc_conn_mean", "KPM RRC.ConnMean of the cell", s["cell"].get("rrcConnMean"))
    return "\n".join(L) + "\n"


def token_ok(given):
    try:
        with open(TOKEN_FILE) as f:
            want = f.read().strip()
    except OSError:
        return False
    return bool(given) and bool(want) and hmac.compare_digest(given.encode(), want.encode())


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        b = (json.dumps(body) if ctype == "application/json" else body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self.send(200, "ok", "text/plain")
        if path not in ("/status", "/metrics"):
            return self.send(404, {"error": "not found"})
        given = self.headers.get("X-Relay-Token", "")
        auth = self.headers.get("Authorization", "")
        if not given and auth.startswith("Bearer "):
            given = auth[7:].strip()
        if not token_ok(given):
            print(time.strftime("%FT%TZ", time.gmtime()), "REFUSED bad token from", self.client_address[0], flush=True)
            return self.send(401, {"error": "bad token"})
        if path == "/status":
            return self.send(200, status())
        return self.send(200, metrics(), "text/plain; version=0.0.4")

    def do_POST(self):
        return self.send(405, {"error": "read only"})

    do_PUT = do_DELETE = do_PATCH = do_POST

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    threading.Thread(target=supervisor, daemon=True).start()
    print("FlexRIC relay on %s:%d, xApp: %s" % (BIND, PORT, " ".join(XAPP)), flush=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
