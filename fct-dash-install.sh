#!/usr/bin/env bash
# FCT 5G testbed dashboard installer v0.7.3 (D2-D6, Uu events, message flow oldest first, iperf3 watchdog v2).
# Run on REDLAB:  bash fct-dash-install.sh
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ran" "$TMP/core"

cat > "$TMP/capture.py" <<'FILEEOF'
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
FILEEOF
cat > "$TMP/n2-capture.yaml" <<'FILEEOF'
# N2 capture service for the dashboard. Runs on the RAN host (FCT0173).
# It only listens: tshark on SCTP port 38412, results kept in memory.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n2-capture
  namespace: fct-dash
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: n2-capture
  template:
    metadata:
      labels:
        app: n2-capture
      annotations:
        fct-dash/code-hash: "CODE_HASH"
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      containers:
      - name: capture
        image: alpine:3.20
        command: ["sh", "-c", "apk add --no-cache tshark python3 >/dev/null && exec python3 /app/capture.py"]
        env:
        - name: PORT
          value: "8091"
        - name: GNB_IP
          value: 10.0.129.7
        - name: PYTHONUNBUFFERED
          value: "1"
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8091
          initialDelaySeconds: 10
          periodSeconds: 5
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: "1", memory: 512Mi}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            add: ["NET_RAW", "NET_ADMIN"]
        volumeMounts:
        - name: app
          mountPath: /app
          readOnly: true
      volumes:
      - name: app
        configMap:
          name: n2-capture-app
FILEEOF
cat > "$TMP/ran-control.yaml" <<'FILEEOF'
# Controller account for the dashboard (RAN cluster). It may only read
# deployments and change the replica count of four named deployments.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fct-dash-controller
  namespace: fct-dash
---
apiVersion: v1
kind: Secret
metadata:
  name: fct-dash-controller-token
  namespace: fct-dash
  annotations:
    kubernetes.io/service-account.name: fct-dash-controller
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: fct-dash-scale
  namespace: default
rules:
- apiGroups: ["apps"]
  resources: ["deployments/scale"]
  resourceNames: ["oai-gnb", "oai-nr-ue", "speedtest-dl", "speedtest-ul"]
  verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: fct-dash-scale
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: fct-dash-scale
subjects:
- kind: ServiceAccount
  name: fct-dash-controller
  namespace: fct-dash
---
# Speed-test clients. They run iperf3 through the UE tunnel while scaled to 1.
# Same watchdog as the servers.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: speedtest-dl
  namespace: default
spec:
  replicas: 0
  selector: {matchLabels: {app: speedtest-dl}}
  template:
    metadata: {labels: {app: speedtest-dl}}
    spec:
      hostNetwork: true
      terminationGracePeriodSeconds: 2
      containers:
      - name: iperf
        image: alpine:3.20
        command: ["sh", "-c", "apk add --no-cache iperf3 >/dev/null\n# run IPERF3_ARGS... : loop iperf3 forever under a watchdog that restarts it when\n#  (a) it reports 5 one-second intervals in a row with 0 bytes (peer vanished mid-test), or\n#  (b) a connection on the test port is open but the log has not moved for 10 s\n#      (peer vanished during test setup, before any interval was reported).\nrun(){\n  L=/tmp/iperf-$$.log\n  PORT=5201; prev=\"\"; for a in \"$@\"; do [ \"$prev\" = \"-p\" ] && PORT=$a; prev=$a; done\n  HEX=$(printf '%04X' $PORT)\n  while true; do\n    : > $L\n    iperf3 \"$@\" -i 1 --forceflush --logfile $L & P=$!\n    tail -f $L & T=$!\n    last=0; still=0\n    while kill -0 $P 2>/dev/null; do\n      sleep 1\n      size=$(wc -c < $L)\n      # count seconds without log progress, but only while a connection on the test port is open\n      if [ \"$size\" = \"$last\" ] && cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qE \":$HEX [0-9A-F]+:[0-9A-F]+ 01 |:[0-9A-F]+ [0-9A-F]+:$HEX 01 \"; then\n        still=$((still+1)); else still=0; fi\n      last=$size; why=\"\"\n      [ \"$(tail -n 5 $L | grep -c ' 0.00 Bytes')\" -ge 5 ] && why=\"5 s without data\"\n      [ $still -ge 10 ] && why=\"connection open but no progress for 10 s\"\n      if [ -n \"$why\" ]; then\n        echo \"watchdog: $why, restarting iperf3\"; kill $P; sleep 1; kill -9 $P 2>/dev/null\n      fi\n    done\n    wait $P 2>/dev/null; sleep 1; kill $T 2>/dev/null   # let tail print the summary first\n  done\n}\nrun -c 10.45.0.1 -p 5201 -B 10.45.0.3 --bind-dev oaitun_ue1 -t 600 --connect-timeout 3000 --snd-timeout 5000 -R --rcv-timeout 5000\n"]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: speedtest-ul
  namespace: default
spec:
  replicas: 0
  selector: {matchLabels: {app: speedtest-ul}}
  template:
    metadata: {labels: {app: speedtest-ul}}
    spec:
      hostNetwork: true
      terminationGracePeriodSeconds: 2
      containers:
      - name: iperf
        image: alpine:3.20
        command: ["sh", "-c", "apk add --no-cache iperf3 >/dev/null\n# run IPERF3_ARGS... : loop iperf3 forever under a watchdog that restarts it when\n#  (a) it reports 5 one-second intervals in a row with 0 bytes (peer vanished mid-test), or\n#  (b) a connection on the test port is open but the log has not moved for 10 s\n#      (peer vanished during test setup, before any interval was reported).\nrun(){\n  L=/tmp/iperf-$$.log\n  PORT=5201; prev=\"\"; for a in \"$@\"; do [ \"$prev\" = \"-p\" ] && PORT=$a; prev=$a; done\n  HEX=$(printf '%04X' $PORT)\n  while true; do\n    : > $L\n    iperf3 \"$@\" -i 1 --forceflush --logfile $L & P=$!\n    tail -f $L & T=$!\n    last=0; still=0\n    while kill -0 $P 2>/dev/null; do\n      sleep 1\n      size=$(wc -c < $L)\n      # count seconds without log progress, but only while a connection on the test port is open\n      if [ \"$size\" = \"$last\" ] && cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qE \":$HEX [0-9A-F]+:[0-9A-F]+ 01 |:[0-9A-F]+ [0-9A-F]+:$HEX 01 \"; then\n        still=$((still+1)); else still=0; fi\n      last=$size; why=\"\"\n      [ \"$(tail -n 5 $L | grep -c ' 0.00 Bytes')\" -ge 5 ] && why=\"5 s without data\"\n      [ $still -ge 10 ] && why=\"connection open but no progress for 10 s\"\n      if [ -n \"$why\" ]; then\n        echo \"watchdog: $why, restarting iperf3\"; kill $P; sleep 1; kill -9 $P 2>/dev/null\n      fi\n    done\n    wait $P 2>/dev/null; sleep 1; kill $T 2>/dev/null   # let tail print the summary first\n  done\n}\nrun -c 10.45.0.1 -p 5202 -B 10.45.0.3 --bind-dev oaitun_ue1 -t 600 --connect-timeout 3000 --snd-timeout 5000\n"]
FILEEOF
cat > "$TMP/app.py" <<'FILEEOF'
#!/usr/bin/env python3
"""FCT 5G testbed dashboard - backend (D2: topology).

Standard library only, so it runs on a plain python:3.12-alpine image.
Read-only: it lists pods and reads pod logs in two Kubernetes clusters
(core on FCT0172, RAN on FCT0173) with the fct-dash-reader account.
"""
import collections
import csv
import io
import hmac
import json
import math
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("PORT", "8080"))
MOCK = os.environ.get("MOCK") == "1"
# The radio mode is a server-side setting. The browser can only read it.
RADIO_MODE = os.environ.get("RADIO_MODE", "rfsim")

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
CORE_NS = os.environ.get("CORE_NAMESPACE", "open5gs")
RAN_NS = os.environ.get("RAN_NAMESPACE", "default")
CACHE_SECONDS = 2.0
NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$")


class Cluster:
    """Minimal Kubernetes API client: GET only."""

    def __init__(self, name, server, token_file, ca_file):
        self.name = name
        self.server = server.rstrip("/")
        self.token_file = token_file
        self.ctx = ssl.create_default_context(cafile=ca_file)

    def patch(self, path, body, token_file=None, timeout=6):
        with open(token_file or self.token_file) as f:
            token = f.read().strip()
        req = urllib.request.Request(
            self.server + path, data=json.dumps(body).encode(), method="PATCH",
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/merge-patch+json"})
        with urllib.request.urlopen(req, context=self.ctx, timeout=timeout) as r:
            return json.loads(r.read())

    def get(self, path, raw=False, timeout=4):
        with open(self.token_file) as f:
            token = f.read().strip()
        req = urllib.request.Request(
            self.server + path, headers={"Authorization": "Bearer " + token}
        )
        with urllib.request.urlopen(req, context=self.ctx, timeout=timeout) as r:
            body = r.read()
        return body.decode("utf-8", "replace") if raw else json.loads(body)


def make_clusters():
    """Build both clients. A cluster that cannot be set up is reported, not fatal."""
    specs = {
        "core": (lambda: Cluster(
            "core",
            os.environ.get("CORE_SERVER", "https://kubernetes.default.svc"),
            os.environ.get("CORE_TOKEN_FILE", SA_DIR + "/token"),
            os.environ.get("CORE_CA_FILE", SA_DIR + "/ca.crt")), CORE_NS),
        "ran": (lambda: Cluster(
            "ran",
            open(os.environ.get("RAN_SERVER_FILE", "/etc/fct-dash/ran/server")).read().strip(),
            os.environ.get("RAN_TOKEN_FILE", "/etc/fct-dash/ran/token"),
            os.environ.get("RAN_CA_FILE", "/etc/fct-dash/ran/ca.crt")), RAN_NS),
    }
    out = {}
    for name, (build, ns) in specs.items():
        try:
            out[name] = (build(), ns, None)
        except Exception as e:
            out[name] = (None, ns, f"client not configured: {e}")
    return out


def role_of(cluster, pod_name):
    """Map a pod name to the network function it runs."""
    if cluster == "core":
        m = re.match(r"^open5gs-([a-z0-9]+)-", pod_name)
        return m.group(1) if m else None
    if "gnb" in pod_name:
        return "gnb"
    if "nr-ue" in pod_name or re.search(r"(^|-)ue(-|$)", pod_name):
        return "ue"
    return None


def summarize(cluster, pod):
    meta, spec, st = pod["metadata"], pod.get("spec", {}), pod.get("status", {})
    cs = st.get("containerStatuses") or []
    ready = bool(cs) and all(c.get("ready") for c in cs)
    phase = st.get("phase", "Unknown")
    deleting = "deletionTimestamp" in meta
    if deleting:
        state = "stopping"
    elif phase == "Running" and ready:
        state = "running"
    elif phase in ("Pending", "Running"):
        state = "starting"
    else:
        state = "failed"
    waiting = [c["state"]["waiting"].get("reason") for c in cs if "waiting" in c.get("state", {})]
    return {
        "cluster": cluster,
        "pod": meta["name"],
        "role": role_of(cluster, meta["name"]),
        "state": state,
        "reason": waiting[0] if waiting else None,
        "ip": st.get("podIP"),
        "node": spec.get("nodeName"),
        "restarts": sum(c.get("restartCount", 0) for c in cs),
        "started": st.get("startTime"),
    }



# ---- D4: counts and UE radio KPIs from logs -------------------------------
RE_GNBS = re.compile(r"Number of gNBs is now (\d+)")
RE_GNB_UES = re.compile(r"Number of gNB-UEs is now (\d+)")
RE_IMSI_OK = re.compile(r"\[imsi-(\d+)\] Registration complete")
RE_HDR = re.compile(r"UE RNTI ([0-9a-fA-F]{4}) .*?PH (-?\d+) dB PCMAX (-?\d+) dBm, average RSRP (-?\d+)")
RE_CSI = re.compile(r"UE ([0-9a-fA-F]{4}): CSI \[CQI (\d+) RI (\d+)")
RE_DL = re.compile(r"UE ([0-9a-fA-F]{4}): dlsch_rounds .*?\(SNR ([-\d.]+)[^)]*\) RSSI ([-\d.]+), BLER ([\d.]+) MCS \(\d+\) (\d+)")
RE_UL = re.compile(r"UE ([0-9a-fA-F]{4}): ulsch_rounds .*?BLER ([\d.]+) MCS \(\d+\) (\d+).*?NPRB (\d+)\s+SNR ([-\d.]+).*?RSSI ([-\d.]+)")
RE_GP = re.compile(r"UE ([0-9a-fA-F]{4}): .*?goodput DL\s+([\d.]+) UL\s+([\d.]+)")


def last_int(regex, text):
    m = regex.findall(text)
    return int(m[-1]) if m else None


def parse_amf(text):
    imsis = RE_IMSI_OK.findall(text)
    return {"gnbs": last_int(RE_GNBS, text), "ues": last_int(RE_GNB_UES, text),
            "lastImsi": imsis[-1] if imsis else None}


def parse_gnb_stats(text):
    """Latest MAC statistics per RNTI, in the order the RNTIs were last seen."""
    ues, order = {}, []
    for line in text.splitlines():
        for rx, keys in ((RE_HDR, ("ph", "pcmax", "rsrp")), (RE_CSI, ("cqi", "ri")),
                         (RE_DL, ("snrPucch", "rssiDl", "blerDl", "mcsDl")),
                         (RE_UL, ("blerUl", "mcsUl", "nprbUl", "snrPusch", "rssiUl")),
                         (RE_GP, ("goodputDl", "goodputUl"))):
            m = rx.search(line)
            if m:
                rnti = m.group(1).lower()
                ue = ues.setdefault(rnti, {"rnti": rnti})
                for k, v in zip(keys, m.groups()[1:]):
                    ue[k] = float(v)
                if rnti in order:
                    order.remove(rnti)
                order.append(rnti)
                break
    return [ues[r] for r in order]


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.cached = None
        self.cached_at = 0.0
        self.clusters = None if MOCK else make_clusters()

    def snapshot(self):
        with self.lock:
            if self.cached and time.time() - self.cached_at < CACHE_SECONDS:
                return self.cached
            data = mock_state() if MOCK else self._collect()
            self.cached, self.cached_at = data, time.time()
            return data

    def _collect(self):
        out = {"time": now_iso(), "radioMode": RADIO_MODE, "pods": [], "errors": {}}
        for name, (cl, ns, err) in self.clusters.items():
            if err:
                out["errors"][name] = err
                continue
            try:
                items = cl.get(f"/api/v1/namespaces/{ns}/pods")["items"]
                out["pods"] += [summarize(name, p) for p in items]
            except Exception as e:  # report per cluster, keep the other one
                out["errors"][name] = describe_error(e)
        out["ran"] = self._ran_metrics(out["pods"])
        out["controls"] = self._controls()
        return out

    def _controls(self):
        """Replica state of the deployments the dashboard may scale."""
        res = {"enabled": CONTROL.enabled, "reason": CONTROL.reason, "radioMode": RADIO_MODE, "targets": {}}
        cl, ns, err = self.clusters["ran"]
        if err:
            return res
        try:
            for d in cl.get(f"/apis/apps/v1/namespaces/{ns}/deployments")["items"]:
                name = d["metadata"]["name"]
                if name in CONTROL.TARGETS:
                    res["targets"][name] = {"want": d["spec"].get("replicas", 0),
                                            "ready": d.get("status", {}).get("readyReplicas", 0) or 0}
        except Exception as e:
            res["reason"] = "Cannot read deployments: " + describe_error(e)
        return res

    def _ran_metrics(self, pods):
        """gNB/UE counts from the AMF log, radio KPIs from the gNB log."""
        res = {"gnbs": None, "ues": None, "lastImsi": None, "ueStats": [], "errors": []}
        amf = next((p for p in pods if p["cluster"] == "core" and p["role"] == "amf"), None)
        gnb = next((p for p in pods if p["cluster"] == "ran" and p["role"] == "gnb"
                    and p["state"] == "running"), None)
        if amf:
            try:
                res.update(parse_amf(self.logs("core", amf["pod"], 3000)))
            except Exception as e:
                res["errors"].append("AMF log: " + describe_error(e))
        if gnb:
            try:
                stats = parse_gnb_stats(self.logs("ran", gnb["pod"], 400))
                n = res["ues"] if res["ues"] is not None else len(stats)
                res["ueStats"] = stats[-n:] if n else []
            except Exception as e:
                res["errors"].append("gNB log: " + describe_error(e))
        else:
            res["gnbs"] = 0 if res["gnbs"] is None else res["gnbs"]
        return res

    def logs(self, cluster, pod, lines):
        if MOCK:
            return "\n".join(f"[MOCK] {pod} line {i}" for i in range(lines))
        cl, ns, err = self.clusters[cluster]
        if err:
            raise RuntimeError(err)
        q = urllib.parse.urlencode({"tailLines": lines})
        return cl.get(f"/api/v1/namespaces/{ns}/pods/{pod}/log?{q}", raw=True)


def describe_error(e):
    if isinstance(e, urllib.error.HTTPError):
        return f"API answered {e.code} {e.reason}"
    if isinstance(e, urllib.error.URLError):
        return f"API not reachable: {e.reason}"
    return f"{type(e).__name__}: {e}"


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def mock_state():
    t0 = "2026-09-21T08:00:00Z"
    core = ["amf", "ausf", "bsf", "nrf", "nssf", "pcf", "scp", "smf", "udm", "udr",
            "upf", "mongodb", "hss", "mme", "pcrf", "sgwc", "sgwu"]
    pods = []
    for i, nf in enumerate(core):
        state = "running"
        if nf == "bsf" and int(time.time() / 10) % 2:
            state = "missing"
        if state == "missing":
            continue
        pods.append({"cluster": "core", "pod": f"open5gs-{nf}-7bbc-{i:02d}x", "role": nf,
                     "state": state, "reason": None, "ip": f"192.168.181.{10 + i}",
                     "node": "fct0172-core", "restarts": 0, "started": t0})
    for role, pod in (("gnb", "oai-gnb-test"), ("ue", "oai-nr-ue-test")):
        if "CONTROL" in globals() and not CONTROL.mock["oai-gnb" if role == "gnb" else "oai-nr-ue"]:
            continue
        pods.append({"cluster": "ran", "pod": pod, "role": role, "state": "running",
                     "reason": None, "ip": "10.0.129.7", "node": "fct0173-real-ran",
                     "restarts": 0, "started": "2026-10-05T10:04:29Z"})
    ran = {"gnbs": 1, "ues": 1, "lastImsi": "001700000150652", "errors": [],
           "ueStats": [{"rnti": "5566", "ph": 57, "pcmax": 19, "rsrp": -43, "cqi": 15, "ri": 1,
                        "snrPucch": 16.7, "rssiDl": -37.3, "blerDl": 0.0, "mcsDl": 28,
                        "blerUl": 0.0, "mcsUl": 28, "nprbUl": 106, "snrPusch": 22.6, "rssiUl": -42.0,
                        "goodputDl": 90.2, "goodputUl": 2.98}]}
    ctl = {"enabled": True, "reason": None, "radioMode": RADIO_MODE,
           "targets": {t: {"want": n, "ready": n} for t, n in CONTROL.mock.items()}} if "CONTROL" in globals() else {}
    return {"time": now_iso(), "radioMode": RADIO_MODE, "pods": pods, "errors": {}, "ran": ran, "controls": ctl}


CAPTURE_URL = os.environ.get("CAPTURE_URL", "http://10.0.129.7:8091").rstrip("/")
MOCK_FLOW = [
    ("ul", "NGAP", "NGSetupRequest"), ("dl", "NGAP", "NGSetupResponse"),
    ("ul", "NGAP/NAS-5GS", "InitialUEMessage, Registration request"),
    ("dl", "NGAP/NAS-5GS", "DownlinkNASTransport, Authentication request"),
    ("ul", "NGAP/NAS-5GS", "UplinkNASTransport, Authentication response"),
    ("dl", "NGAP/NAS-5GS", "DownlinkNASTransport, Security mode command"),
    ("ul", "NGAP/NAS-5GS", "UplinkNASTransport"),
    ("dl", "NGAP/NAS-5GS", "InitialContextSetupRequest"),
    ("ul", "NGAP", "UERadioCapabilityInfoIndication"),
    ("ul", "NGAP", "InitialContextSetupResponse"),
    ("ul", "NGAP/NAS-5GS", "UplinkNASTransport"),
    ("dl", "NGAP/NAS-5GS", "PDUSessionResourceSetupRequest"),
    ("ul", "NGAP", "PDUSessionResourceSetupResponse"),
]


def mock_flow(after):
    """Emit one more mock message every 2 s so the panel can be tested."""
    n = min(len(MOCK_FLOW), int(time.time() / 2) % (len(MOCK_FLOW) + 4))
    t0 = time.time() - n * 0.4
    msgs = [{"seq": i + 1, "t": t0 + i * 0.4, "dir": d, "proto": p, "msg": m,
             "src": "10.0.129.7" if d == "ul" else "10.0.129.2",
             "dst": "10.0.129.2" if d == "ul" else "10.0.129.7"}
            for i, (d, p, m) in enumerate(MOCK_FLOW[:n])]
    return {"status": {"running": True}, "last": n, "messages": [m for m in msgs if m["seq"] > after]}



# ---- D5: per-UE KPI history, sampled once per second ----------------------
HISTORY_SECONDS = int(os.environ.get("HISTORY_SECONDS", "900"))
FIELDS = ["rsrp", "ph", "pcmax", "cqi", "ri", "snrPucch", "snrPusch", "rssiDl", "rssiUl",
          "mcsDl", "mcsUl", "blerDl", "blerUl", "nprbUl", "goodputDl", "goodputUl"]


class History:
    def __init__(self):
        self.lock = threading.Lock()
        self.by_rnti = {}

    def add(self, t, ue):
        with self.lock:
            d = self.by_rnti.setdefault(ue["rnti"], collections.deque(maxlen=HISTORY_SECONDS))
            d.append({"t": t, **{k: ue.get(k) for k in FIELDS}})

    def get(self, rnti, seconds):
        cut = time.time() - seconds
        with self.lock:
            if not rnti and self.by_rnti:  # newest UE by default
                rnti = max(self.by_rnti, key=lambda r: self.by_rnti[r][-1]["t"])
            rows = [r for r in self.by_rnti.get(rnti, []) if r["t"] >= cut]
            rntis = sorted(self.by_rnti, key=lambda r: -self.by_rnti[r][-1]["t"])
        return {"rnti": rnti, "rntis": rntis, "fields": FIELDS, "rows": rows}


HISTORY = History()


def sampler():
    """Read the newest gNB statistics every second and keep a rolling history."""
    while True:
        t0 = time.time()
        try:
            if MOCK:
                for ue in mock_stats(t0):
                    HISTORY.add(t0, ue)
            else:
                pods = STATE.snapshot().get("pods", [])
                gnb = next((p for p in pods if p["cluster"] == "ran" and p["role"] == "gnb"
                            and p["state"] == "running"), None)
                if gnb:
                    cl, ns, err = STATE.clusters["ran"]
                    if not err:
                        text = cl.get(f"/api/v1/namespaces/{ns}/pods/{gnb['pod']}/log?sinceSeconds=3", raw=True)
                        for ue in parse_gnb_stats(text):
                            if "goodputDl" in ue:
                                HISTORY.add(t0, ue)
        except Exception:
            pass  # a missed sample shows as a gap in the chart
        time.sleep(max(0.2, 1.0 - (time.time() - t0)))


def mock_stats(t):
    load = 1 if (t // 20) % 2 else 0
    noise = math.sin(t / 7)
    return [{"rnti": "5566", "rsrp": -43 + 2 * noise, "ph": 55 + 4 * noise, "pcmax": 19,
             "cqi": 15 - (2 if noise < -0.6 else 0), "ri": 1, "snrPucch": 16.5 + noise,
             "snrPusch": 22 + 1.5 * noise, "rssiDl": -37.3 + 0.3 * noise, "rssiUl": -41 + noise,
             "mcsDl": 28 if load else 9, "mcsUl": 28 if noise > -0.6 else 20,
             "blerDl": max(0, 0.02 * noise), "blerUl": max(0, 0.03 * -noise), "nprbUl": 106 if not load else 5,
             "goodputDl": 90 * load + 0.1, "goodputUl": 2.9 * load + 0.05}]


# ---- D6: controls (scale approved deployments only) -----------------------
class Control:
    """Starts and stops the approved RAN deployments by changing their replica
    count. The RAN-cluster account behind it may only scale these names; it
    cannot create pods or change a manifest, so it cannot reach the X410."""
    TARGETS = ("oai-gnb", "oai-nr-ue", "speedtest-dl", "speedtest-ul")

    def __init__(self):
        self.token_file = os.environ.get("CTL_TOKEN_FILE", "/etc/fct-dash/ctl/token")
        self.admin_file = os.environ.get("ADMIN_KEY_FILE", "/etc/fct-dash/admin/password")
        self.log = collections.deque(maxlen=50)
        self.lock = threading.Lock()
        self.enabled, self.reason = False, None
        if MOCK:
            self.enabled, self.mock = True, {t: 1 if t in ("oai-gnb", "oai-nr-ue") else 0 for t in self.TARGETS}
        elif RADIO_MODE != "rfsim":
            self.reason = "Controls are only offered in rfsim mode"
        elif not os.path.exists(self.token_file):
            self.reason = "Controller account not installed"
        elif not os.path.exists(self.admin_file):
            self.reason = "Admin password not set"
        else:
            self.enabled = True

    def check_key(self, key):
        if MOCK:
            return key == "demo"
        try:
            with open(self.admin_file) as f:
                want = f.read().strip()
        except OSError:
            return False
        return bool(key) and hmac.compare_digest(key, want)

    def scale(self, name, n):
        if name not in self.TARGETS or n not in (0, 1):
            raise ValueError("not an approved target")
        if MOCK:
            self.mock[name] = n
            return
        cl, ns, err = STATE.clusters["ran"]
        if err:
            raise RuntimeError(err)
        cl.patch(f"/apis/apps/v1/namespaces/{ns}/deployments/{name}/scale",
                 {"spec": {"replicas": n}}, token_file=self.token_file)

    def act(self, action):
        """Run one named action. Returns a sentence for the operator."""
        ready = lambda role: any(p["cluster"] == "ran" and p["role"] == role and p["state"] == "running"
                                 for p in STATE.snapshot()["pods"])
        steps = {
            "gnb-start": [("oai-gnb", 1)],
            "gnb-stop": [("speedtest-dl", 0), ("speedtest-ul", 0), ("oai-nr-ue", 0), ("oai-gnb", 0)],
            "ue-start": [("oai-nr-ue", 1)],
            "ue-stop": [("speedtest-dl", 0), ("speedtest-ul", 0), ("oai-nr-ue", 0)],
            "speed-dl": [("speedtest-ul", 0), ("speedtest-dl", 1)],
            "speed-ul": [("speedtest-dl", 0), ("speedtest-ul", 1)],
            "speed-stop": [("speedtest-dl", 0), ("speedtest-ul", 0)],
        }
        if action not in steps:
            raise ValueError("unknown action")
        if not MOCK:
            if action == "ue-start" and not ready("gnb"):
                return False, "Start the gNB first; the UE needs a running cell."
            if action.startswith("speed-") and action != "speed-stop" and not ready("ue"):
                return False, "Start the UE first; the speed test runs through its tunnel."
        with self.lock:
            for name, n in steps[action]:
                self.scale(name, n)
            self.log.append({"t": now_iso(), "action": action})
        print(f"{now_iso()} CONTROL {action}", flush=True)
        return True, {"gnb-start": "gNB starting. NG Setup appears in the message flow within seconds.",
                      "gnb-stop": "gNB, UE and speed tests stopping.",
                      "ue-start": "UE starting. Registration appears in the message flow.",
                      "ue-stop": "UE and speed tests stopping.",
                      "speed-dl": "Downlink speed test running.",
                      "speed-ul": "Uplink speed test running.",
                      "speed-stop": "Speed test stopped."}[action]


# ---- Uu events (random access and RRC setup) from gNB and UE logs ----------
UU_RULES = [  # (pod role, regex, direction, protocol, label template)
    ("ue", r"Initial sync successful, PCI: (\d+)", "dl", "PHY", "SSB found, PCI {0}"),
    ("ue", r"SIB1 decoded", "dl", "RRC", "SIB1 decoded"),
    ("gnb", r"Initiating RA procedure with preamble (\d+)", "ul", "PRACH", "Msg1: preamble {0}"),
    ("gnb", r"Generating RA-Msg2 DCI", "dl", "MAC", "Msg2: Random Access Response"),
    ("gnb", r"PUSCH with TC_RNTI 0x([0-9a-f]+) received correctly", "ul", "MAC/RRC", "Msg3: RRCSetupRequest, TC-RNTI 0x{0}"),
    ("gnb", r"UE ([0-9a-f]+) Generate Msg4", "dl", "MAC/RRC", "Msg4: RRCSetup and contention resolution"),
    ("gnb", r"Received Ack of Msg4", "ul", "MAC", "Msg4 acknowledged: random access complete"),
    ("gnb", r"Received RRCSetupComplete", "ul", "RRC", "RRCSetupComplete, carries the Registration request"),
]
UU_RULES = [(r, re.compile(x), d, p, l) for r, x, d, p, l in UU_RULES]


def parse_k8s_ts(ts):
    """'2026-10-06T06:44:55.996342288Z' -> epoch seconds (microsecond precision)."""
    main, _, frac = ts.rstrip("Z").partition(".")
    return datetime.fromisoformat(main).replace(tzinfo=timezone.utc).timestamp() + float("0." + (frac or "0")[:6])


class UuEvents:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = collections.deque(maxlen=500)
        self.seen = collections.deque(maxlen=2000)
        self.seq = 0

    def ingest(self, role, text):
        for line in text.splitlines():
            ts, _, msg = line.partition(" ")
            for r, rx, d, proto, label in UU_RULES:
                if r != role:
                    continue
                m = rx.search(msg)
                if not m:
                    continue
                key = (role, ts, label)
                with self.lock:
                    if key in self.seen:
                        break
                    self.seen.append(key)
                    self.seq += 1
                    self.events.append({"seq": self.seq, "t": parse_k8s_ts(ts), "dir": d, "iface": "Uu",
                                        "proto": proto, "msg": label.format(*m.groups()), "src": role})
                break

    def after(self, seq):
        with self.lock:
            return {"last": self.seq, "events": [e for e in self.events if e["seq"] > seq]}


UU = UuEvents()


def uu_collector():
    while True:
        try:
            if MOCK:
                mock_uu()
            else:
                pods = STATE.snapshot().get("pods", [])
                cl, ns, err = STATE.clusters["ran"]
                if not err:
                    for p in pods:
                        if p["cluster"] == "ran" and p["role"] in ("gnb", "ue") and p["state"] == "running":
                            text = cl.get(f"/api/v1/namespaces/{ns}/pods/{p['pod']}/log?timestamps=true&sinceSeconds=6", raw=True)
                            UU.ingest(p["role"], text)
        except Exception:
            pass
        time.sleep(1)


def mock_uu():
    n = int(time.time() / 2) % 17
    if n == 3:
        t = datetime.now(timezone.utc)
        base = t.strftime("%Y-%m-%dT%H:%M:%S.")
        lines = {"ue": ["Initial sync successful, PCI: 0", "[NR_RRC] SIB1 decoded"],
                 "gnb": ["Initiating RA procedure with preamble 16, energy 60.5 dB", "Generating RA-Msg2 DCI, RA RNTI 0x10f",
                         "188.19 PUSCH with TC_RNTI 0xfcff received correctly", "UE fcff Generate Msg4: feedback",
                         "UE fcff: Received Ack of Msg4. CBRA procedure succeeded", "Received RRCSetupComplete (RRC_CONNECTED reached)"]}
        for role, ls in lines.items():
            off = 0 if role == "ue" else 2
            UU.ingest(role, "\n".join(f"{base}{(off + i) * 4:03d}000000Z {l}" for i, l in enumerate(ls)))

STATE = State()
CONTROL = Control()


class Handler(BaseHTTPRequestHandler):
    server_version = "fct-dash/0.2"

    def log_message(self, fmt, *args):  # quiet access log
        pass

    def send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        if url.path != "/api/control":
            return self.send(404, "Not found", "text/plain")
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 4096)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self.send(400, json.dumps({"ok": False, "msg": "Bad request"}), "application/json")
        if not CONTROL.enabled:
            return self.send(403, json.dumps({"ok": False, "msg": CONTROL.reason}), "application/json")
        if not CONTROL.check_key(self.headers.get("X-Admin-Key", "")):
            time.sleep(1)  # slows down guessing
            return self.send(401, json.dumps({"ok": False, "msg": "Wrong admin password"}), "application/json")
        if body.get("action") == "check":
            return self.send(200, json.dumps({"ok": True, "msg": "Controls unlocked"}), "application/json")
        try:
            ok, msg = CONTROL.act(body.get("action", ""))
            with STATE.lock:
                STATE.cached_at = 0  # show the change on the next poll
            return self.send(200 if ok else 409, json.dumps({"ok": ok, "msg": msg}), "application/json")
        except Exception as e:
            return self.send(502, json.dumps({"ok": False, "msg": "Kubernetes refused: " + describe_error(e)}), "application/json")

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(url.query)
        if url.path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if url.path == "/api/state":
            return self.send(200, json.dumps(STATE.snapshot()), "application/json")
        if url.path == "/api/logs":
            cluster = (q.get("cluster") or [""])[0]
            pod = (q.get("pod") or [""])[0]
            try:
                lines = max(10, min(500, int((q.get("lines") or ["80"])[0])))
            except ValueError:
                lines = 80
            if cluster not in ("core", "ran") or not NAME_RE.match(pod):
                return self.send(400, "Unknown cluster or invalid pod name", "text/plain")
            try:
                return self.send(200, STATE.logs(cluster, pod, lines), "text/plain; charset=utf-8")
            except Exception as e:
                return self.send(502, describe_error(e), "text/plain")
        if url.path in ("/api/history", "/api/history.csv"):
            rnti = (q.get("rnti") or [""])[0].lower()
            if rnti and not re.fullmatch(r"[0-9a-f]{1,8}", rnti):
                return self.send(400, "Invalid RNTI", "text/plain")
            try:
                seconds = max(30, min(HISTORY_SECONDS, int((q.get("seconds") or ["300"])[0])))
            except ValueError:
                seconds = 300
            h = HISTORY.get(rnti, seconds)
            if url.path.endswith(".csv"):
                buf = io.StringIO()
                w = csv.writer(buf)
                w.writerow(["time_utc", "rnti", "radio_mode"] + FIELDS)
                for r in h["rows"]:
                    ts = datetime.fromtimestamp(r["t"], timezone.utc).isoformat(timespec="seconds")
                    w.writerow([ts, h["rnti"], RADIO_MODE] + [r.get(k) for k in FIELDS])
                return self.send(200, buf.getvalue(), "text/csv; charset=utf-8")
            return self.send(200, json.dumps(h), "application/json")
        if url.path == "/api/uu":
            try:
                after = int((q.get("after") or ["0"])[0])
            except ValueError:
                after = 0
            return self.send(200, json.dumps(UU.after(after)), "application/json")
        if url.path == "/api/flow":
            try:
                after = int((q.get("after") or ["0"])[0])
            except ValueError:
                after = 0
            if MOCK:
                return self.send(200, json.dumps(mock_flow(after)), "application/json")
            try:
                req = urllib.request.Request(f"{CAPTURE_URL}/messages?after={after}")
                with urllib.request.urlopen(req, timeout=3) as r:
                    return self.send(200, r.read(), "application/json")
            except Exception as e:
                return self.send(502, json.dumps({"error": "Capture service: " + describe_error(e)}), "application/json")
        if url.path == "/healthz":
            return self.send(200, "ok", "text/plain")
        self.send(404, "Not found", "text/plain")


if __name__ == "__main__":
    print(f"fct-dash on :{PORT} (mock={MOCK}, radio mode={RADIO_MODE})", flush=True)
    if not MOCK:
        STATE.snapshot()
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=uu_collector, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
FILEEOF
cat > "$TMP/index.html" <<'FILEEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FCT 5G Testbed</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Barlow:wght@400;500;600&family=Barlow+Semi+Condensed:wght@500;600;700&display=swap" rel="stylesheet">
<style>
:root {
  --bg: #E9EEF2;
  --panel: #F8FAFB;
  --ink: #18222D;
  --muted: #5B6875;
  --line: #A9B5C0;
  --ok: #157A6E;
  --warn: #B7791F;
  --fault: #C23B22;
  --unknown: #8A96A3;
  --rf: #2B59C3;
  --sans: "Barlow", system-ui, sans-serif;
  --cond: "Barlow Semi Condensed", "Barlow", system-ui, sans-serif;
  --mono: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.45 var(--sans); }
header {
  display: flex; flex-wrap: wrap; gap: 16px 32px; align-items: stretch; justify-content: space-between;
  padding: 20px 28px 16px;
}
.title h1 { margin: 0; font: 700 30px/1.1 var(--cond); letter-spacing: .2px; }
.title p { margin: 4px 0 0; color: var(--muted); }
.radio {
  display: flex; align-items: center; gap: 14px; padding: 10px 18px 10px 14px;
  background: var(--panel); border-left: 6px solid var(--rf); border-radius: 4px; min-width: 300px;
}
.radio .mode { font: 700 24px/1 var(--cond); color: var(--rf); }
.radio .note { color: var(--muted); font-size: 13px; line-height: 1.3; }
.radio.live { border-left-color: var(--fault); }
.radio.live .mode { color: var(--fault); }
.summary {
  display: flex; flex-wrap: wrap; gap: 6px 22px; align-items: baseline;
  padding: 10px 28px; background: var(--panel); border-top: 1px solid #D5DCE2; border-bottom: 1px solid #D5DCE2;
}
.summary b { font: 600 17px var(--cond); }
.summary .ok { color: var(--ok); } .summary .bad { color: var(--fault); } .summary .mid { color: var(--warn); }
.summary .updated { margin-left: auto; color: var(--muted); font-size: 13px; }
.summary .updated.stale { color: var(--fault); font-weight: 600; }
.kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; padding: 14px 28px 0; }
.kpi { display: flex; align-items: center; gap: 14px; background: var(--panel); border: 1px solid #D5DCE2; border-radius: 6px; padding: 10px 16px; }
.kpi .v { font: 700 34px/1 var(--cond); font-variant-numeric: tabular-nums; min-width: 2.2ch; }
.kpi .l { font: 600 14px/1.25 var(--sans); }
.kpi .l small { display: block; font-weight: 400; font-size: 12px; color: var(--muted); }
@media (max-width: 900px) { .kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); padding: 12px 16px 0; } }
.uecard rect { fill: var(--panel); stroke: #C7D0D8; }
.uecard .h { font: 700 15px var(--cond); fill: var(--ink); }
.uecard .k, .uecard .h { white-space: pre; }
.uecard .k { font: 400 12.5px var(--sans); fill: var(--muted); }
.uecard .k tspan.n { fill: var(--ink); font-weight: 600; }

.tabs { display: flex; gap: 4px; margin-top: 12px; }
.tab { background: transparent; border: 1px solid transparent; border-bottom: 3px solid transparent; border-radius: 4px 4px 0 0; padding: 6px 14px; font: 600 15px var(--sans); color: var(--muted); }
.tab.on { color: var(--ink); border-bottom-color: var(--rf); background: var(--panel); }
.uepage { padding: 14px 28px 28px; }
.uebar { display: flex; flex-wrap: wrap; gap: 10px 18px; align-items: center; margin-bottom: 14px; }
.uebar select { font: 600 14px var(--sans); padding: 5px 8px; border-radius: 4px; border: 1px solid #C7D0D8; background: var(--panel); }
.seg { display: inline-flex; border: 1px solid #C7D0D8; border-radius: 4px; overflow: hidden; }
.seg button { border: 0; border-radius: 0; background: var(--panel); }
.seg button.on { background: var(--ink); color: #fff; }
.btn { font: 600 14px var(--sans); color: var(--ink); background: #E3E9EE; border: 1px solid #C7D0D8; border-radius: 4px; padding: 6px 12px; text-decoration: none; }
.uenote { color: var(--muted); font-size: 13px; }
.uetiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(170px, 1fr)); gap: 10px; margin-bottom: 16px; }
.ut { background: var(--panel); border: 1px solid #D5DCE2; border-radius: 6px; padding: 10px 14px; }
.ut .n { font: 600 13px var(--sans); color: var(--muted); }
.ut .v { font: 700 28px/1.15 var(--cond); font-variant-numeric: tabular-nums; }
.ut .v small { font: 600 13px var(--sans); color: var(--muted); margin-left: 3px; }
.ut .r { font-size: 12px; color: var(--muted); font-variant-numeric: tabular-nums; }
.charts { display: grid; grid-template-columns: repeat(auto-fill, minmax(380px, 1fr)); gap: 12px; }
.chart { background: var(--panel); border: 1px solid #D5DCE2; border-radius: 6px; padding: 10px 12px 6px; }
.chart h3 { margin: 0; font: 700 17px var(--cond); display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap; }
.chart h3 small { font: 400 12px var(--sans); color: var(--muted); }
.chart .lg { margin-left: auto; display: flex; gap: 12px; font: 600 12px var(--sans); color: var(--ink); }
.chart .lg i { display: inline-block; width: 14px; height: 3px; border-radius: 2px; vertical-align: middle; margin-right: 5px; }
.chart svg { width: 100%; height: auto; display: block; }
.chart .grid { stroke: #E1E6EA; stroke-width: 1; }
.chart .axis { font: 400 11px var(--sans); fill: var(--muted); }
.chart .ln { fill: none; stroke-width: 2; stroke-linejoin: round; stroke-linecap: round; }
.chart .xh { stroke: var(--muted); stroke-width: 1; stroke-dasharray: 3 3; }
.chart .empty { font: 400 13px var(--sans); fill: var(--muted); }
.tip { position: fixed; pointer-events: none; background: var(--ink); color: #fff; font: 12px/1.45 var(--sans); padding: 6px 9px; border-radius: 4px; z-index: 6; white-space: nowrap; }
@media (max-width: 700px) { .uepage { padding: 12px 12px 20px; } .charts { grid-template-columns: 1fr; } }

.ctl { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; margin: 12px 28px 0; padding: 10px 14px; background: var(--panel); border: 1px solid #D5DCE2; border-radius: 6px; }
.ctl-t { font: 700 17px var(--cond); }
.unlock { display: flex; gap: 6px; }
.unlock input { font: 14px var(--sans); padding: 5px 8px; border: 1px solid #C7D0D8; border-radius: 4px; width: 160px; }
.ctl .grp { display: flex; align-items: center; gap: 4px; }
.ctl .grp span { font: 600 13px var(--sans); color: var(--muted); margin-right: 4px; }
.ctl button:disabled { opacity: .45; cursor: not-allowed; }
.ctl button.active { background: var(--ink); color: #fff; border-color: var(--ink); }
.ctl-msg { font-size: 13px; color: var(--muted); }
.ctl-msg.bad { color: var(--fault); } .ctl-msg.ok { color: var(--ok); }
@media (max-width: 700px) { .ctl { margin: 12px 16px 0; } }
.errors { margin: 12px 28px 0; }
.errors div { padding: 8px 12px; background: #F6E3DF; color: #7A1F0E; border-left: 4px solid var(--fault); margin-bottom: 6px; border-radius: 3px; }
main { padding: 8px 20px 28px; display: grid; grid-template-columns: minmax(0, 1fr) 640px; gap: 18px; align-items: start; }
@media (max-width: 1640px) { main { grid-template-columns: minmax(0, 1fr); } }
.topo-wrap { min-width: 0; }
svg#topo { width: 100%; height: auto; display: block; max-width: 1320px; margin: 0 auto; }
.flow { background: var(--panel); border: 1px solid #D5DCE2; border-radius: 6px; display: flex; flex-direction: column; max-height: calc(100vh - 190px); min-height: 360px; }
.flow-head { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 14px; padding: 12px 16px; border-bottom: 1px solid #D5DCE2; }
.flow-head h2 { margin: 0; font: 700 20px var(--cond); }
.flow-state { flex: 1; color: var(--muted); font-size: 13px; }
.flow-state.ok { color: var(--ok); } .flow-state.bad { color: var(--fault); }
.flow-scroll { overflow: auto; flex: 1; }
.flow table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.flow td.m { overflow-wrap: anywhere; }
.flow th { position: sticky; top: 0; background: #EEF2F5; text-align: left; font: 600 13px var(--sans); color: var(--muted); padding: 7px 10px; }
.flow td { padding: 6px 10px; border-top: 1px solid #E3E8EC; vertical-align: top; }
.flow td.t { font-variant-numeric: tabular-nums; color: var(--muted); white-space: nowrap; }
.flow td.d { white-space: nowrap; font-weight: 600; }
.flow td.d.ul { color: var(--rf); } .flow td.d.dl { color: var(--ok); }
.flow td.i { font-weight: 600; color: var(--muted); }
.flow tr.uu td.i { color: #8A4FBF; }
.flow tr.uu td:first-child { box-shadow: inset 3px 0 0 #8A4FBF; }
.flow td.p { color: var(--muted); white-space: nowrap; }
.flow td.m b { font-weight: 600; }
.flow tr.milestone td { background: #EAF1FB; }
.flow tr.bad td { background: #F6E3DF; }
.flow-empty { margin: 0; padding: 18px 16px; color: var(--muted); }
@media (prefers-reduced-motion: no-preference) { .flow tr.new td { animation: flash 1.2s ease-out; } }
@keyframes flash { from { background: #FFF3C4; } }
.wire { fill: none; stroke: var(--line); stroke-width: 1.6; }
.wire.dash { stroke-dasharray: 5 5; }
.wire.radio { stroke: var(--rf); stroke-dasharray: 3 6; stroke-width: 2.2; stroke-linecap: round; }
.ifname { font: 500 12px var(--sans); fill: var(--muted); }
.section { font: 600 14px var(--cond); fill: var(--muted); }
.tile { cursor: pointer; outline: none; }
.tile rect.body { fill: var(--panel); stroke: #C7D0D8; stroke-width: 1; }
.tile:hover rect.body, .tile:focus rect.body { stroke: var(--ink); stroke-width: 1.6; }
.tile .name { font: 700 18px var(--cond); fill: var(--ink); }
.tile .status { font: 600 13px var(--sans); }
.tile .meta { font: 400 12px var(--sans); fill: var(--muted); }
.tile.small .name { font-size: 14px; }
.dn rect { fill: none; stroke: var(--line); stroke-dasharray: 4 4; }
.dn text { fill: var(--muted); }
/* Log drawer */
aside {
  position: fixed; top: 0; right: 0; bottom: 0; width: min(640px, 100vw);
  background: var(--panel); box-shadow: -2px 0 0 #C7D0D8; display: none; flex-direction: column; z-index: 5;
}
aside.open { display: flex; }
aside .bar { display: flex; gap: 10px; align-items: center; padding: 14px 18px; border-bottom: 1px solid #D5DCE2; }
aside .bar h2 { margin: 0; font: 700 20px var(--cond); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
aside .bar small { display: block; font: 400 13px var(--sans); color: var(--muted); }
button {
  font: 600 14px var(--sans); color: var(--ink); background: #E3E9EE; border: 1px solid #C7D0D8;
  border-radius: 4px; padding: 6px 12px; cursor: pointer;
}
button:hover { background: #D6DEE5; }
button:focus-visible, .tile:focus-visible { outline: 3px solid var(--rf); outline-offset: 2px; }
aside pre {
  flex: 1; margin: 0; padding: 14px 18px; overflow: auto; font: 12px/1.5 var(--mono);
  white-space: pre-wrap; word-break: break-all; background: #FDFEFE;
}
@media (max-width: 700px) {
  header { padding: 14px 16px; } .summary { padding: 10px 16px; } main { padding: 8px 6px 20px; }
  .radio { min-width: 0; width: 100%; }
  .topo-wrap { overflow-x: auto; } svg#topo { min-width: 900px; } .flow { max-height: 70vh; }
}
@media (prefers-reduced-motion: no-preference) {
  .tile rect.bar { transition: fill .4s; }
}
</style>
</head>
<body>
<header>
  <div class="title">
    <h1>FCT 5G Testbed</h1>
    <p>Open5GS core on FCT0172, OAI RAN on FCT0173. Select any function to read its log.</p>
    <nav class="tabs" aria-label="Pages">
      <button class="tab on" data-page="overview" aria-current="page">Overview</button>
      <button class="tab" data-page="ue">UE KPIs</button>
    </nav>
  </div>
  <div class="radio" id="radio">
    <div class="mode" id="radioMode">Radio: …</div>
    <div class="note" id="radioNote">Set on the server only.</div>
  </div>
</header>
<div class="summary" id="summary"><span>Waiting for the first update…</span></div>
<div class="kpis" id="kpis">
  <div class="kpi"><span class="v" id="kGnb">–</span><span class="l">gNBs connected<small>reported by the AMF</small></span></div>
  <div class="kpi"><span class="v" id="kUe">–</span><span class="l">UEs connected<small>reported by the AMF</small></span></div>
  <div class="kpi"><span class="v" id="kDl">–</span><span class="l">Downlink, Mbit/s<small id="kDlNote">MAC goodput</small></span></div>
  <div class="kpi"><span class="v" id="kUl">–</span><span class="l">Uplink, Mbit/s<small id="kUlNote">MAC goodput</small></span></div>
</div>
<div class="ctl" id="ctl">
  <span class="ctl-t">Controls</span>
  <form id="unlock" class="unlock">
    <input id="adminKey" type="password" placeholder="Admin password" autocomplete="current-password" aria-label="Admin password">
    <button type="submit">Unlock</button>
  </form>
  <button id="lockBtn" type="button" hidden>Lock</button>
  <div class="grp"><span>gNB</span><button data-a="gnb-start" disabled>Start</button><button data-a="gnb-stop" disabled>Stop</button></div>
  <div class="grp"><span>UE</span><button data-a="ue-start" disabled>Start</button><button data-a="ue-stop" disabled>Stop</button></div>
  <div class="grp"><span>Speed test</span><button data-a="speed-dl" disabled>Downlink</button><button data-a="speed-ul" disabled>Uplink</button><button data-a="speed-stop" disabled>Stop</button></div>
  <span id="ctlMsg" class="ctl-msg" role="status"></span>
</div>
<div class="errors" id="errors"></div>
<main id="overview">
<div class="topo-wrap">
<svg id="topo" viewBox="0 0 1120 560" role="img" aria-label="Topology of the 5G core and RAN with the state of each function">
  <g id="wires"></g>
  <g id="tiles"></g>
  <g id="uecard" class="uecard"></g>
</svg>
</div>
<section class="flow" aria-label="5G SA message flow">
  <div class="flow-head">
    <h2>5G SA message flow</h2>
    <span id="flowState" class="flow-state">Connecting to the N2 capture…</span>
    <button id="flowOrder" type="button" title="Change the reading order">Newest first</button>
    <button id="flowClear" title="Hide earlier messages; new ones keep appearing">Clear view</button>
  </div>
  <div class="flow-scroll">
    <table>
      <thead><tr><th>Time</th><th>Link</th><th>Direction</th><th>Protocol</th><th>Message</th></tr></thead>
      <tbody id="flowBody"></tbody>
    </table>
    <p id="flowEmpty" class="flow-empty">No messages yet. Start the gNB to see NG Setup here.</p>
  </div>
</section>
</main>
<section id="ue" class="uepage" hidden>
  <div class="uebar">
    <label>UE <select id="ueSel"></select></label>
    <div class="seg" role="group" aria-label="Time window">
      <button data-w="120">2 min</button><button data-w="300" class="on">5 min</button><button data-w="900">15 min</button>
    </div>
    <a id="csv" class="btn" href="api/history.csv" download>Download CSV</a>
    <span id="ueNote" class="uenote"></span>
  </div>
  <div class="uetiles" id="ueTiles"></div>
  <div class="charts" id="charts"></div>
  <div id="tip" class="tip" hidden></div>
</section>
<aside id="drawer" aria-label="Pod log">
  <div class="bar">
    <h2 id="logTitle">Log<small id="logSub"></small></h2>
    <button id="logRefresh">Refresh</button>
    <button id="logClose">Close</button>
  </div>
  <pre id="logBody"></pre>
</aside>
<script>
const W = 124, H = 74;
// Layout: one entry per network function we expect to see.
const NODES = [
  // Control plane on the service-based interface
  {role: "nrf", label: "NRF", c: "core", x: 316, y: 36, bus: "down"},
  {role: "scp", label: "SCP", c: "core", x: 450, y: 36, bus: "down"},
  {role: "ausf", label: "AUSF", c: "core", x: 584, y: 36, bus: "down"},
  {role: "udm", label: "UDM", c: "core", x: 718, y: 36, bus: "down"},
  {role: "udr", label: "UDR", c: "core", x: 852, y: 36, bus: "down"},
  {role: "pcf", label: "PCF", c: "core", x: 986, y: 36, bus: "down"},
  {role: "amf", label: "AMF", c: "core", x: 316, y: 166, bus: "up"},
  {role: "smf", label: "SMF", c: "core", x: 584, y: 166, bus: "up"},
  {role: "nssf", label: "NSSF", c: "core", x: 718, y: 166, bus: "up"},
  {role: "mongodb", label: "MongoDB", c: "core", x: 852, y: 166},
  {role: "bsf", label: "BSF", c: "core", x: 986, y: 166, bus: "up"},
  {role: "upf", label: "UPF", c: "core", x: 584, y: 320},
  // RAN
  {role: "gnb", label: "gNB", c: "ran", x: 40, y: 320},
  {role: "ue", label: "UE", c: "ran", x: 40, y: 470},
  // 4G EPC, deployed alongside the 5G core
  {role: "mme", label: "MME", c: "core", x: 584, y: 478, small: true},
  {role: "hss", label: "HSS", c: "core", x: 690, y: 478, small: true},
  {role: "pcrf", label: "PCRF", c: "core", x: 796, y: 478, small: true},
  {role: "sgwc", label: "SGW-C", c: "core", x: 902, y: 478, small: true},
  {role: "sgwu", label: "SGW-U", c: "core", x: 1008, y: 478, small: true},
];
const SMALL_W = 100, SMALL_H = 52;
const COLORS = {running: "var(--ok)", starting: "var(--warn)", stopping: "var(--warn)",
                failed: "var(--fault)", missing: "var(--fault)", unknown: "var(--unknown)", off: "var(--unknown)"};
const WORDS = {running: "Running", starting: "Starting", stopping: "Stopping",
               failed: "Failed", missing: "Stopped", unknown: "Unknown", off: "Off"};
const NS = "http://www.w3.org/2000/svg";
const $ = id => document.getElementById(id);
function el(tag, attrs, text) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (text !== undefined) e.textContent = text;
  return e;
}
function path(d, cls) { return el("path", {d, class: "wire " + (cls || "")}); }
function label(x, y, t, anchor) { return el("text", {x, y, class: "ifname", "text-anchor": anchor || "start"}, t); }

function drawWires() {
  const g = $("wires");
  // SBI bus
  g.append(path("M300 134 H1110"), label(300, 127, "SBI"));
  for (const n of NODES.filter(n => n.bus)) {
    const cx = n.x + W / 2;
    g.append(n.bus === "down" ? path(`M${cx} ${n.y + H} V134`) : path(`M${cx} 134 V${n.y}`));
  }
  // MongoDB holds the UDR and PCF data
  g.append(path("M914 166 V110", "dash"));
  // N4 SMF-UPF, N6 UPF-data network
  g.append(path("M646 240 V320"), label(654, 286, "N4"));
  g.append(path("M708 357 H852"), label(780, 349, "N6", "middle"));
  // N2 gNB-AMF, N3 gNB-UPF
  g.append(path("M164 345 H378 V240"), label(270, 337, "N2", "middle"));
  g.append(path("M164 375 H584"), label(374, 367, "N3", "middle"));
  // Radio link UE-gNB
  g.append(path("M102 470 V394", "radio"), label(112, 438, "Radio (rfsim)"));
  // Data network
  const dn = el("g", {class: "dn"});
  dn.append(el("rect", {x: 852, y: 320, width: 258, height: 74, rx: 6}),
            el("text", {x: 868, y: 350, style: "font:700 17px var(--cond)"}, "Data network fctoai"),
            el("text", {x: 868, y: 372, style: "font:12px var(--sans)"}, "UE pool 10.45.0.0/16"));
  g.append(dn);
  // Section names
  g.append(el("text", {x: 316, y: 24, class: "section"}, "Core, Open5GS on FCT0172"),
           el("text", {x: 40, y: 306, class: "section"}, "RAN, OAI on FCT0173"),
           el("text", {x: 584, y: 468, class: "section"}, "4G EPC, also deployed"));
}

function drawTiles() {
  const g = $("tiles");
  for (const n of NODES) {
    const w = n.small ? SMALL_W : W, h = n.small ? SMALL_H : H;
    const t = el("g", {class: "tile" + (n.small ? " small" : ""), tabindex: 0, role: "button", id: "t-" + n.role});
    t.append(el("rect", {class: "body", x: n.x, y: n.y, width: w, height: h, rx: 6}),
             el("rect", {class: "bar", x: n.x, y: n.y, width: 6, height: h, rx: 2, fill: COLORS.unknown}),
             el("text", {class: "name", x: n.x + 16, y: n.y + (n.small ? 21 : 25), style: n.label.length > 6 ? "font-size:15px" : ""}, n.label),
             el("text", {class: "status", x: n.x + 16, y: n.y + (n.small ? 40 : 45), fill: COLORS.unknown}, WORDS.unknown));
    if (!n.small) t.append(el("text", {class: "meta", x: n.x + 16, y: n.y + 63}, ""),
                           el("text", {class: "meta up", x: n.x + w - 10, y: n.y + 24, "text-anchor": "end"}, ""));
    t.append(el("title", {}, n.label));
    t.addEventListener("click", () => openLog(n));
    t.addEventListener("keydown", e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); openLog(n); } });
    g.append(t);
  }
}

let latest = null;
function podFor(n) {
  return latest && latest.pods.find(p => p.cluster === n.c && p.role === n.role);
}
function age(iso) {
  if (!iso) return "";
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (s < 3600) return Math.max(1, Math.round(s / 60)) + " min";
  if (s < 86400) return Math.round(s / 3600) + " h";
  return Math.round(s / 86400) + " d";
}

function render(data) {
  latest = data;
  const live = data.radioMode !== "rfsim";
  $("radio").classList.toggle("live", live);
  $("radioMode").textContent = "Radio: " + data.radioMode;
  $("radioNote").innerHTML = live
    ? "Radio hardware may transmit.<br>Changed on the server only."
    : "Software radio, no RF emission.<br>Changed on the server only.";
  $("errors").innerHTML = "";
  for (const [c, msg] of Object.entries(data.errors || {})) {
    const d = document.createElement("div");
    d.textContent = (c === "core" ? "Core cluster (FCT0172)" : "RAN cluster (FCT0173)") + ": " + msg;
    $("errors").append(d);
  }
  let coreUp = 0, coreAll = 0;
  for (const n of NODES) {
    const p = podFor(n);
    const clusterDown = data.errors && data.errors[n.c];
    const dep = {gnb: "oai-gnb", ue: "oai-nr-ue"}[n.role];
    const tg = dep && data.controls && data.controls.targets && data.controls.targets[dep];
    const state = clusterDown ? "unknown" : (p ? p.state : (tg && tg.want === 0 ? "off" : "missing"));
    const t = $("t-" + n.role);
    t.querySelector("rect.bar").setAttribute("fill", COLORS[state]);
    const st = t.querySelector(".status");
    st.setAttribute("fill", COLORS[state]);
    st.textContent = (p && p.reason && state !== "running") ? p.reason : WORDS[state];
    const meta = t.querySelector(".meta");
    if (meta) meta.textContent = p ? (p.ip || "no IP") : "";
    const up = t.querySelector(".up");
    if (up) up.textContent = p && n.label.length <= 6 ? age(p.started) : "";
    t.querySelector("title").textContent = p
      ? `${p.pod}\nnode ${p.node}\nrestarts ${p.restarts}\nselect to read the log`
      : `${n.label}: no pod found`;
    if (n.c === "core" && !n.small) { coreAll++; if (state === "running") coreUp++; }
  }
  const s = $("summary");
  s.innerHTML = "";
  const part = (text, cls) => { const b = document.createElement("b"); b.textContent = text; b.className = cls; s.append(b); };
  part(`5G core: ${coreUp} of ${coreAll} running`, coreUp === coreAll ? "ok" : "bad");
  for (const r of ["gnb", "ue"]) {
    const n = NODES.find(n => n.role === r), p = podFor(n);
    const ok = p && p.state === "running";
    const tg2 = data.controls && data.controls.targets && data.controls.targets[{gnb: "oai-gnb", ue: "oai-nr-ue"}[r]];
    const off = !p && tg2 && tg2.want === 0;
    part(`${n.label}: ${p ? WORDS[p.state] : (off ? "off" : "not deployed")}`, ok ? "ok" : (p ? "mid" : (off ? "" : "bad")));
  }
  const u = document.createElement("span");
  u.className = "updated"; u.id = "updated";
  u.dataset.t = Date.parse(data.time);
  s.append(u);
  renderRan(data);
  renderControls(data.controls);
  tick();
}
function tick() {
  const u = $("updated"); if (!u) return;
  const ago = Math.round((Date.now() - Number(u.dataset.t)) / 1000);
  u.textContent = `Updated ${new Date(Number(u.dataset.t)).toLocaleTimeString()}` + (ago > 10 ? `, ${ago} s ago: dashboard cannot reach its backend` : "");
  u.classList.toggle("stale", ago > 10);
}

async function poll() {
  try {
    const r = await fetch("api/state", {cache: "no-store"});
    if (r.ok) render(await r.json());
  } catch (e) { /* the stale marker shows the gap */ }
}

// Log drawer
let logNode = null;
async function openLog(n) {
  logNode = n;
  const p = podFor(n);
  $("drawer").classList.add("open");
  $("logTitle").firstChild.textContent = n.label + " log";
  $("logSub").textContent = p ? p.pod : "no pod running";
  $("logBody").textContent = p ? "Loading…" : "There is no pod for this function, so there is no log to show.";
  if (!p) return;
  try {
    const r = await fetch(`api/logs?cluster=${p.cluster}&pod=${encodeURIComponent(p.pod)}&lines=200`);
    $("logBody").textContent = await r.text() || "(the log is empty)";
    $("logBody").scrollTop = $("logBody").scrollHeight;
  } catch (e) { $("logBody").textContent = "Could not reach the dashboard backend."; }
}
$("logRefresh").onclick = () => logNode && openLog(logNode);
$("logClose").onclick = () => $("drawer").classList.remove("open");
document.addEventListener("keydown", e => { if (e.key === "Escape") $("drawer").classList.remove("open"); });



// D4: counts, rates and the UE card
function fmt(v, d) { return v === null || v === undefined || isNaN(v) ? "–" : Number(v).toFixed(d); }
function renderRan(data) {
  const ran = data.ran || {};
  const stats = ran.ueStats || [];
  const sum = k => stats.reduce((a, u) => a + (u[k] || 0), 0);
  $("kGnb").textContent = ran.gnbs ?? "–";
  $("kUe").textContent = ran.ues ?? "–";
  $("kDl").textContent = stats.length ? fmt(sum("goodputDl"), 1) : "–";
  $("kUl").textContent = stats.length ? fmt(sum("goodputUl"), 1) : "–";
  const note = data.radioMode === "rfsim" ? "MAC goodput, simulated time" : "MAC goodput";
  $("kDlNote").textContent = note; $("kUlNote").textContent = note;
  const g = $("uecard"); g.innerHTML = "";
  if (!stats.length) return;
  const u = stats[stats.length - 1], x = 196, y = 444;
  const line = (ty, parts) => {
    const t = el("text", {x: x + 14, y: ty, class: "k"});
    parts.forEach(([label, val]) => { t.append(document.createTextNode(label + " ")); const n = el("tspan", {class: "n"}, val + "   "); t.append(n); });
    return t;
  };
  g.append(path(`M164 507 H${x}`),
    el("rect", {x, y, width: 370, height: 104, rx: 6}),
    el("text", {x: x + 14, y: y + 22, class: "h"}, `RNTI 0x${u.rnti}` + (ran.lastImsi ? `   IMSI ${ran.lastImsi}` : "") + (stats.length > 1 ? `   (+${stats.length - 1} more)` : "")),
    line(y + 44, [["RSRP", fmt(u.rsrp, 0) + " dBm"], ["CQI", fmt(u.cqi, 0)], ["RI", fmt(u.ri, 0)], ["PH", fmt(u.ph, 0) + " dB"]]),
    line(y + 64, [["MCS DL", fmt(u.mcsDl, 0)], ["UL", fmt(u.mcsUl, 0)], ["BLER DL", fmt(u.blerDl * 100, 1) + "%"], ["UL", fmt(u.blerUl * 100, 1) + "%"]]),
    line(y + 84, [["Goodput DL", fmt(u.goodputDl, 1)], ["UL", fmt(u.goodputUl, 1) + " Mbit/s"], ["SNR UL", fmt(u.snrPusch, 1) + " dB"]]));
}

// 5G SA message flow: N2 from packet capture, Uu from gNB/UE logs
let flowLast = 0, uuLast = 0, flowHideT = 0, flowRows = [], uuRows = [], flowNewestFirst = false;
try { flowNewestFirst = localStorage.getItem("fctFlowNewestFirst") === "1"; } catch (e) {}
const MILESTONE = /NGSetup(Request|Response)|Registration (request|accept|complete)|PDUSessionResourceSetup(Request|Response)|InitialContextSetupResponse|Msg1|RRCSetupComplete/;
const BAD = /reject|Failure|failure|Error Indication|UEContextRelease/;
function fmtTime(t) {
  const d = new Date(t * 1000);
  return d.toLocaleTimeString([], {hour12: false}) + "." + String(d.getMilliseconds()).padStart(3, "0");
}
const DIRS = {N2: {ul: "gNB → AMF", dl: "AMF → gNB"}, Uu: {ul: "UE → gNB", dl: "gNB → UE"}};
function renderFlow(newKeys) {
  const body = $("flowBody");
  const sc = document.querySelector(".flow-scroll");
  const atEnd = sc.scrollHeight - sc.scrollTop - sc.clientHeight < 40;
  let rows = flowRows.concat(uuRows).filter(m => m.t > flowHideT).sort((a, b) => a.t - b.t).slice(-300);
  if (flowNewestFirst) rows = rows.reverse();
  body.innerHTML = "";
  for (const m of rows) {
    const tr = document.createElement("tr");
    const iface = m.iface || "N2";
    if (iface === "Uu") tr.classList.add("uu");
    if (MILESTONE.test(m.msg)) tr.classList.add("milestone");
    if (BAD.test(m.msg)) tr.classList.add("bad");
    if (newKeys.has(iface + m.seq)) tr.classList.add("new");
    const [ngap, ...nas] = iface === "N2" ? m.msg.split(", ") : [m.msg];
    const td = (cls, text) => { const c = document.createElement("td"); c.className = cls; c.textContent = text; return c; };
    const msg = td("m", ngap);
    if (nas.length) { msg.append(", "); const b = document.createElement("b"); b.textContent = nas.join(", "); msg.append(b); }
    tr.append(td("t", fmtTime(m.t)), td("i", iface), td("d " + m.dir, DIRS[iface][m.dir]), td("p", m.proto), msg);
    body.append(tr);
  }
  $("flowEmpty").style.display = rows.length ? "none" : "block";
  if (flowNewestFirst) sc.scrollTop = 0; else if (atEnd || newKeys.size === 0) sc.scrollTop = sc.scrollHeight;
}
function setOrder(newest) {
  flowNewestFirst = newest;
  $("flowOrder").textContent = newest ? "Oldest first" : "Newest first";
  try { localStorage.setItem("fctFlowNewestFirst", newest ? "1" : "0"); } catch (e) {}
  renderFlow(new Set());
}
async function pollFlow() {
  const fresh = new Set();
  try {
    const r = await fetch(`api/flow?after=${flowLast}`, {cache: "no-store"});
    const d = await r.json();
    if (!r.ok || d.error) throw new Error(d.error || r.status);
    if (d.last < flowLast) { flowRows = []; flowLast = 0; }
    for (const m of d.messages) { flowRows.push(m); fresh.add("N2" + m.seq); flowLast = Math.max(flowLast, m.seq); }
    if (flowRows.length > 1000) flowRows = flowRows.slice(-1000);
    const st = $("flowState");
    st.textContent = d.status && d.status.running ? "N2 from packet capture, Uu from gNB and UE logs" : "N2 capture stopped: " + ((d.status && d.status.error) || "unknown reason");
    st.className = "flow-state " + (d.status && d.status.running ? "ok" : "bad");
  } catch (e) {
    const st = $("flowState");
    st.textContent = "No contact with the N2 capture: " + e.message;
    st.className = "flow-state bad";
  }
  try {
    const r = await fetch(`api/uu?after=${uuLast}`, {cache: "no-store"});
    if (r.ok) {
      const d = await r.json();
      if (d.last < uuLast) { uuRows = []; uuLast = 0; }
      for (const m of d.events) { uuRows.push(m); fresh.add("Uu" + m.seq); uuLast = Math.max(uuLast, m.seq); }
      if (uuRows.length > 500) uuRows = uuRows.slice(-500);
    }
  } catch (e) { /* Uu rows are optional; N2 status shows backend loss */ }
  if (fresh.size || !$("flowBody").children.length) renderFlow(fresh);
}
$("flowClear").onclick = () => { flowHideT = Date.now() / 1000; renderFlow(new Set()); };
$("flowOrder").onclick = () => setOrder(!flowNewestFirst);
$("flowOrder").textContent = flowNewestFirst ? "Oldest first" : "Newest first";
pollFlow();
setInterval(pollFlow, 1000);



// D6: controls
let adminKey = "";
try { adminKey = sessionStorage.getItem("fctAdminKey") || ""; } catch (e) {}
function ctlMsg(text, cls) { const m = $("ctlMsg"); m.textContent = text; m.className = "ctl-msg " + (cls || ""); }
function renderControls(c) {
  const unlocked = !!adminKey && c && c.enabled;
  $("unlock").hidden = !!adminKey || !(c && c.enabled);
  $("lockBtn").hidden = !adminKey;
  const t = (c && c.targets) || {};
  const on = n => t[n] && t[n].want > 0;
  document.querySelectorAll(".ctl button[data-a]").forEach(b => {
    b.disabled = !unlocked;
    const a = b.dataset.a;
    b.classList.toggle("active", (a === "gnb-start" && on("oai-gnb")) || (a === "ue-start" && on("oai-nr-ue")) ||
      (a === "speed-dl" && on("speedtest-dl")) || (a === "speed-ul" && on("speedtest-ul")));
  });
  if (c && !c.enabled && !$("ctlMsg").textContent) ctlMsg(c.reason || "Controls are off");
}
async function control(action) {
  ctlMsg("Working…");
  try {
    const r = await fetch("api/control", {method: "POST", headers: {"Content-Type": "application/json", "X-Admin-Key": adminKey}, body: JSON.stringify({action})});
    const d = await r.json();
    if (r.status === 401) { adminKey = ""; try { sessionStorage.removeItem("fctAdminKey"); } catch (e) {} }
    ctlMsg(d.msg, d.ok ? "ok" : "bad");
    poll();
    return d.ok;
  } catch (e) { ctlMsg("No contact with the dashboard backend.", "bad"); return false; }
}
$("unlock").onsubmit = async e => {
  e.preventDefault();
  adminKey = $("adminKey").value; $("adminKey").value = "";
  if (await control("check")) { try { sessionStorage.setItem("fctAdminKey", adminKey); } catch (e) {} }
  else adminKey = "";
  renderControls(latest && latest.controls);
};
$("lockBtn").onclick = () => { adminKey = ""; try { sessionStorage.removeItem("fctAdminKey"); } catch (e) {} ctlMsg("Controls locked"); renderControls(latest && latest.controls); };
document.querySelectorAll(".ctl button[data-a]").forEach(b => b.onclick = () => control(b.dataset.a));

// D5: UE KPI page
const SERIES = {a: "#2a78d6", b: "#eb6834"};
const CHARTS = [
  {id: "rsrp", t: "RSRP", u: "dBm", s: [["rsrp", "RSRP", "a"]], span: 10},
  {id: "ph", t: "Power headroom", u: "dB", s: [["ph", "PH", "a"]]},
  {id: "cqi", t: "CQI", u: "", s: [["cqi", "CQI", "a"]], min: 0, max: 15},
  {id: "snr", t: "SNR at the gNB", u: "dB", s: [["snrPucch", "PUCCH", "a"], ["snrPusch", "PUSCH", "b"]], span: 10},
  {id: "mcs", t: "MCS", u: "index", s: [["mcsDl", "DL", "a"], ["mcsUl", "UL", "b"]], min: 0, max: 28},
  {id: "bler", t: "BLER", u: "%", s: [["blerDl", "DL", "a", 100], ["blerUl", "UL", "b", 100]], min: 0},
  {id: "gp", t: "Goodput", u: "Mbit/s", s: [["goodputDl", "DL", "a"], ["goodputUl", "UL", "b"]], min: 0, max: 10},
  {id: "rssi", t: "RSSI at the gNB", u: "dBm", s: [["rssiDl", "PUCCH", "a"], ["rssiUl", "PUSCH", "b"]], span: 10},
];
const TILES = [
  ["RSRP", "rsrp", "dBm", 0], ["Power headroom", "ph", "dB", 0], ["CQI", "cqi", "", 0],
  ["SNR PUSCH", "snrPusch", "dB", 1], ["SNR PUCCH", "snrPucch", "dB", 1],
  ["MCS DL", "mcsDl", "", 0], ["MCS UL", "mcsUl", "", 0],
  ["BLER DL", "blerDl", "%", 2, 100], ["BLER UL", "blerUl", "%", 2, 100],
  ["Goodput DL", "goodputDl", "Mbit/s", 1], ["Goodput UL", "goodputUl", "Mbit/s", 1],
];
let ueWin = 300, ueRnti = "", ueTimer = null, ueData = null;
function niceRange(lo, hi, fixedMin, fixedMax, minSpan) {
  if (minSpan && isFinite(lo) && isFinite(hi) && hi - lo < minSpan) { const m = (lo + hi) / 2; lo = m - minSpan / 2; hi = m + minSpan / 2; }
  if (fixedMin !== undefined) lo = Math.min(lo, fixedMin);
  if (fixedMax !== undefined) hi = Math.max(hi, fixedMax);
  if (!isFinite(lo) || !isFinite(hi)) { lo = 0; hi = 1; }
  if (hi - lo < 1e-9) { lo -= 1; hi += 1; }
  const step = Math.pow(10, Math.floor(Math.log10((hi - lo) / 3)));
  const st = [1, 2, 2.5, 5, 10].map(k => k * step).find(k => (hi - lo) / k <= 4);
  lo = fixedMin !== undefined ? fixedMin : Math.floor(lo / st) * st;
  hi = Math.ceil(hi / st) * st;
  const ticks = []; for (let v = lo; v <= hi + st / 2; v += st) ticks.push(+v.toFixed(6));
  return {lo, hi: Math.max(hi, ticks[ticks.length - 1]), ticks, dec: Math.max(0, -Math.floor(Math.log10(st)))};
}
function hhmmss(t) { return new Date(t * 1000).toLocaleTimeString([], {hour12: false}); }
function drawChart(c, rows, t1) {
  const Wc = 520, Hc = 190, L = 46, R = 12, T = 10, B = 24, t0 = t1 - ueWin;
  const vals = [];
  for (const [k, , , m] of c.s) for (const r of rows) if (r[k] !== null && r[k] !== undefined) vals.push(r[k] * (m || 1));
  const yr = niceRange(Math.min(...vals), Math.max(...vals), c.min, c.max, c.span);
  const X = t => L + (t - t0) / (t1 - t0) * (Wc - L - R), Y = v => T + (1 - (v - yr.lo) / (yr.hi - yr.lo)) * (Hc - T - B);
  const svg = el("svg", {viewBox: `0 0 ${Wc} ${Hc}`, role: "img", "aria-label": `${c.t} over the last ${ueWin / 60} minutes`});
  for (const v of yr.ticks) svg.append(el("line", {class: "grid", x1: L, x2: Wc - R, y1: Y(v), y2: Y(v)}), el("text", {class: "axis", x: L - 6, y: Y(v) + 4, "text-anchor": "end"}, v.toFixed(yr.dec)));
  for (let i = 0; i <= 4; i++) { const t = t0 + i * ueWin / 4; svg.append(el("text", {class: "axis", x: X(t), y: Hc - 6, "text-anchor": i === 0 ? "start" : i === 4 ? "end" : "middle"}, hhmmss(t))); }
  if (!vals.length) svg.append(el("text", {class: "empty", x: Wc / 2, y: Hc / 2, "text-anchor": "middle"}, "No samples in this window"));
  for (const [k, , col, m] of c.s) {
    let d = "", prev = null;
    for (const r of rows) {
      const v = r[k]; if (v === null || v === undefined) { prev = null; continue; }
      const gap = prev === null || r.t - prev > 3;
      d += `${gap ? "M" : "L"}${X(r.t).toFixed(1)} ${Y(v * (m || 1)).toFixed(1)}`; prev = r.t;
    }
    svg.append(el("path", {class: "ln", d, stroke: SERIES[col]}));
  }
  const xh = el("line", {class: "xh", y1: T, y2: Hc - B, visibility: "hidden"});
  const hit = el("rect", {x: L, y: T, width: Wc - L - R, height: Hc - T - B, fill: "transparent"});
  svg.append(xh, hit);
  hit.addEventListener("mousemove", e => {
    if (!rows.length) return;
    const bb = svg.getBoundingClientRect(), tx = t0 + ((e.clientX - bb.left) * Wc / bb.width - L) / (Wc - L - R) * ueWin;
    let best = rows[0]; for (const r of rows) if (Math.abs(r.t - tx) < Math.abs(best.t - tx)) best = r;
    xh.setAttribute("x1", X(best.t)); xh.setAttribute("x2", X(best.t)); xh.setAttribute("visibility", "visible");
    const tip = $("tip"); tip.hidden = false;
    tip.innerHTML = `<b>${hhmmss(best.t)}</b><br>` + c.s.map(([k, lab, col, m]) => `<span style="color:${SERIES[col]}">■</span> ${lab}: ${best[k] === null || best[k] === undefined ? "–" : fmt(best[k] * (m || 1), 2)} ${c.u}`).join("<br>");
    tip.style.left = Math.min(e.clientX + 14, innerWidth - 180) + "px"; tip.style.top = (e.clientY + 12) + "px";
  });
  hit.addEventListener("mouseleave", () => { xh.setAttribute("visibility", "hidden"); $("tip").hidden = true; });
  return svg;
}
function renderUe() {
  const d = ueData; if (!d) return;
  const sel = $("ueSel"), cur = d.rnti || "";
  sel.innerHTML = d.rntis.length ? "" : "<option value=''>No UE seen yet</option>";
  for (const r of d.rntis) { const o = document.createElement("option"); o.value = r; o.textContent = "RNTI 0x" + r; o.selected = r === cur; sel.append(o); }
  $("csv").href = `api/history.csv?seconds=${ueWin}` + (cur ? `&rnti=${cur}` : "");
  $("ueNote").textContent = latest && latest.radioMode === "rfsim" ? "Radio mode rfsim: values come from the software channel model; goodput is in simulated time." : "";
  const rows = d.rows, t1 = Date.now() / 1000;
  const tl = $("ueTiles"); tl.innerHTML = "";
  for (const [name, k, unit, dec, m] of TILES) {
    const v = rows.map(r => r[k]).filter(x => x !== null && x !== undefined).map(x => x * (m || 1));
    const div = document.createElement("div"); div.className = "ut";
    const last = v.length ? v[v.length - 1] : null;
    const avg = v.length ? v.reduce((a, b) => a + b, 0) / v.length : null;
    div.innerHTML = `<div class="n">${name}</div><div class="v">${fmt(last, dec)}<small>${unit}</small></div>` +
      `<div class="r">min ${fmt(v.length ? Math.min(...v) : null, dec)}, max ${fmt(v.length ? Math.max(...v) : null, dec)}, avg ${fmt(avg, dec)}</div>`;
    tl.append(div);
  }
  const ch = $("charts"); ch.innerHTML = "";
  for (const c of CHARTS) {
    const box = document.createElement("div"); box.className = "chart";
    const h = document.createElement("h3"); h.textContent = c.t;
    const sm = document.createElement("small"); sm.textContent = c.u; h.append(sm);
    if (c.s.length > 1) {
      const lg = document.createElement("span"); lg.className = "lg";
      for (const [, lab, col] of c.s) { const it = document.createElement("span"); it.innerHTML = `<i style="background:${SERIES[col]}"></i>${lab}`; lg.append(it); }
      h.append(lg);
    }
    box.append(h, drawChart(c, rows, t1)); ch.append(box);
  }
}
async function pollUe() {
  try {
    const r = await fetch(`api/history?seconds=${ueWin}` + (ueRnti ? `&rnti=${ueRnti}` : ""), {cache: "no-store"});
    if (r.ok) { ueData = await r.json(); renderUe(); }
  } catch (e) { /* the stale marker on the overview shows backend loss */ }
}
$("ueSel").onchange = e => { ueRnti = e.target.value; pollUe(); };
document.querySelectorAll(".seg button").forEach(b => b.onclick = () => {
  document.querySelectorAll(".seg button").forEach(x => x.classList.toggle("on", x === b));
  ueWin = Number(b.dataset.w); pollUe();
});
function showPage(p) {
  document.querySelectorAll(".tab").forEach(t => { const on = t.dataset.page === p; t.classList.toggle("on", on); on ? t.setAttribute("aria-current", "page") : t.removeAttribute("aria-current"); });
  $("overview").hidden = p !== "overview"; $("ue").hidden = p !== "ue";
  clearInterval(ueTimer);
  if (p === "ue") { pollUe(); ueTimer = setInterval(pollUe, 2000); }
  history.replaceState(null, "", p === "ue" ? "#ue" : "#");
}
document.querySelectorAll(".tab").forEach(t => t.onclick = () => showPage(t.dataset.page));
if (location.hash === "#ue") showPage("ue");

drawWires();
drawTiles();
poll();
setInterval(poll, 3000);
setInterval(tick, 1000);
</script>
</body>
</html>
FILEEOF
cat > "$TMP/fct-dash.yaml" <<'FILEEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fct-dash
  namespace: fct-dash
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fct-dash
  template:
    metadata:
      labels:
        app: fct-dash
      annotations:
        fct-dash/code-hash: "CODE_HASH"
    spec:
      serviceAccountName: fct-dash-reader
      containers:
      - name: dash
        image: python:3.12-alpine
        command: ["python", "/app/app.py"]
        env:
        - name: RADIO_MODE
          value: rfsim
        - name: CAPTURE_URL
          value: http://10.0.129.7:8091
        - name: PYTHONDONTWRITEBYTECODE
          value: "1"
        - name: PYTHONUNBUFFERED
          value: "1"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8080
          periodSeconds: 5
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits: {cpu: 500m, memory: 256Mi}
        securityContext:
          runAsNonRoot: true
          runAsUser: 65534
          readOnlyRootFilesystem: true
          allowPrivilegeEscalation: false
        volumeMounts:
        - name: app
          mountPath: /app
          readOnly: true
        - name: ran
          mountPath: /etc/fct-dash/ran
          readOnly: true
        - name: ctl
          mountPath: /etc/fct-dash/ctl
          readOnly: true
        - name: admin
          mountPath: /etc/fct-dash/admin
          readOnly: true
      volumes:
      - name: app
        configMap:
          name: fct-dash-app
      - name: ran
        secret:
          secretName: fct-dash-ran
      - name: ctl
        secret:
          secretName: fct-dash-ctl
          optional: true
      - name: admin
        secret:
          secretName: fct-dash-admin
          optional: true
---
apiVersion: v1
kind: Service
metadata:
  name: fct-dash
  namespace: fct-dash
spec:
  type: NodePort
  selector:
    app: fct-dash
  ports:
  - port: 80
    targetPort: 8080
    nodePort: 30880
FILEEOF
cat > "$TMP/iperf-server.yaml" <<'FILEEOF'
# Speed-test servers on the UPF host (core cluster), bound to the UE pool gateway.
# Each iperf3 runs under a watchdog (5 s of 0-byte intervals, or an open connection
# with no progress for 10 s, restarts it), so a UE lost mid-test never leaves the
# server answering "busy". Nothing else on FCT0172 may listen on 5201/5202.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf-server
  namespace: fct-dash
spec:
  replicas: 1
  strategy: {type: Recreate}   # hostNetwork: the old pod must free ports 5201/5202 first
  selector: {matchLabels: {app: iperf-server}}
  template:
    metadata: {labels: {app: iperf-server}}
    spec:
      hostNetwork: true
      containers:
      - name: dl
        image: alpine:3.20
        command: ["sh", "-c", "apk add --no-cache iperf3 >/dev/null\niperf3 --version | head -1\n# run IPERF3_ARGS... : loop iperf3 forever under a watchdog that restarts it when\n#  (a) it reports 5 one-second intervals in a row with 0 bytes (peer vanished mid-test), or\n#  (b) a connection on the test port is open but the log has not moved for 10 s\n#      (peer vanished during test setup, before any interval was reported).\nrun(){\n  L=/tmp/iperf-$$.log\n  PORT=5201; prev=\"\"; for a in \"$@\"; do [ \"$prev\" = \"-p\" ] && PORT=$a; prev=$a; done\n  HEX=$(printf '%04X' $PORT)\n  while true; do\n    : > $L\n    iperf3 \"$@\" -i 1 --forceflush --logfile $L & P=$!\n    tail -f $L & T=$!\n    last=0; still=0\n    while kill -0 $P 2>/dev/null; do\n      sleep 1\n      size=$(wc -c < $L)\n      # count seconds without log progress, but only while a connection on the test port is open\n      if [ \"$size\" = \"$last\" ] && cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qE \":$HEX [0-9A-F]+:[0-9A-F]+ 01 |:[0-9A-F]+ [0-9A-F]+:$HEX 01 \"; then\n        still=$((still+1)); else still=0; fi\n      last=$size; why=\"\"\n      [ \"$(tail -n 5 $L | grep -c ' 0.00 Bytes')\" -ge 5 ] && why=\"5 s without data\"\n      [ $still -ge 10 ] && why=\"connection open but no progress for 10 s\"\n      if [ -n \"$why\" ]; then\n        echo \"watchdog: $why, restarting iperf3\"; kill $P; sleep 1; kill -9 $P 2>/dev/null\n      fi\n    done\n    wait $P 2>/dev/null; sleep 1; kill $T 2>/dev/null   # let tail print the summary first\n  done\n}\nrun -s -1 -p 5201 -B 10.45.0.1 --rcv-timeout 5000 --snd-timeout 5000\n"]
      - name: ul
        image: alpine:3.20
        command: ["sh", "-c", "apk add --no-cache iperf3 >/dev/null\niperf3 --version | head -1\n# run IPERF3_ARGS... : loop iperf3 forever under a watchdog that restarts it when\n#  (a) it reports 5 one-second intervals in a row with 0 bytes (peer vanished mid-test), or\n#  (b) a connection on the test port is open but the log has not moved for 10 s\n#      (peer vanished during test setup, before any interval was reported).\nrun(){\n  L=/tmp/iperf-$$.log\n  PORT=5201; prev=\"\"; for a in \"$@\"; do [ \"$prev\" = \"-p\" ] && PORT=$a; prev=$a; done\n  HEX=$(printf '%04X' $PORT)\n  while true; do\n    : > $L\n    iperf3 \"$@\" -i 1 --forceflush --logfile $L & P=$!\n    tail -f $L & T=$!\n    last=0; still=0\n    while kill -0 $P 2>/dev/null; do\n      sleep 1\n      size=$(wc -c < $L)\n      # count seconds without log progress, but only while a connection on the test port is open\n      if [ \"$size\" = \"$last\" ] && cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qE \":$HEX [0-9A-F]+:[0-9A-F]+ 01 |:[0-9A-F]+ [0-9A-F]+:$HEX 01 \"; then\n        still=$((still+1)); else still=0; fi\n      last=$size; why=\"\"\n      [ \"$(tail -n 5 $L | grep -c ' 0.00 Bytes')\" -ge 5 ] && why=\"5 s without data\"\n      [ $still -ge 10 ] && why=\"connection open but no progress for 10 s\"\n      if [ -n \"$why\" ]; then\n        echo \"watchdog: $why, restarting iperf3\"; kill $P; sleep 1; kill -9 $P 2>/dev/null\n      fi\n    done\n    wait $P 2>/dev/null; sleep 1; kill $T 2>/dev/null   # let tail print the summary first\n  done\n}\nrun -s -1 -p 5202 -B 10.45.0.1 --rcv-timeout 5000 --snd-timeout 5000\n"]
FILEEOF

mv "$TMP/capture.py" "$TMP/n2-capture.yaml" "$TMP/ran-control.yaml" "$TMP/ran/"
mv "$TMP/app.py" "$TMP/index.html" "$TMP/fct-dash.yaml" "$TMP/iperf-server.yaml" "$TMP/core/"

echo "### RAN side: FCT0173"
tar -C "$TMP/ran" -cz . | ssh fct0173 'mkdir -p ~/fct-dash && tar -C ~/fct-dash -xz'
ssh fct0173 'bash -s' <<'REMOTEEOF'
set -e
cd ~/fct-dash
echo "== RAN 1. Port 8091 must be free (or already ours)"
if ss -ltnp 2>/dev/null | grep -q ":8091 " && ! kubectl -n fct-dash get deploy n2-capture >/dev/null 2>&1; then
  echo "STOP: port 8091 on FCT0173 is used by something else"; ss -ltnp | grep ":8091 "; exit 1
fi
echo "== RAN 2. Capture code and Deployment"
kubectl -n fct-dash create configmap n2-capture-app --from-file=capture.py --dry-run=client -o yaml | kubectl apply -f -
HASH=$(sha256sum capture.py | cut -c1-12)
sed "s/CODE_HASH/$HASH/" n2-capture.yaml | kubectl apply -f -
kubectl -n fct-dash rollout status deploy/n2-capture --timeout=240s
sleep 3
echo -n "Capture health: "; curl -s localhost:8091/healthz; echo
echo "== RAN 3. Controller account (scale only) and speed-test clients"
kubectl apply -f ran-control.yaml
kubectl auth can-i patch deployments/oai-gnb --subresource=scale -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may scale oai-gnb: /'
kubectl auth can-i create pods -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may create pods (must be no): /'
kubectl auth can-i patch deployments/ocudu-gnb --subresource=scale -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may scale anything else (must be no): /' 
git init -q 2>/dev/null || true
git add -A && git -c user.name="Redi" -c user.email="redi@fct-lab" commit -qm "n2-capture $HASH" || true
REMOTEEOF

echo "### Controller token: RAN -> core secret"
sleep 2
ssh fct0173 "kubectl -n fct-dash get secret fct-dash-controller-token -o jsonpath='{.data.token}' | base64 -d" |   ssh fct0172 'umask 077; cat > /tmp/ctl-token && kubectl -n fct-dash create secret generic fct-dash-ctl --from-file=token=/tmp/ctl-token --dry-run=client -o yaml | kubectl apply -f - && rm -f /tmp/ctl-token'
if ! ssh fct0172 'kubectl -n fct-dash get secret fct-dash-admin >/dev/null 2>&1' || [ "${RESET_ADMIN:-0}" = 1 ]; then
  read -r -s -p "Choose the dashboard admin password: " PW; echo
  [ -n "$PW" ] || { echo "Empty password, stopping"; exit 1; }
  printf '%s' "$PW" | ssh fct0172 'umask 077; cat > /tmp/adm && kubectl -n fct-dash create secret generic fct-dash-admin --from-file=password=/tmp/adm --dry-run=client -o yaml | kubectl apply -f - && rm -f /tmp/adm'
  unset PW
fi

echo "### Core side: FCT0172"
tar -C "$TMP/core" -cz . | ssh fct0172 'mkdir -p ~/fct-dash && tar -C ~/fct-dash -xz'
ssh fct0172 'bash -s' <<'REMOTEEOF'
set -e
cd ~/fct-dash
echo "== CORE 1. Secret for the RAN cluster API (read-only token)"
KC=$HOME/.kube/ran-reader.kubeconfig
umask 077; mkdir -p .ran
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.clusters[0].cluster.server}' > .ran/server
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > .ran/ca.crt
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.users[0].user.token}' > .ran/token
kubectl -n fct-dash create secret generic fct-dash-ran --from-file=.ran/server --from-file=.ran/token --from-file=.ran/ca.crt --dry-run=client -o yaml | kubectl apply -f -
rm -rf .ran
echo "== CORE 1b. Speed-test servers on the UPF host"
kubectl apply -f iperf-server.yaml
echo "== CORE 2. Dashboard code and Deployment (NodePort 30880)"
kubectl -n fct-dash create configmap fct-dash-app --from-file=app.py --from-file=index.html --dry-run=client -o yaml | kubectl apply -f -
HASH=$(cat app.py index.html | sha256sum | cut -c1-12)
sed "s/CODE_HASH/$HASH/" fct-dash.yaml | kubectl apply -f -
kubectl -n fct-dash rollout restart deploy/fct-dash >/dev/null
kubectl -n fct-dash rollout status deploy/fct-dash --timeout=180s
printf '.ran/\n' > .gitignore
git init -q 2>/dev/null || true
git add -A && git -c user.name="Redi" -c user.email="redi@fct-lab" commit -qm "fct-dash $HASH: D2-D6 + Uu events" || true
echo "== CORE 3. Self-test"
sleep 4
curl -s localhost:30880/api/state | python3 -c "import json,sys; d=json.load(sys.stdin); print('state errors:', d['errors'] or 'none', '| pods:', len(d['pods']))"
curl -s "localhost:30880/api/flow?after=0" | python3 -c "import json,sys; d=json.load(sys.stdin); print('flow:', d.get('error') or ('capture running=%s, messages=%d' % (d['status']['running'], len(d['messages']))))"
REMOTEEOF
echo
echo "Open from REDLAB: http://10.0.129.2:30880"
