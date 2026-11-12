#!/usr/bin/env bash
# Experiment 17, stage M2 on the OAI cell: replay a per-SIM SINR profile (from exp17-gwlog-profile.py or
# exp17-profile.py) as the UE's DL noise setting, step by step, and check that the cell follows it.
# Mapping by CQI, not by SINR value: the ship modem's SINR (median per STEP s, plus OFFSET dB) -> the CQI a typical
# receiver reports there (dashboard table) -> the bench noise_power_dB at which the OAI UE reports that CQI (measured
# curve: Experiment 0b and the M2 floor probe). Same CQI = same spectral efficiency, so the bench offers the rate the ship
# would get; the absolute SINR differs (the OAI UE reports 1-3 CQI lower than typical at the same SINR).
# Below the bench's lowest steady CQI (4, at noise -2 dB) the OAI UE reports CQI 0 and MCS is erratic (floor probe):
# those steps go to an "edge" zone, noise -2 .. 0 dB (UE still attached, 2-12 Mbit/s), and are not graded on MCS.
# Typical CQI 15 -> noise off (-100 dB).
# One UDP DL flow above the link rate runs the whole time (as Experiment 0b), so MCS and goodput show what the cell
# offers at each step. The sequence runs REPS times with noise off between repetitions.
# Gate (PASS): noise read back at every step; one UE context; in >= 90 % of the graded (non-edge) steps the DL MCS is within the
# curve's MCS change over +-1 dB of noise of the expected MCS; across repetitions the same holds for the MCS spread.
# The profile and every output stay OUTSIDE this public repo (client data): OUT must be outside it.
# Always ends with noise -100 dB, the dashboard preset Off and the pod deleted. rfsim only.
# Run ON REDLAB from the repo root as the login user (no sudo):
#   PROFILE=<profile.csv> OUT=<dir outside the repo> MODE=preview bash infra/exp/exp17-replay.sh
#   MODE=preview  preconditions and the replay plan (plan.csv in OUT); changes nothing on the bench
#   MODE=run      REPS x (LEN/STEP) steps of STEP s
# Options: START=0 (s into the profile) LEN=600 (s of profile) STEP=10 SETTLE=4 REPS=3 OFFSET=0 COL=sinr_db RATE=200M
#          CURVES="<curve.csv> ..." (default: the Experiment 0b curve plus the M2 floor probe if present)
set -u
MODE=${MODE:-preview}; START=${START:-0}; LEN=${LEN:-600}; STEP=${STEP:-10}; SETTLE=${SETTLE:-4}; REPS=${REPS:-3}
OFFSET=${OFFSET:-0}; COL=${COL:-sinr_db}; RATE=${RATE:-200M}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
CURVES=${CURVES:-$(ls "$REPO"/docs/experiments/data/bench-sweep-20261014T064929Z/curve.csv \
                      "$REPO"/docs/experiments/data/bench-floor-20261112T062657Z/curve.csv 2>/dev/null | tr '\n' ' ')}
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp17-iperf
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

[ -n "${PROFILE:-}" ] && [ -f "$PROFILE" ] || { echo "PROFILE=<profile.csv> is required"; exit 1; }
[ -n "${OUT:-}" ] || { echo "OUT=<folder outside the repo> is required"; exit 1; }
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
case "$OUT/" in "$REPO"/*) echo "refusing to write replay results inside the repo: choose OUT outside it"; exit 1 ;; esac

plan(){  # writes $OUT/plan.csv: step,t_s,target_sinr,noise,exp_mcs,tol,clipped
  python3 -I - "$PROFILE" "$OUT/plan.csv" "$START" "$LEN" "$STEP" "$OFFSET" "$COL" $CURVES <<'PY'
import csv, statistics as st, sys
prof, outp, START, LEN, STEP, OFF, COL = sys.argv[1], sys.argv[2], *map(int, sys.argv[3:6]), float(sys.argv[6]), sys.argv[7]
TYP = [-6.7, -4.7, -2.3, 0.2, 2.4, 4.3, 5.9, 8.1, 10.3, 11.7, 14.1, 16.3, 18.7, 21.0, 22.7]   # app.py TYPICAL_SINR_T1
def ship_cqi(x):                                # fractional CQI a typical receiver reports at SINR x
    if x < TYP[0]: return 0.0
    i = sum(1 for t in TYP if x >= t)
    return float(i) if i == 15 else i + (x - TYP[i - 1]) / (TYP[i] - TYP[i - 1])
pts = {}
for c in sys.argv[8:]:
    for r in csv.DictReader(open(c)):
        n = float(r["noise"])
        if -50 < n <= -2 and r["cqi"] and r["mcsDl"]:   # below -2 dB the reported CQI is 0 and MCS erratic (M2 floor probe)
            pts[n] = (float(r["cqi"]), float(r["mcsDl"]))
pts = sorted(pts.items())                       # by noise, rising: CQI falls
if len(pts) < 3:
    sys.exit("no usable curve points")
def interp(x, xs, ys):
    if x <= xs[0]: return ys[0]
    if x >= xs[-1]: return ys[-1]
    for i in range(1, len(xs)):
        if x <= xs[i]:
            return ys[i-1] + (ys[i] - ys[i-1]) * (x - xs[i-1]) / (xs[i] - xs[i-1])
N = [p[0] for p in pts]; M = [p[1][1] for p in pts]
byc = {}
for n, (c, _) in pts:
    byc.setdefault(int(c), []).append(n)
C = sorted(byc); CN = [st.median(byc[c]) for c in C]  # bench noise that gives each reported CQI
cmin = C[0]
v = [r[COL] for r in csv.DictReader(open(prof))][START:START + LEN]
rows = []
for k in range(0, len(v) - STEP + 1, STEP):
    x = [float(a) for a in v[k:k + STEP] if a not in ("", None)]
    if not x:
        continue
    tgt = st.median(x) + OFF
    c = ship_cqi(tgt)
    edge = c < cmin
    if c >= 15:
        noise = -100.0
    elif edge:                                   # below the bench's lowest steady CQI: noise -2 .. 0 dB, ungraded
        noise = round((N[-1] + (0 - N[-1]) * (cmin - c) / cmin) * 2) / 2
    else:
        noise = round(interp(c, C, CN) * 2) / 2  # 0.5 dB steps
    exp = interp(max(noise, N[0]), N, M) if noise > -100 else M[0]
    tol = max(2.0, abs(interp(min(noise + 1, N[-1]), N, M) - exp), abs(interp(max(noise - 1, N[0]), N, M) - exp)) \
          if noise > -100 else 2.0
    rows.append((len(rows), k, round(tgt, 1), round(c, 1), noise, round(exp, 1), round(tol, 1), int(edge)))
with open(outp, "w") as fh:
    fh.write("step,t_s,target_sinr,ship_cqi,noise,exp_mcs,tol,clipped\n")
    fh.writelines(",".join(map(str, r)) + "\n" for r in rows)
c = sum(r[7] for r in rows)
print("  info  %d steps of %d s from %s s; bench CQI %d..%d graded; %d steps (%d %%) in the edge zone below CQI %d (ungraded)"
      % (len(rows), STEP, START, cmin, C[-1], c, 100 * c // max(1, len(rows)), cmin))
print("  info  noise range used: %s .. %s dB" % (min(r[4] for r in rows), max(r[4] for r in rows)))
PY
}

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
  echo "  info  curves: $CURVES"
  plan || bad "replay plan"
  n=$(($(wc -l < "$OUT/plan.csv") - 1)); echo "  info  $REPS repetitions x $n steps x $STEP s (~$(( (REPS * (n * STEP + 20) + 40) / 60 )) min)"
}

restore(){
  setnoise -100 >/dev/null 2>&1
  [ -n "$KEY" ] && api noise-off >/dev/null
  $KC delete pod $POD --wait=false >/dev/null 2>&1
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  trap 'restore' EXIT
  $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 14400' >/dev/null
  for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $POD -- test -f /tmp/ready 2>/dev/null && ok "client pod ready" || { bad "client pod not ready"; exit 1; }
  NOISES=$(python3 -I -c 'import csv,sys; print(" ".join(r["noise"] for r in csv.DictReader(open(sys.argv[1]))))' "$OUT/plan.csv"); n=$(echo $NOISES | wc -w)
  T=$(( REPS * (n * STEP + 25) + 15 ))
  echo "== Replay: UDP $RATE for $T s (do not use the dashboard controls until RESULT)"
  $KC exec $POD -- iperf3 -c 10.45.0.1 -p 5202 -R -u -b "$RATE" -t "$T" --bind-dev oaitun_ue1 --connect-timeout 3000 -J \
    > "$OUT/udp.json" 2>&1 &
  IP=$!
  sleep 8
  T0=$(date +%s.%N); echo "rep,step,t_s,noise_set,noise_read" > "$OUT/steps.csv"
  for rep in $(seq 1 "$REPS"); do
    s=0
    for v in $NOISES; do
      ts=$(date +%s.%N); rb=$(setnoise "$v" 2>&1 | tail -1)
      t=$(awk -v a="$ts" -v b="$T0" 'BEGIN{printf "%.1f", a-b}')
      echo "$rep,$s,$t,$v,$rb" >> "$OUT/steps.csv"
      case "$rb" in -[0-9]*|0|0.0) ;; *) bad "noise $v not applied: $rb"; exit 1 ;; esac
      [ $((s % 10)) = 0 ] && printf '  rep %d  step %3d/%d  %7s s  noise %6s dB\n' "$rep" "$s" "$n" "$t" "$rb"
      s=$((s + 1))
      sleep "$(awk -v d="$STEP" -v a="$ts" -v b="$(date +%s.%N)" 'BEGIN{x = d-(b-a); printf "%.1f", (x > 0 ? x : 0)}')"
    done
    setnoise -100 >/dev/null; sleep 20                      # noise off between repetitions
    # the dashboard keeps 900 s of 1 s history (HISTORY_SECONDS): fetch it after every repetition
    curl -s -m 60 "$URL/api/history?seconds=900" > "$OUT/history-rep$rep.json"
  done
  T1=$(date +%s.%N)
  api noise-off >/dev/null
  wait $IP 2>/dev/null
  dur=$(awk -v a="$T1" -v b="$T0" 'BEGIN{print int(a-b)+10}')
  curl -s -m 60 "$URL/api/kpi?domain=ue&seconds=$dur" > "$OUT/ue-kpi.json"
  restore; trap - EXIT
  python3 -I - "$OUT" "$T0" "$T1" "$STEP" "$SETTLE" <<'PY' | tee "$OUT/summary.txt"
import csv, json, statistics as st, sys, collections
out, t0, t1, STEP, SETTLE = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
import glob
h = sorted({r["t"]: r for f in glob.glob(out + "/history-rep*.json") for r in json.load(open(f))["rows"]
            if t0 <= r["t"] <= t1}.values(), key=lambda r: r["t"])
plan = {int(r["step"]): r for r in csv.DictReader(open(out + "/plan.csv"))}
steps = list(csv.DictReader(open(out + "/steps.csv")))
ues = [u["rnti"] for u in json.load(open(out + "/ue-kpi.json"))["ues"] if u["first"] <= t1 and u["last"] >= t0]
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
def med(rows, k):
    v = [x[k] for x in rows if x.get(k) is not None]
    return st.median(v) if v else None
res = []
for s in steps:
    a = t0 + float(s["t_s"]) + SETTLE; b = t0 + float(s["t_s"]) + STEP
    rows = [x for x in h if a <= x["t"] < b]
    p = plan[int(s["step"])]
    res.append({"rep": int(s["rep"]), "step": int(s["step"]), "target": float(p["target_sinr"]), "noise": float(s["noise_set"]),
                "read": s["noise_read"], "exp": float(p["exp_mcs"]), "tol": float(p["tol"]), "clipped": int(p["clipped"]), "shipCqi": float(p["ship_cqi"]),
                "n": len(rows), "oos": sum(1 for x in rows if x.get("oos")),
                **{k: med(rows, k) for k in ("sinrUe", "cqi", "mcsDl", "blerDl", "goodputDl")}})
with open(out + "/replay.csv", "w") as fh:
    w = csv.DictWriter(fh, fieldnames=list(res[0])); w.writeheader(); [w.writerow(x) for x in res]
bad_rb = [x for x in res if not (lambda v: v is not None and abs(v - x["noise"]) < 0.01)(
    (lambda s: float(s) if s.replace(".", "", 1).lstrip("-").isdigit() else None)(x["read"]))]
r(not bad_rb, "noise read back at every step (%d wrong)" % len(bad_rb))
r(len(ues) == 1, "one UE context throughout: %s" % ues)
r(all(x["n"] >= 1 for x in res), "every step has samples (min %d)" % min(x["n"] for x in res))
u = [x for x in res if not x["clipped"] and x["mcsDl"] is not None]
within = sum(abs(x["mcsDl"] - x["exp"]) <= x["tol"] for x in u)
r(u and within >= 0.9 * len(u), "DL MCS follows the curve in %d of %d graded steps (>= 90 %% needed)" % (within, len(u)))
by = collections.defaultdict(list)
for x in u:
    by[x["step"]].append(x)
rep_ok = sum(max(y["mcsDl"] for y in v) - min(y["mcsDl"] for y in v) <= v[0]["tol"] for v in by.values() if len(v) > 1)
nrep = sum(1 for v in by.values() if len(v) > 1)
r(nrep == 0 or rep_ok >= 0.9 * nrep, "MCS repeats across repetitions in %d of %d steps (>= 90 %% needed)" % (rep_ok, nrep))
c = [x for x in res if x["clipped"]]
oos = sum(x["oos"] for x in res)
print("  info  edge-zone steps: %d of %d (ungraded, ship CQI below the bench floor); out-of-sync samples: %d" % (len(c), len(res), oos))
for rep in sorted({x["rep"] for x in res}):
    g = [x["goodputDl"] for x in res if x["rep"] == rep and x["goodputDl"] is not None]
    s = [x["sinrUe"] for x in res if x["rep"] == rep and x["sinrUe"] is not None]
    if g and s:
        print("  info  rep %d: UE SINR median %.1f dB, DL goodput median %.1f Mbit/s, min %.1f" % (rep, st.median(s), st.median(g), min(g)))
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
PY
  rm -f "$OUT"/history-rep*.json
  [ "$(noise_db)" = "-100.0" ] && echo "  info  noise back at -100 dB" || echo "  WARNING  relay does not report -100 dB: $(noise_db)"
  echo "  info  saved in $OUT"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  pod $POD, one UDP $RATE DL flow, $REPS replays of plan.csv through the UE telnet, then noise -100, preset Off, pod deleted" ;;
run) run ;;
*) echo "MODE must be preview or run"; exit 1 ;;
esac
