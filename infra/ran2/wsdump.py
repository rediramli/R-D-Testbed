# Read the OCUDU gNB JSON metrics from the remote-control WebSocket (127.0.0.1:8001, pod loopback) and print one JSON
# line per report with the local wall time added ("wall"). Runs in the tools container of the ocudu-cell pod.
# Usage: python3 wsdump.py N   (N reports, at most 60 s unless MAXS=seconds is set)
import json, sys, time, websocket
n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
ws = websocket.create_connection("ws://127.0.0.1:8001", timeout=5)
ws.send(json.dumps({"cmd": "metrics_subscribe"}))
got, t0 = 0, time.time()
import os
maxs = float(os.environ.get("MAXS", "60"))
while got < n and time.time() - t0 < maxs:
    m = ws.recv()
    try: d = json.loads(m)
    except ValueError: continue
    if "cmd" in d: continue
    print(json.dumps({"wall": round(time.time(), 3), **d})); got += 1
