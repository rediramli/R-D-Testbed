#!/usr/bin/env bash
# Checks that the Uu events of the latest UE attach come in the right order and
# line up in time with the first N2 message. Run on REDLAB after a UE start.
BASE=${BASE:-http://10.0.129.2:30880}
python3 - "$BASE" <<'PY'
import json, sys, urllib.request
from datetime import datetime, timezone
base = sys.argv[1]
uu = sorted(json.load(urllib.request.urlopen(base + "/api/uu?after=0"))["events"], key=lambda e: e["t"])
n2 = json.load(urllib.request.urlopen(base + "/api/flow?after=0"))["messages"]
order = ["SSB found", "SIB1 decoded", "Msg1", "Msg2", "Msg3", "Msg4:", "Msg4 acknowledged", "RRCSetupComplete"]
ssb = [e for e in uu if e["msg"].startswith("SSB found")]
if not ssb:
    sys.exit("FAIL: no 'SSB found' event yet; start the UE first")
t0 = ssb[-1]["t"]
last = [e for e in uu if e["t"] >= t0][:len(order)]   # the latest attach, in time order
ts = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime("%H:%M:%S.%f")[:-3]
ok = True
for i, want in enumerate(order):
    e = last[i] if i < len(last) else None
    good = bool(e) and e["msg"].startswith(want)
    ok &= good
    print(f"{'PASS' if good else 'FAIL'}  " + (f"{ts(e['t'])}  {e['proto']:8} {e['msg']}" if e else f"missing: {want}"))
rrc = next((e["t"] for e in last if e["msg"].startswith("RRCSetupComplete")), None)
msg1 = next((e["t"] for e in last if e["msg"].startswith("Msg1")), None)
ini = [m for m in n2 if rrc and m["msg"].startswith("InitialUEMessage") and m["t"] >= rrc - 1]
if ini:
    gap = (ini[0]["t"] - rrc) * 1000
    good = -5 <= gap <= 50
    ok &= good
    print(f"{'PASS' if good else 'FAIL'}  InitialUEMessage on N2 {gap:+.1f} ms after RRCSetupComplete")
    if msg1:
        print(f"INFO  Msg1 to RRCSetupComplete: {(rrc - msg1) * 1000:.1f} ms")
else:
    ok = False; print("FAIL  no InitialUEMessage on N2 after RRCSetupComplete")
print("RESULT:", "PASS" if ok else "FAIL")
PY
