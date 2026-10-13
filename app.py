#!/usr/bin/env python3
"""FCT 5G testbed dashboard - backend (D2: topology).

Standard library only, so it runs on a plain python:3.12-alpine image.
Read-only: it lists pods and reads pod logs in two Kubernetes clusters
(core on the P3 Tiny, RAN on REDLAB) with the fct-dash-reader account.
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
RE_DL = re.compile(r"UE ([0-9a-fA-F]{4}): dlsch_rounds .*?\(SNR ([-\d.]+)[^)]*\) RSSI ([-\d.]+), BLER ([\d.]+) MCS \((\d+)\) (\d+)")
RE_UL = re.compile(r"UE ([0-9a-fA-F]{4}): ulsch_rounds .*?BLER ([\d.]+) MCS \(\d+\) (\d+).*?NPRB (\d+)\s+SNR ([-\d.]+).*?RSSI ([-\d.]+)")
RE_GP = re.compile(r"UE ([0-9a-fA-F]{4}): .*?goodput DL\s+([\d.]+) UL\s+([\d.]+)")


# ---- K2: RAN (gNB) KPIs from the OAI MAC statistics and the Uu events -------
# OAI prints cumulative per-UE counters in its MAC statistics (about 5 times a second):
#   "UE xxxx: dlsch_rounds a/b/c/d, dlsch_errors e, pucch0_DTX f ... CCE fail g"   (HARQ round 1..4 counts of DL TBs)
#   "UE xxxx: ulsch_rounds a/b/c/d, ulsch_errors e, ulsch_DTX f ... CCE fail g"
#   "UE RNTI xxxx ... in-sync|out-of-sync ..."
# The sampler stores them once a second per RNTI; a KPI uses the change of each counter inside the window, per RNTI
# (a new RNTI starts its own counters). Random access and RRC setup are counted from the Uu events.
RE_DLC = re.compile(r"UE ([0-9a-fA-F]{4}): dlsch_rounds (\d+)/(\d+)/(\d+)/(\d+), dlsch_errors (\d+), pucch0_DTX (\d+).*?CCE fail (\d+)")
RE_ULC = re.compile(r"UE ([0-9a-fA-F]{4}): ulsch_rounds (\d+)/(\d+)/(\d+)/(\d+), ulsch_errors (\d+), ulsch_DTX (\d+).*?CCE fail (\d+)")
RE_SYNC = re.compile(r"UE RNTI ([0-9a-fA-F]{4}) .*?\b(in-sync|out-of-sync)\b")
COUNTERS = ["dlR0", "dlR1", "dlR2", "dlR3", "dlErr", "pucchDtx", "cceDl", "ulR0", "ulR1", "ulR2", "ulR3", "ulErr", "ulDtx",
            "cceUl", "oos"]


def parse_gnb_counters(text, ues):
    """Add the cumulative MAC counters of each RNTI to `ues` (the dicts from parse_gnb_stats)."""
    by = {u["rnti"]: u for u in ues}
    for line in text.splitlines():
        for rx, keys in ((RE_DLC, COUNTERS[0:7]), (RE_ULC, COUNTERS[7:14])):
            m = rx.search(line)
            if m and m[1].lower() in by:
                by[m[1].lower()].update({k: int(v) for k, v in zip(keys, m.groups()[1:])})
        m = RE_SYNC.search(line)
        if m and m[1].lower() in by:
            by[m[1].lower()]["oos"] = 1 if m[2] == "out-of-sync" else 0




# UE side (nrUE log): "DL Chan: SSB 1 SINR 43.3 dB RSRP -41 dBm, RI 1 CQI 15 CSI-RS RSRP -41 dBm"
RE_UE_CHAN = re.compile(r"DL Chan: SSB \d+ SINR ([-\d.]+) dB RSRP (-?\d+) dBm, RI (\d+) CQI (\d+)")

# 3GPP TS 38.214 CQI tables: (modulation, Qm, code rate x 1024, spectral efficiency). Index 0 = out of range.
CQI_TABLES = {
    1: ("TS 38.214 Table 5.2.2.1-2 (CQI table 1, up to 64QAM)", [
        ("QPSK", 2, 78, 0.1523), ("QPSK", 2, 120, 0.2344), ("QPSK", 2, 193, 0.3770), ("QPSK", 2, 308, 0.6016),
        ("QPSK", 2, 449, 0.8770), ("QPSK", 2, 602, 1.1758), ("16QAM", 4, 378, 1.4766), ("16QAM", 4, 490, 1.9141),
        ("16QAM", 4, 616, 2.4063), ("64QAM", 6, 466, 2.7305), ("64QAM", 6, 567, 3.3223), ("64QAM", 6, 666, 3.9023),
        ("64QAM", 6, 772, 4.5234), ("64QAM", 6, 873, 5.1152), ("64QAM", 6, 948, 5.5547)]),
    2: ("TS 38.214 Table 5.2.2.1-3 (CQI table 2, up to 256QAM)", [
        ("QPSK", 2, 78, 0.1523), ("QPSK", 2, 193, 0.3770), ("QPSK", 2, 449, 0.8770), ("16QAM", 4, 378, 1.4766),
        ("16QAM", 4, 490, 1.9141), ("16QAM", 4, 616, 2.4063), ("64QAM", 6, 466, 2.7305), ("64QAM", 6, 567, 3.3223),
        ("64QAM", 6, 666, 3.9023), ("64QAM", 6, 772, 4.5234), ("64QAM", 6, 873, 5.1152), ("256QAM", 8, 711, 5.5547),
        ("256QAM", 8, 797, 6.2266), ("256QAM", 8, 885, 6.9141), ("256QAM", 8, 948, 7.4063)]),
}
# Lowest SINR (dB) for CQI 1..15 of table 1 at a 10 % BLER target. Typical link-level values, NOT specified by 3GPP
# (38.214 only says the UE reports the highest CQI whose transport block would meet BLER <= 0.1).
TYPICAL_SINR_T1 = [-6.7, -4.7, -2.3, 0.2, 2.4, 4.3, 5.9, 8.1, 10.3, 11.7, 14.1, 16.3, 18.7, 21.0, 22.7]


def parse_ue_chan(text):
    m = RE_UE_CHAN.findall(text)
    if not m:
        return {}
    sinr, rsrp, ri, cqi = m[-1]
    return {"sinrUe": float(sinr), "rsrpUe": float(rsrp), "riUe": int(ri), "cqiUe": int(cqi)}


def cqi_view(cqi, mcs_table, sinr):
    """Reported CQI as a row of the 38.214 table, and the CQI a typical receiver would reach at this SINR.
    OAI picks the CQI table that matches the DL MCS table (MCS (0) = 64QAM tables, (1) = 256QAM tables)."""
    t = 2 if mcs_table == 1 else 1
    name, rows = CQI_TABLES[t]
    exp = None
    if t == 1 and sinr is not None:
        exp = sum(1 for thr in TYPICAL_SINR_T1 if sinr >= thr)
    cqi = None if cqi is None else int(cqi)
    return {"table": t, "name": name,
            "rows": [{"cqi": i + 1, "mod": m, "qm": q, "rate": r, "eff": e,
                      "sinrMin": TYPICAL_SINR_T1[i] if t == 1 else None} for i, (m, q, r, e) in enumerate(rows)],
            "cqi": cqi, "sinr": sinr, "expectedCqi": exp,
            "delta": None if cqi is None or exp is None else cqi - exp,
            "note": "CQI table from the DL MCS table index in the gNB log; SINR is the UE's SSB SINR; "
                    "SINR thresholds are typical values for BLER 10 %, not 3GPP values."}


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
                         (RE_DL, ("snrPucch", "rssiDl", "blerDl", "mcsTableDl", "mcsDl")),
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
        res = {"enabled": CONTROL.enabled, "reason": CONTROL.reason, "radioMode": RADIO_MODE, "targets": {},
               "noise": CONTROL.noise_state()}
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
        uep = next((p for p in pods if p["cluster"] == "ran" and p["role"] == "ue" and p["state"] == "running"), None)
        chan = {}
        if uep:
            try:
                chan = parse_ue_chan(self.logs("ran", uep["pod"], 80))
            except Exception as e:
                res["errors"].append("UE log: " + describe_error(e))
        res["ueChan"] = chan
        last = res["ueStats"][-1] if res["ueStats"] else {}
        res["cqiView"] = cqi_view(last.get("cqi"), last.get("mcsTableDl"), chan.get("sinrUe")) if last else None
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
           "targets": {t: {"want": n, "ready": n} for t, n in CONTROL.mock.items()},
           "noise": CONTROL.noise_state()} if "CONTROL" in globals() else {}
    return {"time": now_iso(), "radioMode": RADIO_MODE, "pods": pods, "errors": {}, "ran": ran, "controls": ctl}


CAPTURE_URL = os.environ.get("CAPTURE_URL", "http://10.0.129.7:8091").rstrip("/")
# Noise relay on the RAN host (stage B). It accepts only these preset names.
NOISE_URL = os.environ.get("NOISE_URL", "http://10.0.129.7:8092").rstrip("/")
NOISE_PRESETS = ("off", "clean", "moderate", "poor")
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
          "mcsDl", "mcsUl", "blerDl", "blerUl", "nprbUl", "goodputDl", "goodputUl", "sinrUe"] + COUNTERS


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
                        uep = next((p for p in pods if p["cluster"] == "ran" and p["role"] == "ue"
                                    and p["state"] == "running"), None)
                        chan = {}
                        if uep:
                            try:  # one UE in rfsim: its SINR belongs to the (single) RNTI the gNB reports
                                chan = parse_ue_chan(cl.get(f"/api/v1/namespaces/{ns}/pods/{uep['pod']}/log?sinceSeconds=3", raw=True))
                            except Exception:
                                pass
                        ues = parse_gnb_stats(text)
                        parse_gnb_counters(text, ues)
                        for ue in ues:
                            if chan:
                                ue["sinrUe"] = chan["sinrUe"]
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
             "goodputDl": 90 * load + 0.1, "goodputUl": 2.9 * load + 0.05,
             # cumulative MAC counters (about 1000 DL / 200 UL TBs a second, 1 % retransmitted)
             "dlR0": int(t * 1000) % 10**9, "dlR1": int(t * 10) % 10**9, "dlR2": 0, "dlR3": 0, "dlErr": 0, "pucchDtx": 0,
             "cceDl": int(t), "ulR0": int(t * 200) % 10**9, "ulR1": int(t * 2) % 10**9, "ulR2": 0, "ulR3": 0, "ulErr": 0,
             "ulDtx": 0, "cceUl": 0, "oos": 0}]


# ---- D6: controls (scale approved deployments only) -----------------------
class Control:
    """Starts and stops the approved RAN deployments by changing their replica
    count. The RAN-cluster account behind it may only scale these names; it
    cannot create pods or change a manifest, so it cannot reach the X410."""
    TARGETS = ("oai-gnb", "oai-nr-ue", "speedtest-dl", "speedtest-ul")

    def __init__(self):
        self.token_file = os.environ.get("CTL_TOKEN_FILE", "/etc/fct-dash/ctl/token")
        self.admin_file = os.environ.get("ADMIN_KEY_FILE", "/etc/fct-dash/admin/password")
        self.noise_token_file = os.environ.get("NOISE_TOKEN_FILE", "/etc/fct-dash/noise/token")
        self.mock_noise = "off"
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

    def noise_state(self):
        """Current downlink noise preset as reported by the relay (no token needed to read)."""
        if MOCK:
            return {"preset": self.mock_noise, "available": True}
        if not os.path.exists(self.noise_token_file):
            return {"available": False, "reason": "Noise relay token not installed"}
        try:
            with urllib.request.urlopen(f"{NOISE_URL}/noise", timeout=1.5) as r:
                d = json.loads(r.read())
            return {"available": True, "preset": d.get("preset"), "noiseDb": d.get("noiseDb")}
        except urllib.error.HTTPError as e:
            return {"available": False, "reason": "UE channel model not reachable (is the UE running?)" if e.code == 503
                    else f"Noise relay answered {e.code}"}
        except Exception as e:
            return {"available": False, "reason": "Noise relay: " + describe_error(e)}

    def set_noise(self, preset):
        """Ask the relay for one of the fixed presets. Returns (ok, message)."""
        if preset not in NOISE_PRESETS:
            raise ValueError("unknown preset")
        if MOCK:
            self.mock_noise = preset
            return True, f"Downlink channel set to {preset}."
        try:
            with open(self.noise_token_file) as f:
                token = f.read().strip()
        except OSError:
            return False, "Noise relay token not installed."
        req = urllib.request.Request(f"{NOISE_URL}/noise", data=json.dumps({"preset": preset}).encode(), method="POST",
                                     headers={"Content-Type": "application/json", "X-Relay-Token": token})
        try:
            with urllib.request.urlopen(req, timeout=12) as r:
                d = json.loads(r.read())
        except urllib.error.HTTPError as e:
            return False, {401: "Noise relay refused the dashboard token.",
                           503: "The UE channel model is not reachable; is the UE running?"}.get(
                               e.code, f"Noise relay answered {e.code}.")
        except Exception as e:
            return False, "Noise relay not reachable: " + describe_error(e)
        return True, f"Downlink channel set to {d.get('preset')} ({d.get('noiseDb'):g} dB noise)."

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
        if action.startswith("noise-"):
            if not MOCK and not ready("ue"):
                return False, "Start the UE first; the noise is applied to its receiver."
            with self.lock:
                ok, msg = self.set_noise(action[len("noise-"):])
                if ok:
                    self.log.append({"t": now_iso(), "action": action})
            if ok:
                print(f"{now_iso()} CONTROL {action}", flush=True)
            return ok, msg
        if action not in steps:
            raise ValueError("unknown action")
        if not MOCK:
            with STATE.lock:
                STATE.cached_at = 0  # decide on fresh pod states, not a 2 s old snapshot
            stopping = lambda role: any(p["cluster"] == "ran" and p["role"] == role and p["state"] == "stopping"
                                        for p in STATE.snapshot()["pods"])
            # A new UE (same SIM) or gNB next to one that is still shutting down puts two of them on the rfsim link.
            if action == "ue-start" and stopping("ue"):
                return False, "The previous UE is still stopping; press Start again when it has gone."
            if action == "gnb-start" and stopping("gnb"):
                return False, "The previous gNB is still stopping; press Start again when it has gone."
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


RE_K8S_TS = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)$")


def parse_k8s_ts(ts):
    """Kubelet log timestamp -> epoch seconds (microsecond precision). The kubelet writes UTC ('...Z') or the
    node's local offset ('2026-10-13T14:19:11.037992879+08:00', as on REDLAB); both must keep their offset."""
    m = RE_K8S_TS.match(ts)
    if not m:
        raise ValueError("unknown timestamp " + ts)
    base = datetime.fromisoformat(m[1] + ("+00:00" if m[3] == "Z" else m[3]))
    return base.timestamp() + float("0." + (m[2] or "0")[:6])


UU_KINDS = [("msg1", "Msg1"), ("msg2", "Msg2"), ("msg3", "Msg3"), ("msg4", "Msg4:"), ("msg4ack", "Msg4 acknowledged"),
            ("rrcComplete", "RRCSetupComplete")]


class UuEvents:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = collections.deque(maxlen=500)
        self.seen = collections.deque(maxlen=2000)
        self.seq = 0
        self.counts = {k: 0 for k, _ in UU_KINDS}   # since the dashboard started, for /metrics

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
                    for k, pre in UU_KINDS:
                        if self.events[-1]["msg"].startswith(pre):
                            self.counts[k] += 1
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


# ---- K1: core KPIs from the Open5GS Prometheus counters ---------------------
# Counters are scraped every PM_STEP seconds and kept in memory (PM_KEEP samples). A KPI is computed over a window
# from the counter deltas, like a PM report over a ROP. Counter names were checked on Open5GS 2.8.0 (metrics.sh).
PM_STEP = int(os.environ.get("PM_STEP", "15"))
PM_KEEP = int(os.environ.get("PM_KEEP", "1440"))           # 6 h at 15 s
PM_TARGETS = dict(kv.split("=", 1) for kv in os.environ.get(
    "CORE_METRICS",
    "amf=http://10.42.0.2:9090/metrics,smf=http://open5gs-smf-sbi.open5gs:9090/metrics,"
    "upf=http://10.42.0.2:9091/metrics,pcf=http://open5gs-pcf-sbi.open5gs:9090/metrics").split(","))
RE_PROM = re.compile(r'^([a-zA-Z_:][a-zA-Z0-9_:]*)(\{[^}]*\})?\s+(\S+)')


def parse_prom(text):
    """Prometheus text format -> {(metric, labels): value}; HELP/TYPE lines skipped."""
    out = {}
    for line in text.splitlines():
        if not line or line[0] == "#":
            continue
        m = RE_PROM.match(line)
        if m:
            try:
                out[(m[1], m[2] or "")] = float(m[3])
            except ValueError:
                pass
    return out


class PmStore:
    def __init__(self):
        self.lock = threading.Lock()
        self.samples = collections.deque(maxlen=PM_KEEP)    # (t, {nf: {(metric, labels): value}}, {nf: error})

    def scrape(self):
        vals, errs = {}, {}
        for nf, url in PM_TARGETS.items():
            try:
                with urllib.request.urlopen(url, timeout=3) as r:
                    vals[nf] = parse_prom(r.read().decode("utf-8", "replace"))
            except Exception as e:
                errs[nf] = describe_error(e)
        with self.lock:
            self.samples.append((time.time(), vals, errs))

    def window(self, seconds):
        """(first, last) samples spanning at most `seconds`; first is the oldest sample inside the window."""
        with self.lock:
            if not self.samples:
                return None, None
            last = self.samples[-1]
            first = next((s for s in self.samples if s[0] >= last[0] - seconds - PM_STEP / 2), last)
            return first, last


PM = PmStore()


def pm_collector():
    while True:
        t0 = time.time()
        if not MOCK or "CORE_METRICS" in os.environ:   # mock mode scrapes only when test endpoints are given
            PM.scrape()
        time.sleep(max(1.0, PM_STEP - (time.time() - t0)))


def _sum(sample, nf, metric):
    """Sum of a metric over all its label sets, or None when the NF or metric is absent."""
    vals = sample[1].get(nf)
    if vals is None:
        return None
    hits = [v for (m, _), v in vals.items() if m == metric]
    return sum(hits) if hits else None


def _delta(first, last, nf, metric):
    a, b = _sum(first, nf, metric), _sum(last, nf, metric)
    if b is None:
        return None
    if first[1].get(nf) is None:    # no data from this NF at the start (scrape failed, or before Prometheus existed):
        return 0                    # unknown start, do not count the whole cumulative value as a change
    if a is None or b < a:          # NF restarted inside the window: the counter started again from 0
        return b
    return b - a


def _by_label(first, last, nf, metric):
    """Per label set delta of a counter (the 'contributors' of a failure counter)."""
    out = []
    lv = last[1].get(nf, {})
    fv = first[1].get(nf, {})
    for (m, labels), v in lv.items():
        if m != metric:
            continue
        a = fv.get((m, labels))
        d = v if a is None or v < a else v - a
        if d:
            out.append({"labels": labels.strip("{}") or "(no label)", "delta": d})
    return sorted(out, key=lambda x: -x["delta"])


def _dsum(ss, nf, metric):
    """Counter change over a list of samples: sum of the changes between consecutive samples (each pair handles a reset)."""
    tot = None
    for a, b in zip(ss, ss[1:]):
        d = _delta(a, b, nf, metric)
        if d is not None:
            tot = (tot or 0) + d
    return tot


def _by_label_sum(ss, nf, metric):
    acc = {}
    for a, b in zip(ss, ss[1:]):
        for x in _by_label(a, b, nf, metric):
            acc[x["labels"]] = acc.get(x["labels"], 0) + x["delta"]
    return sorted(({"labels": k, "delta": v} for k, v in acc.items() if v), key=lambda x: -x["delta"])


# id, group, name, kind, numerator, denominator / extra, unit, target, 3GPP reference, failure contributors, hint
CORE_KPIS = [
    ("reg_init_sr", "Accessibility", "Initial registration success rate", "ratio",
     ("amf", "fivegs_amffunction_rm_reginitsucc"), ("amf", "fivegs_amffunction_rm_reginitreq"), "%", 99.0,
     "TS 28.552 5.2.1 RM.RegInitReq / RM.RegInitSucc; TS 28.554 registration success rate",
     [("amf", "fivegs_amffunction_rm_reginitfail"), ("amf", "fivegs_amffunction_amf_authfail"),
      ("amf", "fivegs_amffunction_amf_authreject")],
     "Failures by cause point to the step: authentication (authfail from the UE = keys/SQN; authreject from the AMF = "
     "subscriber or AUSF/UDM), no gNB connected (N2), or AMF cannot reach AUSF/UDM/PCF through the SCP."),
    ("reg_mob_sr", "Accessibility", "Mobility registration update success rate", "ratio",
     ("amf", "fivegs_amffunction_rm_regmobsucc"), ("amf", "fivegs_amffunction_rm_regmobreq"), "%", 99.0,
     "TS 28.552 5.2.1 RM.RegMobReq / RM.RegMobSucc", [("amf", "fivegs_amffunction_rm_regmobfail")],
     "A single cell bench has no mobility; attempts here mean the UE re-registered with a mobility update."),
    ("reg_period_sr", "Accessibility", "Periodic registration update success rate", "ratio",
     ("amf", "fivegs_amffunction_rm_regperiodsucc"), ("amf", "fivegs_amffunction_rm_regperiodreq"), "%", 99.0,
     "TS 28.552 5.2.1 RM.RegPeriodReq / RM.RegPeriodSucc (T3512 = 540 s on this core)",
     [("amf", "fivegs_amffunction_rm_regperiodfail")],
     "Periodic updates fail when the UE context was lost in the AMF (AMF restart) or the UE lost the cell."),
    ("auth_sr", "Accessibility", "Authentication success rate", "auth",
     ("amf", "fivegs_amffunction_amf_authreq"), None, "%", 99.0,
     "AMF authentication requests vs. failures (authfail) and rejects (authreject)",
     [("amf", "fivegs_amffunction_amf_authfail"), ("amf", "fivegs_amffunction_amf_authreject")],
     "authfail: the UE rejected the network (MAC or SQN failure: K/OPc in the UE and the subscriber DB differ, "
     "or SQN out of range). authreject: the network rejected the UE's RES."),
    ("pdu_sr", "Accessibility", "PDU session establishment success rate", "ratio",
     ("smf", "fivegs_smffunction_sm_pdusessioncreationsucc"), ("smf", "fivegs_smffunction_sm_pdusessioncreationreq"),
     "%", 99.0, "TS 28.552 5.3.1 SM.PduSessionCreationReq / Succ; TS 28.554 PDU session establishment success rate",
     [("smf", "fivegs_smffunction_sm_pdusessioncreationfail"), ("smf", "fivegs_smffunction_sm_n4sessionestabfail")],
     "Failures by cause: DNN or slice not in the subscription, no UE IP left in the pool, PCF policy refused, "
     "or the N4 session to the UPF failed (see N4 success rate and PFCP peers)."),
    ("n4_sr", "Accessibility", "N4 session establishment success rate", "n4",
     ("smf", "fivegs_smffunction_sm_n4sessionestabreq"), None, "%", 99.0,
     "TS 28.552 5.3.x SM.N4SessionEstab (SMF side); UPF side in the contributors",
     [("smf", "fivegs_smffunction_sm_n4sessionestabfail"), ("upf", "fivegs_upffunction_sm_n4sessionestabfail")],
     "N4 failures: PFCP association lost (UPF restarted), or the UPF could not install the rules (ogstun/route)."),
    ("pcf_am_sr", "Accessibility", "AM policy association success rate", "ratio",
     ("pcf", "fivegs_pcffunction_pa_policyamassosucc"), ("pcf", "fivegs_pcffunction_pa_policyamassoreq"), "%", 99.0,
     "PCF PA.PolicyAMAssoReq / Succ", [],
     "AMF to PCF over the SCP; a drop here with a good registration rate means the PCF or UDR is slow or down."),
    ("pcf_sm_sr", "Accessibility", "SM policy association success rate", "ratio",
     ("pcf", "fivegs_pcffunction_pa_policysmassosucc"), ("pcf", "fivegs_pcffunction_pa_policysmassoreq"), "%", 99.0,
     "PCF PA.PolicySMAssoReq / Succ", [],
     "SMF to PCF; failures block PDU sessions (see PDU session success rate)."),
    ("paging_sr", "Accessibility", "Paging success rate", "ratio",
     ("amf", "fivegs_amffunction_mm_paging5gsucc"), ("amf", "fivegs_amffunction_mm_paging5greq"), "%", 95.0,
     "TS 28.552 MM.Paging5GReq / Succ", [],
     "Paging is rare on the bench (the UE stays connected while it has traffic)."),
    ("n3_dl", "Integrity", "N3 downlink user-plane throughput", "rate",
     ("upf", "fivegs_ep_n3_gtp_outdatavolumeqosleveln3upf"), None, "Mbit/s", None,
     "TS 28.552 GTP.OutDataOctN3UPF (per QoS level), UPF to gNB", [], ""),
    ("n3_ul", "Integrity", "N3 uplink user-plane throughput", "rate",
     ("upf", "fivegs_ep_n3_gtp_indatavolumeqosleveln3upf"), None, "Mbit/s", None,
     "TS 28.552 GTP.InDataOctN3UPF (per QoS level), gNB to UPF", [], ""),
    ("gnb", "Load", "gNBs connected to the AMF", "gauge", ("amf", "gnb"), None, "", 1, "AMF gauge", [],
     "0 means no N2 link: gNB down or SCTP to 10.42.0.2:38412 broken."),
    ("ran_ue", "Load", "UEs known to the AMF (RAN UE contexts)", "gauge", ("amf", "ran_ue"), None, "", None, "AMF gauge", [], ""),
    ("reg_subs", "Load", "Registered subscribers", "gauge", ("amf", "fivegs_amffunction_rm_registeredsubnbr"), None, "",
     None, "TS 28.552 RM.RegisteredSubNbr", [], ""),
    ("pdu_sessions", "Load", "Active PDU sessions (SMF)", "gauge", ("smf", "fivegs_smffunction_sm_sessionnbr"), None, "",
     None, "TS 28.552 SM.SessionNbr", [], ""),
    ("upf_sessions", "Load", "Active N4 sessions (UPF)", "gauge", ("upf", "fivegs_upffunction_upf_sessionnbr"), None, "",
     None, "UPF gauge", [], ""),
    ("pfcp_peers", "Load", "PFCP peers of the SMF", "gauge", ("smf", "pfcp_peers_active"), None, "", 1, "SMF gauge", [],
     "0 means the SMF has no UPF: no PDU session can be set up."),
]


def core_eval(ss):
    """Core KPIs from a list of samples (t, {nf: {(metric, labels): value}}, errors), oldest first."""
    first, last = ss[0], ss[-1]
    span = last[0] - first[0]
    res = []
    for kid, group, name, kind, num, den, unit, target, ref, contrib, hint in CORE_KPIS:
        k = {"id": kid, "group": group, "name": name, "unit": unit, "target": target, "ref": ref, "hint": hint,
             "value": None, "counters": [], "contributors": [], "status": "nodata"}
        if kind == "gauge":
            v = _sum(last, *num)
            k["value"] = v
            k["counters"] = [{"name": num[1], "nf": num[0], "value": v}]
            k["status"] = "nodata" if v is None else ("info" if target is None else ("bad" if v < target else "ok"))
        elif kind == "rate":
            d = _dsum(ss, *num)
            k["counters"] = [{"name": num[1], "nf": num[0], "delta": d}]
            if d is not None and span > 0:
                k["value"] = d * 8 / span / 1e6
                k["status"] = "info"
        else:
            req = _dsum(ss, *num) if kind in ("auth", "n4") else _dsum(ss, *den)
            if kind == "ratio":
                succ = _dsum(ss, *num)
                k["counters"] = [{"name": num[1], "nf": num[0], "delta": succ}, {"name": den[1], "nf": den[0], "delta": req}]
            else:                    # success = requests minus the failure counters
                fails = [_dsum(ss, *c) for c in contrib if c[0] == num[0]]
                succ = None if req is None else req - sum(f or 0 for f in fails)
                k["counters"] = [{"name": num[1], "nf": num[0], "delta": req}] + \
                    [{"name": c[1], "nf": c[0], "delta": f} for c, f in zip([c for c in contrib if c[0] == num[0]], fails)]
            if req is None:
                k["status"] = "nodata"
            elif req == 0:
                k["status"] = "idle"            # no attempts in the window: nothing to judge
            else:
                k["value"] = 100.0 * max(0.0, succ or 0) / req
                k["status"] = "ok" if k["value"] >= target else "bad"
        for nf, metric in contrib:
            d = _dsum(ss, nf, metric)
            k["contributors"].append({"name": metric, "nf": nf, "delta": d, "byLabel": _by_label_sum(ss, nf, metric)})
        res.append(k)
    return {"span": round(span), "kpis": res, "errors": dict(last[2])}


def core_kpis(seconds, source=""):
    """Window KPIs from memory when the in-memory samples cover the window, else from Prometheus (P1b).
    The trend series always come from Prometheus (about 60 buckets over the window)."""
    first, last = PM.window(seconds)
    mem_ok = last is not None and last[0] - first[0] >= seconds - 2 * PM_STEP
    step = bucket_step(seconds, 30)
    ss, perr = [], None
    try:
        ss = prom_core_samples(seconds, step)
    except Exception as e:
        perr = describe_error(e)
    use_prom = source == "prom" or (source != "mem" and not mem_ok and len(ss) >= 2)
    if use_prom and len(ss) >= 2:
        out, src, n, used_step = core_eval(ss), "prometheus", len(ss), step
    elif last is not None:
        out, src, n, used_step = core_eval([first, last]), "memory", len(PM.samples), PM_STEP
    else:
        out, src, n, used_step = {"span": 0, "kpis": [], "errors": {"pm": "no sample yet"}}, "none", 0, PM_STEP
    series = {}
    for a, b in zip(ss, ss[1:]):
        for k in core_eval([a, b])["kpis"]:
            series.setdefault(k["id"], []).append([b[0], k["value"]])
    if perr:
        out["errors"]["prometheus"] = perr
    out.update({"window": seconds, "samples": n, "step": used_step, "source": src, "seriesStep": step, "series": series,
                "time": now_iso()})
    return out

def ran_counter_deltas(seconds):
    """Sum over RNTIs of the counter changes inside the window, plus averages of the radio values."""
    cut = time.time() - seconds
    tot = {k: 0 for k in COUNTERS if k != "oos"}
    oos = n = 0
    avg = {k: [] for k in ("cqi", "mcsDl", "mcsUl", "sinrUe", "goodputDl", "goodputUl", "blerDl", "blerUl",
                           "tputDlAct", "tputUlAct", "mcsDlAct")}
    with HISTORY.lock:
        series = {r: [x for x in d if x["t"] >= cut] for r, d in HISTORY.by_rnti.items()}
    for rows in series.values():
        rows = [x for x in rows if x.get("dlR0") is not None]
        if not rows:
            continue
        first, last = rows[0], rows[-1]
        for k in tot:
            a, b = first.get(k), last.get(k)
            if a is not None and b is not None:
                tot[k] += b - a if b >= a else b
        for x in rows:
            n += 1
            oos += x.get("oos") or 0
            for k in avg:
                if x.get(k) is not None:
                    avg[k].append(x[k])
            if (x.get("goodputDl") or 0) >= ACTIVE["dl"]:
                avg["tputDlAct"].append(x["goodputDl"])
                if x.get("mcsDl") is not None:
                    avg["mcsDlAct"].append(x["mcsDl"])
            if (x.get("goodputUl") or 0) >= ACTIVE["ul"]:
                avg["tputUlAct"].append(x["goodputUl"])
    act = {"dl": len(avg["tputDlAct"]), "ul": len(avg["tputUlAct"])}
    return tot, oos, n, {k: (sum(v) / len(v) if v else None) for k, v in avg.items()}, act


def uu_counts(seconds):
    cut = time.time() - seconds
    with UU.lock:
        ev = [e["msg"] for e in UU.events if e["t"] >= cut]
    return {k: sum(1 for m in ev if m.startswith(pre)) for k, pre in UU_KINDS}


def _pct(a, b):
    return None if not b else 100.0 * a / b


def ran_kpis(seconds, source=""):
    """Window KPIs from the 1 s in-memory history when it covers the window, else from Prometheus (P1b);
    trend series from Prometheus."""
    with HISTORY.lock:
        oldest = min((d[0]["t"] for d in HISTORY.by_rnti.values() if d), default=None)
    mem_ok = oldest is not None and oldest <= time.time() - seconds + 5
    step = bucket_step(seconds, 15)
    buckets, perr = [], None
    try:
        buckets = prom_ran_buckets(seconds, step)
    except Exception as e:
        perr = describe_error(e)
    use_prom = source == "prom" or (source != "mem" and not mem_ok and buckets)
    if use_prom and buckets:
        out = ran_eval(*ran_sum_buckets(buckets), seconds)
        out.update({"source": "prometheus", "step": DASH_SCRAPE})
    else:
        tot, oos, n, avg, act = ran_counter_deltas(seconds)
        out = ran_eval(tot, oos, n, avg, act, uu_counts(seconds), seconds)
        out.update({"source": "memory", "step": 1})
    series = {}
    for b in buckets:
        for k in ran_eval(*ran_sum_buckets([b]), step)["kpis"]:
            series.setdefault(k["id"], []).append([b["t"], k["value"] if k["status"] not in ("idle", "nodata") else None])
    if perr:
        out["errors"]["prometheus"] = perr
    out.update({"seriesStep": step, "series": series})
    return out


def ran_eval(tot, oos, n, avg, act, uu, seconds):
    dl_tx = tot["dlR0"]; ul_tx = tot["ulR0"]
    dl_retx = tot["dlR1"] + tot["dlR2"] + tot["dlR3"]; ul_retx = tot["ulR1"] + tot["ulR2"] + tot["ulR3"]
    radio = [{"name": "Average CQI", "value": avg["cqi"]}, {"name": "Average UE SINR (dB)", "value": avg["sinrUe"]},
             {"name": "Average DL MCS", "value": avg["mcsDl"]}, {"name": "Average DL BLER (%)", "value": None if avg["blerDl"] is None else 100 * avg["blerDl"]},
             {"name": "Average DL MAC goodput (Mbit/s)", "value": avg["goodputDl"]}]
    cnt = lambda *names: [{"name": x, "nf": "gNB", "delta": tot.get(x, uu.get(x))} for x in names]
    defs = [
        ("rach_sr", "Accessibility", "Random access success rate", _pct(uu["msg4ack"], uu["msg1"]), uu["msg1"], "%", 99.0, "min",
         cnt("msg1", "msg2", "msg3", "msg4", "msg4ack"),
         "Read the chain Msg1 -> Msg2 -> Msg3 -> Msg4 -> Msg4 ACK: a loss between Msg1 and Msg3 means the UE did not "
         "get or use the RAR (PRACH power, timing advance, RAR window); a loss after Msg3 means contention resolution "
         "failed (two UEs with the same identity on the link, or Msg4 not decoded).",
         "TS 38.321 5.1 random access; counted from the gNB log (Msg1 = preamble detected, success = Msg4 acknowledged)"),
        ("rrc_sr", "Accessibility", "RRC setup success rate", _pct(uu["rrcComplete"], uu["msg3"]), uu["msg3"], "%", 99.0, "min",
         cnt("msg3", "rrcComplete"),
         "RRCSetupRequest (in Msg3) without RRCSetupComplete: RRCSetup not decoded, UE timer T300 expired, or the UE "
         "restarted during the setup.", "TS 38.331 RRC connection establishment; TS 28.552 RRC.ConnEstabAtt / Succ"),
        ("dl_retx", "Integrity", "DL HARQ retransmission rate", _pct(dl_retx, dl_tx), dl_tx, "%", 10.0, "max",
         [{"name": "dlR0 (1st transmissions)", "nf": "gNB", "delta": dl_tx}, {"name": "dlR1-3 (retransmissions)", "nf": "gNB", "delta": dl_retx}] + radio,
         "Above the 10 % BLER target the link adaptation is not following the channel. Read down the chain: UE SINR "
         "(noise or interference) -> CQI reported -> DL MCS chosen -> BLER. Low SINR with a matching CQI is the channel; "
         "a good SINR with a high BLER points to CQI reporting or the MCS offset.",
         "First transmissions vs HARQ retransmissions (OAI dlsch_rounds); 38.214 targets 10 % BLER on the first transmission"),
        ("dl_resid", "Integrity", "DL residual BLER (TB lost after all HARQ rounds)", _pct(tot["dlErr"], dl_tx), dl_tx, "%", 1.0, "max",
         cnt("dlErr", "dlR0"), "Residual errors reach RLC/TCP and cut throughput; they follow a high retransmission rate.",
         "OAI dlsch_errors / dlsch_rounds[1st]"),
        ("pucch_dtx", "Integrity", "PUCCH DTX rate (HARQ feedback not received)", _pct(tot["pucchDtx"], dl_tx), dl_tx, "%", 1.0, "max",
         cnt("pucchDtx", "dlR0"),
         "The gNB expected HARQ ACK/NACK and got nothing: the UE missed the DL assignment (PDCCH) or its PUCCH was too weak.",
         "OAI pucch0_DTX / DL first transmissions"),
        ("ul_retx", "Integrity", "UL HARQ retransmission rate", _pct(ul_retx, ul_tx), ul_tx, "%", 10.0, "max",
         [{"name": "ulR0 (1st transmissions)", "nf": "gNB", "delta": ul_tx}, {"name": "ulR1-3 (retransmissions)", "nf": "gNB", "delta": ul_retx}],
         "UL decoding failures: PUSCH SNR below the MCS in use (UL power control, see the UE KPIs) or UL interference.",
         "OAI ulsch_rounds"),
        ("ul_resid", "Integrity", "UL residual BLER", _pct(tot["ulErr"], ul_tx), ul_tx, "%", 1.0, "max", cnt("ulErr", "ulR0"),
         "", "OAI ulsch_errors / ulsch_rounds[1st]"),
        ("ul_dtx", "Integrity", "PUSCH DTX rate (granted but nothing received)", _pct(tot["ulDtx"], ul_tx), ul_tx, "%", 1.0, "max",
         cnt("ulDtx", "ulR0"), "The UE did not send on its UL grant: it missed the DCI or lost UL sync.", "OAI ulsch_DTX"),
        ("oos", "Retainability", "Time out of sync", _pct(oos, n), n, "%", 0.0, "max",
         [{"name": "samples out-of-sync", "nf": "gNB", "delta": oos}, {"name": "samples", "nf": "gNB", "delta": n}],
         "The gNB lost the UE (no UL for a while): radio link failure follows. Check SINR, the noise preset and whether the UE pod restarted.",
         "OAI in-sync / out-of-sync state per UE, sampled once a second"),
        ("cce_fail", "Utilization", "PDCCH allocation failures (CCE)", tot["cceDl"] + tot["cceUl"], None, "", None, "info",
         cnt("cceDl", "cceUl"), "CCE failures mean the PDCCH had no room for a DCI in that slot; they delay scheduling.",
         "OAI CCE fail counters (DL and UL)"),
        ("dl_tput", "Integrity", "DL user throughput (seconds with data)", avg["tputDlAct"], act["dl"], "Mbit/s",
         round(BASE_TPUT_RATIO * BASELINE["dlTput"], 1), "min",
         [{"name": "seconds with DL data", "nf": "gNB", "delta": act["dl"]},
          {"name": "DL baseline (stage 3, Mbit/s)", "value": BASELINE["dlTput"], "nf": ""}] + radio[:3] +
         [{"name": "Average DL MCS in seconds with data", "value": avg["mcsDlAct"]}],
         "Below 80 % of the bench baseline. Open the UE KPIs: the diagnosis follows SINR -> CQI -> MCS -> BLER -> "
         "throughput and names the first link that fails. Noise lowers the MCS, not the BLER.",
         "MAC goodput averaged over the seconds with data (>= 10 % of the baseline; idle seconds and TCP ACK traffic excluded, "
         "as in a user-throughput KPI); "
         "simulated time in rfsim; target = 80 % of the stage 3 baseline"),
        ("ul_tput", "Integrity", "UL user throughput (seconds with data)", avg["tputUlAct"], act["ul"], "Mbit/s",
         round(BASE_TPUT_RATIO * BASELINE["ulTput"], 1), "min",
         [{"name": "seconds with UL data", "nf": "gNB", "delta": act["ul"]},
          {"name": "UL baseline (stage 3, Mbit/s)", "value": BASELINE["ulTput"], "nf": ""}], "",
         "Same, uplink"),
    ]
    out = []
    for kid, group, name, val, attempts, unit, target, sense, counters, hint, ref in defs:
        if sense == "info":
            status = "info" if val is not None else "nodata"
        elif attempts is None or n == 0 and kid not in ("rach_sr", "rrc_sr"):
            status = "nodata"
        elif not attempts:
            status = "idle"
        else:
            status = "ok" if (val >= target if sense == "min" else val <= target) else "bad"
        out.append({"id": kid, "group": group, "name": name, "unit": unit, "target": target, "sense": sense, "ref": ref,
                    "hint": hint, "value": val, "status": status,
                    "counters": [{**c, "nf": c.get("nf", "gNB")} for c in counters],
                    "contributors": []})
    return {"window": seconds, "span": seconds, "samples": n, "step": 1, "time": now_iso(), "kpis": out, "errors": {}}


# ---- K3/K4: KPIs per UE and degradation against the bench baseline --------------
# Targets are bench rules, not 3GPP values: the stage 3 baseline (rfsim with chanmod, noise off) is the reference.
# A throughput below 80 % of the baseline, a CQI more than 2 below it or a DL MCS more than 4 below it is degraded;
# the SINR target is the typical SINR for that lowest good CQI (TYPICAL_SINR_T1). Throughput and MCS only count the
# seconds with data (see ACTIVE): idle seconds report MCS 0 and goodput 0 and are not a degradation.
BASELINE = {"dlTput": float(os.environ.get("BASELINE_DL_MBPS", "50.9")), "ulTput": float(os.environ.get("BASELINE_UL_MBPS", "35.3")),
            "cqi": int(os.environ.get("BASELINE_CQI", "15")), "mcsDl": int(os.environ.get("BASELINE_MCS_DL", "28"))}
BASE_TPUT_RATIO, BASE_CQI_DROP, BASE_MCS_DROP = 0.8, 2, 4
# A second "has data" in a direction when its goodput is >= 10 % of that direction's baseline: TCP ACKs of a speed
# test in the other direction (about 1-3 Mbit/s) must not count as a slow transfer.
ACTIVE = {"dl": max(1.0, 0.1 * BASELINE["dlTput"]), "ul": max(1.0, 0.1 * BASELINE["ulTput"])}


def _mean(v):
    v = [x for x in v if x is not None]
    return sum(v) / len(v) if v else None


def _grade(val, attempts, target, sense):
    if target is None:
        return "info" if val is not None else "nodata"
    if attempts is None:
        return "nodata"
    if not attempts:
        return "idle"
    if val is None:
        return "nodata"
    return "ok" if (val >= target if sense == "min" else val <= target) else "bad"


def ue_eval(rows):
    """KPIs of one UE (one RNTI) from its rows in the window."""
    cnt = [x for x in rows if x.get("dlR0") is not None]
    d = {k: 0 for k in COUNTERS if k != "oos"}
    if cnt:
        for k in d:
            a, b = cnt[0].get(k), cnt[-1].get(k)
            if a is not None and b is not None:
                d[k] = b - a if b >= a else b
    act_dl = [x for x in rows if (x.get("goodputDl") or 0) >= ACTIVE["dl"]]
    act_ul = [x for x in rows if (x.get("goodputUl") or 0) >= ACTIVE["ul"]]
    v = {"sinr": _mean(x.get("sinrUe") for x in rows), "cqi": _mean(x.get("cqi") for x in rows),
         "mcsDl": _mean(x.get("mcsDl") for x in act_dl), "mcsUl": _mean(x.get("mcsUl") for x in act_ul),
         "tputDl": _mean(x["goodputDl"] for x in act_dl), "tputUl": _mean(x["goodputUl"] for x in act_ul),
         "rsrp": _mean(x.get("rsrp") for x in rows), "ph": rows[-1].get("ph") if rows else None,
         "pcmax": rows[-1].get("pcmax") if rows else None,
         "nprbUl": _mean(x.get("nprbUl") for x in act_ul)}
    n_cqi = sum(1 for x in rows if x.get("cqi") is not None)
    n_sinr = sum(1 for x in rows if x.get("sinrUe") is not None)
    dl_tx, ul_tx = d["dlR0"], d["ulR0"]
    dl_rt, ul_rt = d["dlR1"] + d["dlR2"] + d["dlR3"], d["ulR1"] + d["ulR2"] + d["ulR3"]
    oos = sum(x.get("oos") or 0 for x in cnt)
    cqi_t = BASELINE["cqi"] - BASE_CQI_DROP
    sinr_t = TYPICAL_SINR_T1[cqi_t - 1]
    base = lambda name, val: {"name": name, "value": val, "nf": ""}
    defs = [
        ("sinr", "Radio quality", "UE SINR (SSB, UE side)", v["sinr"], n_sinr or None, "dB", sinr_t, "min",
         [base("samples", n_sinr), base("SINR needed for CQI %d (typical)" % cqi_t, sinr_t)],
         "Low SINR means noise or interference on the DL. In this bench the only source is the noise preset (AWGN on "
         "the UE receiver); check the DL channel buttons.", "UE log 'DL Chan: SSB SINR'; target = typical SINR for CQI %d "
         "at 10 %% BLER (link-level value, not 3GPP)" % cqi_t),
        ("cqi", "Radio quality", "Average CQI", v["cqi"], n_cqi or None, "", cqi_t, "min",
         [base("samples", n_cqi), base("baseline CQI", BASELINE["cqi"]), base("average UE SINR (dB)", v["sinr"])],
         "CQI follows SINR. A low CQI with a good SINR points to CSI-RS / CSI report configuration, not the channel.",
         "gNB 'CSI [CQI n'; TS 38.214 5.2.2.1; target = baseline CQI - %d" % BASE_CQI_DROP),
        ("mcs_dl", "Radio quality", "Average DL MCS (seconds with data)", v["mcsDl"], len(act_dl), "",
         BASELINE["mcsDl"] - BASE_MCS_DROP, "min",
         [base("seconds with DL data", len(act_dl)), base("baseline DL MCS", BASELINE["mcsDl"]), base("average CQI", v["cqi"])],
         "The scheduler picks the MCS from the CQI and lowers it further when the BLER is high. A low MCS with a good "
         "CQI points to the BLER-based backoff or an MCS limit in the gNB config.",
         "gNB 'MCS (table) n'; TS 38.214 Table 5.1.3.1-1; target = baseline MCS - %d" % BASE_MCS_DROP),
        ("dl_retx", "Integrity", "DL HARQ retransmission rate", _pct(dl_rt, dl_tx), dl_tx, "%", 10.0, "max",
         [{"name": "dlR0 (1st transmissions)", "delta": dl_tx}, {"name": "dlR1-3 (retransmissions)", "delta": dl_rt},
          {"name": "dlErr (residual)", "delta": d["dlErr"]}, {"name": "pucchDtx", "delta": d["pucchDtx"]}],
         "Above 10 % the link adaptation does not follow the channel (MCS too high for the SINR).",
         "OAI dlsch_rounds per RNTI; 38.214 BLER target 10 %"),
        ("dl_tput", "Integrity", "DL user throughput (seconds with data)", v["tputDl"], len(act_dl), "Mbit/s",
         round(BASE_TPUT_RATIO * BASELINE["dlTput"], 1), "min",
         [base("seconds with DL data", len(act_dl)), base("DL baseline (Mbit/s)", BASELINE["dlTput"]),
          base("average DL MCS", v["mcsDl"])],
         "See the diagnosis above: it names the first link of SINR -> CQI -> MCS -> BLER -> throughput that fails.",
         "MAC goodput in seconds with data (>= 10 % of the baseline), simulated time; target = 80 % of the stage 3 baseline"),
        ("ul_retx", "Integrity", "UL HARQ retransmission rate", _pct(ul_rt, ul_tx), ul_tx, "%", 10.0, "max",
         [{"name": "ulR0 (1st transmissions)", "delta": ul_tx}, {"name": "ulR1-3 (retransmissions)", "delta": ul_rt},
          {"name": "ulErr (residual)", "delta": d["ulErr"]}, {"name": "ulDtx", "delta": d["ulDtx"]}],
         "UL decoding failures: PUSCH SNR too low for the UL MCS.", "OAI ulsch_rounds per RNTI"),
        ("ul_tput", "Integrity", "UL user throughput (seconds with data)", v["tputUl"], len(act_ul), "Mbit/s",
         round(BASE_TPUT_RATIO * BASELINE["ulTput"], 1), "min",
         [base("seconds with UL data", len(act_ul)), base("UL baseline (Mbit/s)", BASELINE["ulTput"]),
          base("average UL MCS", v["mcsUl"]), base("average UL PRBs", v["nprbUl"])], "",
         "Same, uplink"),
        ("oos", "Retainability", "Time out of sync", _pct(oos, len(cnt)), len(cnt), "%", 0.0, "max",
         [{"name": "samples out-of-sync", "delta": oos}, {"name": "samples", "delta": len(cnt)}],
         "The gNB lost this UE: radio link failure follows.", "OAI in-sync / out-of-sync per RNTI, sampled once a second"),
        ("rsrp", "Info", "Average RSRP (gNB report)", v["rsrp"], None, "dBm", None, "info", [], "",
         "rfsim has no path loss: RSRP stays near -41 dBm and does not show the noise preset"),
        ("ph", "Info", "Power headroom (last report)", v["ph"], None, "dB", None, "info",
         [base("PCMAX (dBm)", v["pcmax"])],
         "Not used as a KPI: in rfsim the reported PH moves the wrong way (exp-power.sh).", "TS 38.321 PHR; observation only"),
    ]
    out = []
    for kid, group, name, val, att, unit, target, sense, counters, hint, ref in defs:
        out.append({"id": kid, "group": group, "name": name, "unit": unit, "target": target, "sense": sense, "ref": ref,
                    "hint": hint, "value": val, "status": _grade(val, att, target, sense),
                    "counters": [{**c, "nf": c.get("nf", "gNB")} for c in counters], "contributors": []})
    return out, len(act_dl), len(act_ul)


def diagnose(kpis):
    """K4: the first failing link of SINR -> CQI -> MCS -> BLER -> throughput is the root cause."""
    k = {x["id"]: x for x in kpis}
    st = lambda i: k[i]["status"]
    f = lambda i, nd=1: "–" if k[i]["value"] is None else ("%." + str(nd) + "f") % k[i]["value"]
    chain = [{"id": i, "name": n, "value": k[i]["value"], "unit": k[i]["unit"], "status": st(i)}
             for i, n in (("sinr", "SINR"), ("cqi", "CQI"), ("mcs_dl", "DL MCS"), ("dl_retx", "DL BLER (retx)"),
                          ("dl_tput", "DL throughput"))]
    deg = [i for i in ("sinr", "cqi", "mcs_dl", "dl_retx", "dl_tput", "ul_retx", "ul_tput", "oos") if st(i) == "bad"]
    if not deg:
        idle = st("dl_tput") == "idle"
        return {"id": "none", "status": "ok", "chain": chain,
                "summary": "No degradation." + (" No DL data in the window: start a DL speed test to grade the MCS and "
                                                 "throughput." if idle else "")}
    if st("oos") == "bad":
        cid, txt = "rlf", "The gNB lost the UE (out of sync %s %% of the time): radio link failure. Check the noise preset " \
                          "and whether the UE pod restarted." % f("oos")
    elif st("sinr") == "bad":
        cid, txt = "radio_sinr", ("Low SINR (%s dB) -> CQI %s -> DL MCS %s -> %s Mbit/s. The link adaptation works "
                                  "(retransmissions %s %%), so the cause is the channel: noise or interference on the DL "
                                  "(here: the noise preset)." % (f("sinr"), f("cqi"), f("mcs_dl"), f("dl_tput"), f("dl_retx", 2)))
    elif st("cqi") == "bad":
        cid, txt = "cqi_report", "SINR is fine (%s dB) but the CQI is low (%s): CSI reporting or CSI-RS configuration, " \
                                 "not the channel." % (f("sinr"), f("cqi"))
    elif st("mcs_dl") == "bad":
        cid, txt = "mcs_choice", "CQI is fine (%s) but the DL MCS is low (%s): BLER-based MCS backoff or an MCS limit in " \
                                 "the gNB config." % (f("cqi"), f("mcs_dl"))
    elif st("dl_retx") == "bad":
        cid, txt = "link_adaptation", "Radio is fine but %s %% of the DL TBs need a retransmission: the MCS is too high for " \
                                      "the channel (link adaptation)." % f("dl_retx", 2)
    elif st("dl_tput") == "bad":
        cid, txt = "not_radio", "SINR, CQI, MCS and BLER are within target but DL throughput is %s Mbit/s: not the radio. " \
                                "Check the PRB share and CCE failures (RAN KPIs), the traffic source (iperf3), the rfsim " \
                                "CPU load, or the core user plane (UPF)." % f("dl_tput")
    elif st("ul_retx") == "bad":
        cid, txt = "ul_decoding", "UL retransmissions %s %%: PUSCH SNR too low for the UL MCS." % f("ul_retx", 2)
    else:
        cid, txt = "ul_not_radio", "UL throughput is %s Mbit/s with UL decoding fine: check the UL PRBs, the traffic " \
                                   "source, the rfsim CPU load or the UPF." % f("ul_tput")
    return {"id": cid, "status": "bad", "chain": chain, "summary": txt, "degraded": deg}


def ue_kpis(seconds):
    cut = time.time() - seconds
    with HISTORY.lock:
        series = {r: [x for x in d if x["t"] >= cut] for r, d in HISTORY.by_rnti.items()}
    ues = []
    for rnti, rows in sorted(series.items(), key=lambda kv: -(kv[1][-1]["t"] if kv[1] else 0)):
        if not rows:
            continue
        kp, a_dl, a_ul = ue_eval(rows)
        ues.append({"rnti": rnti, "samples": len(rows), "activeDl": a_dl, "activeUl": a_ul,
                    "first": rows[0]["t"], "last": rows[-1]["t"], "kpis": kp, "diagnosis": diagnose(kp)})
    return {"window": seconds, "span": seconds, "samples": sum(u["samples"] for u in ues), "step": 1, "time": now_iso(),
            "baseline": BASELINE, "rules": {"tputRatio": BASE_TPUT_RATIO, "cqiDrop": BASE_CQI_DROP, "mcsDrop": BASE_MCS_DROP,
                                            "activeMbps": ACTIVE}, "ues": ues, "kpis": [], "errors": {}}


# ---- P1b: KPI windows and trends from Prometheus ---------------------------------------
# Prometheus (P1a) keeps the counters 30 days. For a window or a trend the dashboard asks for the counter values at
# bucket boundaries (query_range at the bucket step) and runs the same KPI code on them as on its in-memory samples,
# so KPIs, counters and contributors mean the same whatever the source. Radio averages and "seconds with data" use
# *_over_time sums and counts per bucket (the dashboard is scraped every DASH_SCRAPE seconds).
PROM_URL = os.environ.get("PROM_URL", "http://prometheus.fct-dash.svc:9090").rstrip("/")
DASH_SCRAPE = 5
BUCKETS = 60


def bucket_step(seconds, minimum):
    return int(max(minimum, math.ceil(seconds / BUCKETS / 5) * 5))


def prom_get(path, **params):
    url = f"{PROM_URL}{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=8) as r:
        d = json.loads(r.read())
    if d.get("status") != "success":
        raise RuntimeError(d.get("error", "query failed"))
    return d["data"]["result"]


def _range(query, seconds, step, offset=0):
    """query_range over the window ending now; boundaries t0..tn every step with tn = now (the last bucket ends now)."""
    end = math.floor(time.time())
    return prom_get("/api/v1/query_range", query=query, start=end - math.ceil(seconds / step) * step + offset, end=end, step=step)


def _num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return None if math.isnan(x) or math.isinf(x) else x


def prom_core_samples(seconds, step):
    """Open5GS counters at every bucket boundary, in the in-memory sample format."""
    by_t = {}
    for r in _range('{job="open5gs"}', seconds, step):
        m = r["metric"]
        name, nf = m.get("__name__"), m.get("nf")
        if not name or not nf:
            continue
        lab = {k: v for k, v in m.items() if k not in ("__name__", "job", "instance", "nf")}
        labels = "{" + ",".join('%s="%s"' % kv for kv in sorted(lab.items())) + "}" if lab else ""
        for t, v in r["values"]:
            x = _num(v)
            if x is not None:
                by_t.setdefault(float(t), {}).setdefault(nf, {})[(name, labels)] = x
    return [(t, by_t[t], {}) for t in sorted(by_t)]


def _series_deltas(result, key):
    """Per bucket (t_i-1, t_i] the counter change of each series, summed per `key` label (a reset counts from 0)."""
    out = {}
    for r in result:
        k = r["metric"].get(key)
        vals = [(float(t), _num(v)) for t, v in r["values"]]
        for (ta, a), (tb, b) in zip(vals, vals[1:]):
            if a is None or b is None:   # no start value (series new, or no data yet): skip, as Prometheus increase() does
                continue
            d = b if b < a else b - a
            out.setdefault(tb, {}).setdefault(k, 0)
            out[tb][k] += d
    return out


def _per_t(result, key=None):
    out = {}
    for r in result:
        k = r["metric"].get(key) if key else None
        for t, v in r["values"]:
            x = _num(v)
            if x is not None:
                out.setdefault(float(t), {})[k] = x
    return out


def prom_ran_buckets(seconds, step):
    """RAN inputs per bucket: counter changes, Uu events, radio sums/counts, active seconds, out-of-sync samples."""
    w, sub = f"{step}s", f"[{step}s:{DASH_SCRAPE}s]"
    mac = _series_deltas(_range("fct_gnb_mac_total", seconds, step), "counter")
    uu = _series_deltas(_range("fct_uu_events_total", seconds, step), "msg")
    rs = _per_t(_range(f"sum by (field) (sum_over_time(fct_ue_radio[{w}]))", seconds, step, step), "field")
    rc = _per_t(_range(f"sum by (field) (count_over_time(fct_ue_radio[{w}]))", seconds, step, step), "field")
    os_ = _per_t(_range(f"sum(sum_over_time(fct_ue_out_of_sync[{w}]))", seconds, step, step))
    on = _per_t(_range(f"sum(count_over_time(fct_ue_out_of_sync[{w}]))", seconds, step, step))
    act = {}
    for name, val, gate, thr in (("tputDlAct", "goodputDl", "goodputDl", ACTIVE["dl"]), ("tputUlAct", "goodputUl", "goodputUl", ACTIVE["ul"]),
                                 ("mcsDlAct", "mcsDl", "goodputDl", ACTIVE["dl"])):
        sel = f'fct_ue_radio{{field="{val}"}} and ignoring(field) fct_ue_radio{{field="{gate}"}} >= {thr}' if val != gate \
            else f'fct_ue_radio{{field="{val}"}} >= {thr}'
        act[name] = (_per_t(_range(f"sum(sum_over_time(({sel}){sub}))", seconds, step, step)),
                     _per_t(_range(f"sum(count_over_time(({sel}){sub}))", seconds, step, step)))
    ts = sorted(set(rc) | set(mac) | set(on))
    out = []
    for t in ts:
        sums = dict(rs.get(t, {})); cnts = dict(rc.get(t, {}))
        for name, (sm, ct) in act.items():
            sums[name] = sm.get(t, {}).get(None, 0.0); cnts[name] = ct.get(t, {}).get(None, 0.0)
        out.append({"t": t, "mac": mac.get(t, {}), "uu": uu.get(t, {}), "sums": sums, "cnts": cnts,
                    "oos": os_.get(t, {}).get(None, 0.0), "n": on.get(t, {}).get(None, 0.0)})
    return out


def ran_sum_buckets(buckets):
    """Add buckets into the inputs of ran_eval (same meaning as the in-memory path; seconds = samples x scrape)."""
    tot = {k: 0 for k in COUNTERS if k != "oos"}
    uu = {k: 0 for k, _ in UU_KINDS}
    sums, cnts, oos, n = {}, {}, 0.0, 0.0
    for b in buckets:
        for k, v in b["mac"].items():
            if k in tot:
                tot[k] += v
        for k, v in b["uu"].items():
            if k in uu:
                uu[k] += int(v)
        for k, v in b["sums"].items():
            sums[k] = sums.get(k, 0.0) + v
        for k, v in b["cnts"].items():
            cnts[k] = cnts.get(k, 0.0) + v
        oos += b["oos"]; n += b["n"]
    keys = ("cqi", "mcsDl", "mcsUl", "sinrUe", "goodputDl", "goodputUl", "blerDl", "blerUl", "tputDlAct", "tputUlAct", "mcsDlAct")
    avg = {k: (sums[k] / cnts[k] if cnts.get(k) else None) for k in keys}
    act = {"dl": int(cnts.get("tputDlAct", 0) * DASH_SCRAPE), "ul": int(cnts.get("tputUlAct", 0) * DASH_SCRAPE)}
    return tot, int(oos), int(n), avg, act, uu


# ---- P1: RAN and UE metrics for Prometheus (history beyond the in-memory windows) ----------
# Exposition text format. Counters are the cumulative OAI MAC counters per RNTI (a new RNTI starts at 0, which
# Prometheus increase() handles like a counter reset); gauges are the latest per-second sample of each RNTI seen in
# the last METRICS_FRESH seconds. RNTIs are radio identifiers, not subscriber identities; no IMSI is exported.
METRICS_FRESH = 30
GAUGES = ["sinrUe", "cqi", "ri", "mcsDl", "mcsUl", "blerDl", "blerUl", "goodputDl", "goodputUl", "rsrp", "ph", "pcmax",
          "nprbUl", "snrPucch", "snrPusch"]


def metrics_text():
    cut = time.time() - METRICS_FRESH
    with HISTORY.lock:
        last = {r: d[-1] for r, d in HISTORY.by_rnti.items() if d and d[-1]["t"] >= cut}
    with UU.lock:
        uu = dict(UU.counts)
    out = ["# HELP fct_gnb_mac_total Cumulative OAI gNB MAC counter per RNTI (dlR0..3 = DL HARQ rounds, dlErr, pucchDtx, cceDl, ulR0..3, ulErr, ulDtx, cceUl).",
           "# TYPE fct_gnb_mac_total counter"]
    for r, x in sorted(last.items()):
        for k in COUNTERS:
            if k != "oos" and x.get(k) is not None:
                out.append('fct_gnb_mac_total{rnti="%s",counter="%s"} %d' % (r, k, x[k]))
    out += ["# HELP fct_ue_radio Latest per-second radio value per RNTI (UE SINR dB, CQI, MCS, BLER 0-1, MAC goodput Mbit/s in simulated time, RSRP dBm, PH dB, ...).",
            "# TYPE fct_ue_radio gauge"]
    for r, x in sorted(last.items()):
        for k in GAUGES:
            if x.get(k) is not None:
                out.append('fct_ue_radio{rnti="%s",field="%s"} %s' % (r, k, repr(float(x[k]))))
    out += ["# HELP fct_ue_out_of_sync 1 when the gNB reports the RNTI out-of-sync.", "# TYPE fct_ue_out_of_sync gauge"]
    for r, x in sorted(last.items()):
        if x.get("oos") is not None:
            out.append('fct_ue_out_of_sync{rnti="%s"} %d' % (r, x["oos"]))
    out += ["# HELP fct_uu_events_total Uu procedure events seen in the gNB log since the dashboard started.",
            "# TYPE fct_uu_events_total counter"]
    for k, _ in UU_KINDS:
        out.append('fct_uu_events_total{msg="%s"} %d' % (k, uu.get(k, 0)))
    out += ["# HELP fct_ue_rntis Number of RNTIs with a sample in the last %d s." % METRICS_FRESH, "# TYPE fct_ue_rntis gauge",
            "fct_ue_rntis %d" % len(last), ""]
    return "\n".join(out)


STATE = State()
CONTROL = Control()


class Handler(BaseHTTPRequestHandler):
    server_version = "fct-dash/0.3"

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
            if not isinstance(body, dict):
                raise ValueError("body must be a JSON object")
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
            ok, msg = CONTROL.act(str(body.get("action", "")))
        except ValueError:
            return self.send(400, json.dumps({"ok": False, "msg": "Unknown action"}), "application/json")
        except Exception as e:
            return self.send(502, json.dumps({"ok": False, "msg": "Kubernetes refused: " + describe_error(e)}), "application/json")
        with STATE.lock:
            STATE.cached_at = 0  # show the change on the next poll
        return self.send(200 if ok else 409, json.dumps({"ok": ok, "msg": msg}), "application/json")

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
        if url.path == "/api/kpi":
            dom = (q.get("domain") or ["core"])[0]
            lo, hi = (60, 7 * 86400) if dom == "core" else (30, 7 * 86400) if dom == "ran" else (30, HISTORY_SECONDS)
            try:
                seconds = max(lo, min(hi, int((q.get("seconds") or ["900"])[0])))
            except ValueError:
                seconds = 900
            if dom not in ("core", "ran", "ue"):
                return self.send(400, "domain must be core, ran or ue", "text/plain")
            src = (q.get("source") or [""])[0]
            if src not in ("", "mem", "prom"):
                return self.send(400, "source must be mem or prom", "text/plain")
            res = ue_kpis(seconds) if dom == "ue" else (core_kpis if dom == "core" else ran_kpis)(seconds, src)
            return self.send(200, json.dumps(res), "application/json")
        if url.path == "/metrics":
            return self.send(200, metrics_text(), "text/plain; version=0.0.4; charset=utf-8")
        if url.path == "/healthz":
            return self.send(200, "ok", "text/plain")
        self.send(404, "Not found", "text/plain")


if __name__ == "__main__":
    print(f"fct-dash on :{PORT} (mock={MOCK}, radio mode={RADIO_MODE})", flush=True)
    if not MOCK:
        STATE.snapshot()
    threading.Thread(target=sampler, daemon=True).start()
    threading.Thread(target=uu_collector, daemon=True).start()
    threading.Thread(target=pm_collector, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
