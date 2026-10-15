#!/usr/bin/env python3
"""RAN profile relay for the FCT dashboard (Experiments page, stage E1).

Runs on the RAN host (REDLAB) with host networking. It is the only way the dashboard can reconfigure the gNB and the
UE, and it can do exactly one thing: switch the carrier to one of a few fixed, tested profiles (Experiment 1:
24 / 51 / 106 / 273 PRB, all n78, 30 kHz, TDD, rfsim). Every profile is built from the repository baseline
(infra/ran/gnb.yaml and infra/ran/ran.yaml, mounted read-only), never from the running configuration.

  GET  /healthz    -> "ok"
  GET  /profile    -> {"current": ..., "state": ..., "steps": [...], "profiles": {...}, ...}   (no token needed)
  POST /profile    -> body {"profile": "bw-51"}, header X-Relay-Token; 202 and the switch runs in the background
                      (409 while another switch runs, or when the gNB or UE is stopped)

A switch: build gnb.yaml and the UE command line, patch ConfigMap oai-gnb-config and Deployment oai-gnb, wait for the
gNB, restart the UE with the new command line, wait until the UE tunnel (oaitun_ue1) answers a ping to the core.
If any step fails after the configuration was changed, the relay switches back to the baseline (bw-106) on its own.
Kubernetes access: a ServiceAccount allowed only get/patch on oai-gnb-config, oai-gnb and oai-nr-ue (profile-ran.yaml).
The token is compared in constant time. --rfsim is checked on both command lines before anything is applied.
SIM data is never read: the UE's Secret stays referenced by name only.

Self-test without Kubernetes:  python3 ran-profile-relay.py --selftest infra/ran/gnb.yaml infra/ran/ran.yaml
"""
import hashlib
import hmac
import json
import os
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("RELAY_BIND", "10.42.0.1")
PORT = int(os.environ.get("RELAY_PORT", "8093"))
TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/etc/profile-relay/token")
BASE_DIR = os.environ.get("RELAY_BASE_DIR", "/base")
NS = "default"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"
MAX_BODY = 256
BASELINE = "bw-106"
UE_BASE = "-r 106 --numerology 1 -C 3319680000"
# Carrier parameters from OAI's own configurations at tag 2026.w40, tested in Experiment 1 (exp01-bandwidth.sh).
# pointA, SSB ARFCN, CORESET0 index, BWP RIV, UE carrier centre (Hz), UE --ssb, 3/4 sampling (-E), UDP test rate.
PROFILES = {
    "bw-24":  dict(prb=24,  mhz=10,  pointA=640032, ssb=640320, coreset0=2,  riv=6325,  centre=3604800000, ssbOff=24,   e34=False, udp="150M"),
    "bw-51":  dict(prb=51,  mhz=20,  pointA=639996, ssb=640704, coreset0=12, riv=13750, centre=3609120000, ssbOff=234,  e34=True,  udp="250M"),
    "bw-106": dict(prb=106, mhz=40,  pointA=620040, ssb=621312, coreset0=11, riv=28875, centre=3319680000, ssbOff=516,  e34=True,  udp="200M"),
    "bw-273": dict(prb=273, mhz=100, pointA=626772, ssb=630048, coreset0=12, riv=1099,  centre=3450720000, ssbOff=1518, e34=True,  udp="600M"),
}
KEYS = ("absoluteFrequencySSB", "dl_absoluteFrequencyPointA", "dl_carrierBandwidth", "ul_carrierBandwidth",
        "initialDLBWPlocationAndBandwidth", "initialULBWPlocationAndBandwidth", "initialDLBWPcontrolResourceSetZero")
STEPS = ("build", "gnb-config", "gnb-restart", "ue-restart", "ue-register")
TIMEOUT = {"gnb-restart": 180, "ue-restart": 180, "ue-register": 150}

LOCK = threading.Lock()                       # one switch at a time
ST = {"state": "idle", "target": None, "steps": [], "error": None, "since": time.time(), "log": []}


# ---- building the configuration (pure functions, used by the self-test too) -----------------------------------------
def base_files(gnb_path, ran_path):
    gnb = open(gnb_path).read()
    ran = open(ran_path).read()
    m = re.search(r"name: USE_ADDITIONAL_OPTIONS\s*\n\s*value: \"([^\"]+)\"", ran)
    if not m:
        raise RuntimeError("gNB USE_ADDITIONAL_OPTIONS not found in ran.yaml")
    gnb_opts = m.group(1)
    lines = ran.split("\n")
    i = next((k for k, l in enumerate(lines) if l.strip() == "- name: nr-ue"), None)
    if i is None:
        raise RuntimeError("container nr-ue not found in ran.yaml")
    j = next(k for k in range(i, len(lines)) if lines[k].strip() == "args:")
    if lines[j + 1].strip() != "- |":
        raise RuntimeError("UE args are not a literal block")
    body = []
    for l in lines[j + 2:]:
        if l.strip() and len(l) - len(l.lstrip()) < 10:
            break
        body.append(l[10:] if len(l) >= 10 else "")
    ue_args = "\n".join(body).rstrip("\n") + "\n"
    return gnb, gnb_opts, ue_args


def build(name, gnb, gnb_opts, ue_args):
    """Return (gnb.yaml, gNB options, UE args) for a profile, from the baseline texts."""
    p = PROFILES[name]
    if name != BASELINE:
        vals = (p["ssb"], p["pointA"], p["prb"], p["prb"], p["riv"], p["riv"], p["coreset0"])
        for key, val in zip(KEYS, vals):
            gnb, n = re.subn(r"(?m)^(\s*%s:\s*)\S+\s*$" % key, r"\g<1>%s" % val, gnb)
            if n != 1:
                raise RuntimeError("%s found %d times in gnb.yaml" % (key, n))
        if ue_args.count(UE_BASE) != 1:
            raise RuntimeError("UE carrier options not found once in the baseline UE command")
        ue_args = ue_args.replace(UE_BASE, "-r %d --numerology 1 -C %d --ssb %d" % (p["prb"], p["centre"], p["ssbOff"]))
    if not p["e34"]:
        # OAI 2026.w40 asserts on 11.52 MHz (24 PRB with 3/4 sampling) in get_prach_ru_params(); gNB and UE must match.
        if gnb_opts.count("-E --rfsim") != 1 or ue_args.count("-E --rfsim") != 1:
            raise RuntimeError("-E not found once on both command lines")
        gnb_opts = gnb_opts.replace("-E --rfsim", "--rfsim")
        ue_args = ue_args.replace("-E --rfsim", "--rfsim")
    if "--rfsim" not in gnb_opts or "--rfsim" not in ue_args:
        raise RuntimeError("--rfsim missing: refusing")
    return gnb, gnb_opts, ue_args


def chash(text):
    return hashlib.sha256(text.encode()).hexdigest()[:12]


# ---- Kubernetes API ------------------------------------------------------------------------------------------------
def k8s(method, path, body=None, ctype="application/merge-patch+json", timeout=10):
    host = os.environ["KUBERNETES_SERVICE_HOST"]
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    token = open(SA + "/token").read().strip()
    req = urllib.request.Request("https://%s:%s%s" % (host, port, path), method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + token, "Content-Type": ctype})
    ctx = ssl.create_default_context(cafile=SA + "/ca.crt")
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


DEP = "/apis/apps/v1/namespaces/%s/deployments/" % NS
CM = "/api/v1/namespaces/%s/configmaps/oai-gnb-config" % NS
SMP = "application/strategic-merge-patch+json"


def rollout_done(name, since_gen):
    d = k8s("GET", DEP + name)
    s, sp = d.get("status", {}), d.get("spec", {})
    want = sp.get("replicas", 1)
    return (d["metadata"]["generation"] > since_gen and s.get("observedGeneration", 0) >= d["metadata"]["generation"]
            and s.get("updatedReplicas", 0) == want and s.get("availableReplicas", 0) == want
            and s.get("replicas", 0) == want)


def tunnel_up():
    try:
        a = subprocess.run(["ip", "-4", "-o", "addr", "show", "oaitun_ue1"], capture_output=True, text=True, timeout=5).stdout
        if "10.45." not in a:
            return False
        return subprocess.run(["ping", "-I", "oaitun_ue1", "-c", "1", "-W", "2", "10.45.0.1"],
                              capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def wait(what, fn, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if fn():
                return True
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError("%s: not done within %d s" % (what, timeout))


def note(msg):
    line = time.strftime("%FT%TZ", time.gmtime()) + " " + msg
    print(line, flush=True)
    ST["log"] = (ST["log"] + [line])[-30:]


def step(name):
    now = time.time()
    if ST["steps"] and ST["steps"][-1]["end"] is None:
        ST["steps"][-1]["end"] = now
    ST["steps"].append({"step": name, "start": now, "end": None})


def apply_profile(name, base):
    gnb, gnb_opts, ue_args = build(name, *base)
    step("gnb-config")
    g0 = k8s("GET", DEP + "oai-gnb")["metadata"]["generation"]
    k8s("PATCH", CM, {"data": {"gnb.yaml": gnb}})
    k8s("PATCH", DEP + "oai-gnb", {"spec": {"template": {
        "metadata": {"annotations": {"fct/config-hash": chash(gnb), "fct/profile": name}},
        "spec": {"containers": [{"name": "gnb", "env": [{"name": "USE_ADDITIONAL_OPTIONS", "value": gnb_opts}]}]}}}}, SMP)
    step("gnb-restart")
    wait("gNB restart", lambda: rollout_done("oai-gnb", g0), TIMEOUT["gnb-restart"])
    time.sleep(10)                              # let the gNB open its rfsim server before the UE connects
    step("ue-restart")
    u0 = k8s("GET", DEP + "oai-nr-ue")["metadata"]["generation"]
    k8s("PATCH", DEP + "oai-nr-ue", {"spec": {"template": {
        "metadata": {"annotations": {"fct/profile": name, "fct/switched-at": str(int(time.time()))}},
        "spec": {"containers": [{"name": "nr-ue", "args": [ue_args]}]}}}}, SMP)
    wait("UE restart", lambda: rollout_done("oai-nr-ue", u0), TIMEOUT["ue-restart"])
    step("ue-register")
    wait("UE registration (tunnel and ping to 10.45.0.1)", tunnel_up, TIMEOUT["ue-register"])


def worker(name, base):
    try:
        note("SWITCH to %s" % name)
        step("build")
        build(name, *base)                      # fails early, before anything changes
        apply_profile(name, base)
        ST["steps"][-1]["end"] = time.time()
        ST.update(state="ok", error=None, since=time.time())
        note("DONE %s" % name)
    except Exception as e:
        err = str(e)[:300]
        note("FAILED %s: %s" % (name, err))
        if name != BASELINE and len(ST["steps"]) > 1:   # something was changed: go back to the baseline
            ST.update(state="rolling-back", error=err)
            try:
                ST["steps"] = []
                apply_profile(BASELINE, base)
                ST["steps"][-1]["end"] = time.time()
                ST.update(state="rolled-back", error=err, since=time.time())
                note("ROLLED BACK to %s" % BASELINE)
            except Exception as e2:
                ST.update(state="failed", error="%s; rollback failed: %s (run: sudo MODE=apply bash infra/ran/ran.sh)" % (err, str(e2)[:200]))
                note("ROLLBACK FAILED: %s" % e2)
        else:
            ST.update(state="failed", error=err, since=time.time())
    finally:
        LOCK.release()


def current(base):
    """Which profile is running: the live ConfigMap and UE command compared with what each profile would build."""
    try:
        live_gnb = k8s("GET", CM)["data"]["gnb.yaml"]
        ue = k8s("GET", DEP + "oai-nr-ue")
        live_args = ue["spec"]["template"]["spec"]["containers"][0].get("args", [""])[0]
        reps = {n: k8s("GET", DEP + n)["spec"].get("replicas", 0) for n in ("oai-gnb", "oai-nr-ue")}
    except Exception as e:
        return {"current": None, "apiError": "Kubernetes API: %s" % e}
    name = "custom"
    for n in PROFILES:
        g, _, a = build(n, *base)
        if g == live_gnb and a.strip() == live_args.strip():
            name = n
    return {"current": name, "replicas": reps}


def token_ok(given):
    try:
        want = open(TOKEN_FILE).read().strip()
    except OSError:
        return False
    return bool(given) and bool(want) and hmac.compare_digest(given.encode(), want.encode())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, "ok")
        if self.path != "/profile":
            return self.send(404, {"error": "not found"})
        out = {"state": ST["state"], "target": ST["target"], "error": ST["error"], "steps": ST["steps"],
               "stepNames": STEPS, "since": ST["since"], "log": ST["log"][-8:], "baseline": BASELINE,
               "profiles": {k: {kk: v[kk] for kk in ("prb", "mhz", "pointA", "ssb", "centre", "e34", "udp")} for k, v in PROFILES.items()}}
        if ST["state"] in ("switching", "rolling-back"):
            out["current"] = None
        else:
            out.update(current(BASE))
        return self.send(200, out)

    def do_POST(self):
        if self.path != "/profile":
            return self.send(404, {"error": "not found"})
        if not token_ok(self.headers.get("X-Relay-Token", "")):
            note("REFUSED bad token from %s" % self.client_address[0])
            return self.send(401, {"error": "bad token"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            return self.send(400, {"error": "body too large or invalid length"})
        try:
            name = json.loads(self.rfile.read(n) or b"{}").get("profile")
        except (ValueError, AttributeError):
            return self.send(400, {"error": "body must be JSON {\"profile\": ...}"})
        if not isinstance(name, str) or name not in PROFILES:
            return self.send(400, {"error": "unknown profile", "allowed": sorted(PROFILES)})
        if not LOCK.acquire(blocking=False):
            return self.send(409, {"error": "a switch is already running", "state": ST["state"]})
        try:
            reps = {d: k8s("GET", DEP + d)["spec"].get("replicas", 0) for d in ("oai-gnb", "oai-nr-ue")}
        except Exception as e:
            LOCK.release()
            return self.send(503, {"error": "Kubernetes API: %s" % e})
        if reps != {"oai-gnb": 1, "oai-nr-ue": 1}:
            LOCK.release()
            return self.send(409, {"error": "start the gNB and the UE first", "replicas": reps})
        ST.update(state="switching", target=name, steps=[], error=None, since=time.time())
        threading.Thread(target=worker, args=(name, BASE), daemon=True).start()
        return self.send(202, {"accepted": name})


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)


def selftest(gnb_path, ran_path):
    base = base_files(gnb_path, ran_path)
    print("baseline gNB options:", base[1])
    print("baseline UE carrier options found:", base[2].count(UE_BASE) == 1, "| --rfsim:", "--rfsim" in base[2])
    fail = 0
    for n in PROFILES:
        g, o, a = build(n, *base)
        dg = sum(1 for x, y in zip(base[0].split("\n"), g.split("\n")) if x != y)
        e = "-E" in o.split()
        ok = (dg == (0 if n == BASELINE else 7)) and ("-r %d " % PROFILES[n]["prb"] in a) and (e == PROFILES[n]["e34"]) \
            and ("-E --rfsim" in a) == PROFILES[n]["e34"] and "--rfsim" in o and "--rfsim" in a
        fail += not ok
        print("%s %-7s gnb.yaml lines changed %d, gNB -E %s, UE: %s, hash %s" % ("PASS" if ok else "FAIL", n, dg, e,
              re.search(r"-r \d+ --numerology 1 -C \d+( --ssb \d+)?", a).group(0), chash(g)))
    print("SELFTEST:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
    return fail


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--selftest":
        sys.exit(1 if selftest(sys.argv[2], sys.argv[3]) else 0)
    BASE = base_files(BASE_DIR + "/gnb.yaml", BASE_DIR + "/ran.yaml")
    selftest(BASE_DIR + "/gnb.yaml", BASE_DIR + "/ran.yaml")
    print("profile relay on %s:%d, profiles %s" % (BIND, PORT, ", ".join(PROFILES)), flush=True)
    Server((BIND, PORT), Handler).serve_forever()
