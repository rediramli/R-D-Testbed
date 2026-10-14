#!/usr/bin/env bash
# Experiment 0b on the bench: SINR to CQI/MCS curve. One UDP DL flow above the link rate runs the whole time while the
# UE's DL noise steps from -100 dB (reference) through -20 ... -2 dB and back to -100 dB. For every step: UE SINR, CQI,
# DL MCS, BLER and MAC goodput (median of the last SETTLE..STEP seconds). Answers two open questions:
#   - how many dB the UE SINR falls per dB of noise (Experiment 0 showed about 2, expected about 1);
#   - how far the reported CQI sits from the typical CQI at that SINR (about 2 below in K4).
# The noise is set through the UE telnet (127.0.0.1:9090) with the noise relay's own functions, because the relay only
# accepts the four preset names; the relay and the dashboard are not changed (the dashboard shows "custom" meanwhile).
# Client: temporary pod exp0b-iperf (alpine + iperf3, host network, bound to oaitun_ue1), server 10.45.0.1:5202 -R.
# Always ends with noise -100 dB, the dashboard preset Off and the pod deleted. rfsim only.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp00b-noise-sweep.sh
#   MODE=preview  preconditions and the step list; changes nothing
#   MODE=run      about 7.5 min; results in docs/experiments/data/bench-sweep-<UTC time>/
# Options: STEPS="-100 -20 -19 ... -2 -100" STEP=20 (s per step) SETTLE=8 (s skipped after a change) RATE=200M
set -u
MODE=${MODE:-preview}; STEP=${STEP:-20}; SETTLE=${SETTLE:-8}; RATE=${RATE:-200M}
STEPS=${STEPS:-"-100 $(seq -s ' ' -20 1 -2) -100"}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp0b-iperf
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
setnoise(){  # setnoise DB -> prints the value read back from the UE channel model (relay's telnet and parser)
  python3 - "$REPO/noise-relay.py" "$1" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("relay", sys.argv[1]); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
v = float(sys.argv[2])
assert -100.0 <= v <= 0.0, "noise out of range"
out = r.telnet("channelmod modify 0 noise_power_dB %g" % v, "channelmod show current")
print(r.parse_noise(out))
PYEOF
}
KEY=""; api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
                 -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }

pre(){
  echo "== Preconditions"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  $KC get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--rfsim' \
    && ok "UE runs with --rfsim" || bad "UE without --rfsim: STOP"
  r=$($KC get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running (replicas '$r'): press Stop"
  $KC get pod $POD >/dev/null 2>&1 && bad "pod $POD already exists ($KC delete pod $POD)" || ok "no leftover pod $POD"
  tiny "ss -Hltn '( sport = :5202 )'" 2>/dev/null | grep -q "10.45.0.1:5202" && ok "iperf3 server on 10.45.0.1:5202 (core)" \
    || bad "no iperf3 server on 10.45.0.1:5202"
  v=$(python3 - "$REPO/noise-relay.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("relay", sys.argv[1]); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
print(r.read_noise())
PYEOF
)
  [ "$v" = "-100.0" ] && ok "UE telnet reachable, channel model reads -100 dB" || bad "UE telnet / channel model: '$v'"
  n=$(echo $STEPS | wc -w); echo "  info  $n steps of $STEP s (~$(( (n * STEP + 40) / 60 )) min): $STEPS"
}

restore(){
  setnoise -100 >/dev/null 2>&1
  [ -n "$KEY" ] && api noise-off >/dev/null
  $KC delete pod $POD --wait=false >/dev/null 2>&1
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-sweep-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  trap 'restore' EXIT
  $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 1800' >/dev/null
  for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $POD -- test -f /tmp/ready 2>/dev/null && ok "client pod ready" || { bad "client pod not ready"; exit 1; }
  n=$(echo $STEPS | wc -w); T=$(( n * STEP + 15 ))
  echo "== Sweep: UDP $RATE for $T s, noise steps every $STEP s (do not use the dashboard controls until RESULT)"
  $KC exec $POD -- iperf3 -c 10.45.0.1 -p 5202 -R -u -b "$RATE" -t "$T" --bind-dev oaitun_ue1 --connect-timeout 3000 -J \
    > "$OUT/udp.json" 2>&1 &
  IP=$!
  sleep 8
  T0=$(date +%s.%N); echo "t_s,noise_set,noise_read" > "$OUT/steps.csv"
  for v in $STEPS; do
    ts=$(date +%s.%N); rb=$(setnoise "$v" 2>&1 | tail -1)
    t=$(awk -v a="$ts" -v b="$T0" 'BEGIN{printf "%.1f", a-b}')
    echo "$t,$v,$rb" >> "$OUT/steps.csv"; printf '  %6s s  noise %6s dB (read back %s)\n' "$t" "$v" "$rb"
    sleep "$(awk -v d="$STEP" -v a="$ts" -v b="$(date +%s.%N)" 'BEGIN{x = d-(b-a); printf "%.1f", (x > 0 ? x : 0)}')"
  done
  T1=$(date +%s.%N)
  setnoise -100 >/dev/null; api noise-off >/dev/null
  wait $IP 2>/dev/null
  dur=$(awk -v a="$T1" -v b="$T0" 'BEGIN{print int(a-b)+10}')
  curl -s -m 20 "$URL/api/history?seconds=$dur" > "$OUT/history.json"
  curl -s -m 20 "$URL/api/kpi?domain=ue&seconds=$dur" > "$OUT/ue-kpi.json"
  restore; trap - EXIT
  python3 - "$OUT" "$T0" "$T1" "$STEP" "$SETTLE" <<'PY' | tee "$OUT/summary.txt"
import csv, json, statistics as st, sys
out, t0, t1, STEP, SETTLE = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
h = [r for r in json.load(open(out + "/history.json"))["rows"] if t0 <= r["t"] <= t1]
steps = list(csv.DictReader(open(out + "/steps.csv")))
ues = [u["rnti"] for u in json.load(open(out + "/ue-kpi.json"))["ues"] if u["first"] <= t1 and u["last"] >= t0]
TYP = [-6.7, -4.7, -2.3, 0.2, 2.4, 4.3, 5.9, 8.1, 10.3, 11.7, 14.1, 16.3, 18.7, 21.0, 22.7]   # app.py TYPICAL_SINR_T1
typ_cqi = lambda s: sum(1 for x in TYP if s >= x)
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
def med(rows, k):
    v = [x[k] for x in rows if x.get(k) is not None]
    return st.median(v) if v else None
res = []
print("  info  noise dB | UE SINR  CQI (typical)  DL MCS  BLER     MAC goodput | samples  out-of-sync")
for i, s in enumerate(steps):
    a = t0 + float(s["t_s"]) + SETTLE; b = t0 + float(s["t_s"]) + STEP
    rows = [x for x in h if a <= x["t"] < b]
    m = {k: med(rows, k) for k in ("sinrUe", "cqi", "mcsDl", "blerDl", "goodputDl")}
    oos = sum(1 for x in rows if x.get("oos"))
    tc = typ_cqi(m["sinrUe"]) if m["sinrUe"] is not None else None
    res.append({"noise": float(s["noise_set"]), "read": s["noise_read"], "n": len(rows), "oos": oos, "typCqi": tc, **m})
    f = lambda x, d: "-" if x is None else ("%." + str(d) + "f") % x
    print("  info  %7.1f  | %5s dB  %3s (%2s)    %4s   %7s  %6s Mbit/s | %3d  %d" % (
        float(s["noise_set"]), f(m["sinrUe"], 1), f(m["cqi"], 0), f(tc, 0), f(m["mcsDl"], 0), f(m["blerDl"], 4),
        f(m["goodputDl"], 1), len(rows), oos))
with open(out + "/curve.csv", "w") as fh:
    w = csv.DictWriter(fh, fieldnames=["noise", "read", "sinrUe", "cqi", "typCqi", "mcsDl", "blerDl", "goodputDl", "n", "oos"])
    w.writeheader(); [w.writerow(x) for x in res]
for x in res:
    try:
        good = abs(float(x["read"]) - x["noise"]) < 0.01
    except ValueError:
        good = False
    if not good:
        r(False, "noise %g dB read back as '%s'" % (x["noise"], x["read"]))
r(all(x["n"] >= STEP - SETTLE - 4 for x in res), "every step has >= %d samples (min %d)" % (STEP - SETTLE - 4, min(x["n"] for x in res)))
r(len(ues) == 1, "one UE context throughout: %s" % ues)
oos = sum(x["oos"] for x in res)
print("  info  out-of-sync samples: %d%s" % (oos, "" if not oos else " at " + ", ".join("%g dB" % x["noise"] for x in res if x["oos"])))
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
# findings (not pass/fail): SINR slope vs noise below 30 dB SINR, CQI offset vs the typical table
pts = [(x["noise"], x["sinrUe"]) for x in res if x["noise"] > -50 and x["sinrUe"] is not None and x["sinrUe"] < 30]
if len(pts) >= 3:
    mx = sum(p[0] for p in pts) / len(pts); my = sum(p[1] for p in pts) / len(pts)
    slope = sum((p[0] - mx) * (p[1] - my) for p in pts) / sum((p[0] - mx) ** 2 for p in pts)
    print("FINDING: UE SINR falls %.2f dB per dB of added noise (fit over %d steps with SINR < 30 dB; 1.00 expected for AWGN)" % (-slope, len(pts)))
d = [x["cqi"] - x["typCqi"] for x in res if x["cqi"] is not None and x["typCqi"] is not None and x["noise"] > -50 and x["typCqi"] < 15]
if d:
    print("FINDING: reported CQI minus typical CQI at the same SINR: median %+.1f (range %+.0f to %+.0f, %d steps below CQI 15)"
          % (st.median(d), min(d), max(d), len(d)))
j = None
try:
    j = json.load(open(out + "/udp.json"))["end"]["sum"]
    print("  info  UDP over the sweep: %.1f Mbit/s received (wall clock), %.1f %% lost" % (j["bits_per_second"] / 1e6, j.get("lost_percent", 0)))
except Exception as e:
    print("  info  UDP summary not available: %s" % str(e)[:80])
PY
  rm -f "$OUT/history.json"
  [ "$(noise_db)" = "-100.0" ] && echo "  info  noise back at -100 dB" || echo "  WARNING  relay does not report -100 dB: $(noise_db)"
  echo "  info  saved in ${OUT#$REPO/}"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  pod $POD, one UDP $RATE DL flow, noise steps through the UE telnet, then noise -100, preset Off, pod deleted" ;;
run) run ;;
*) echo "MODE must be preview or run"; exit 1 ;;
esac
