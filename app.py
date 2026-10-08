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
