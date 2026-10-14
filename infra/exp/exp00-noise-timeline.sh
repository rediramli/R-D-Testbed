#!/usr/bin/env bash
# Experiment 0 on the bench: switch the DL channel presets on a running DL speed test and record how UE SINR, CQI, MCS,
# BLER and goodput follow, with the time of every switch. Same schedule and CSV format as the first run of Experiment 0 on the
# old lab (exp-noise-timeline.sh), so the two can be compared and plotted with plot-noise-timeline.py.
# The switches go through the dashboard API (the same path as the buttons); samples come from the dashboard's
# 1 s history. rfsim only; nothing is installed or changed besides the noise preset and the speed test.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp00-noise-timeline.sh
#   MODE=preview  dashboard, relay, UE and noise off; changes nothing
#   MODE=run      the timeline (about 3.5 min) into docs/experiments/data/bench-timeline-<UTC time>/, then the phase checks
# Do not use the dashboard controls while it runs. Options: SCHEDULE="off:40 clean:40 moderate:40 poor:40 off:40" SKIP=10
set -u
MODE=${MODE:-preview}; SKIP=${SKIP:-10}
SCHEDULE=${SCHEDULE:-off:40 clean:40 moderate:40 poor:40 off:40}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
KEY=""; api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
                 -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }

pre(){
  echo "== Preconditions"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  k3s kubectl get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--rfsim' \
    && ok "UE runs with --rfsim" || bad "UE without --rfsim: STOP"
  n=$(curl -s -m 8 "$URL/api/history?seconds=30" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))' 2>/dev/null)
  [ "${n:-0}" -ge 10 ] && ok "dashboard history: $n samples in the last 30 s" || bad "dashboard history has '${n:-no}' samples"
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-timeline-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  trap 'api noise-off >/dev/null; api speed-stop >/dev/null' EXIT
  echo "== Timeline: $SCHEDULE (do not use the dashboard controls until RESULT)"
  c=$(api speed-dl); [ "$c" = 200 ] || { bad "dashboard refused speed-dl (HTTP $c)"; exit 1; }
  sleep 15
  T0=$(date +%s.%N); echo "t0_epoch,$T0" > "$OUT/t0.txt"
  echo "t_s,preset,noise_dB,http,apply_s" > "$OUT/events.csv"
  for ph in $SCHEDULE; do
    p=${ph%%:*}; d=${ph##*:}
    ts=$(date +%s.%N); c=$(api "noise-$p"); te=$(date +%s.%N)
    awk -v a="$ts" -v b="$T0" -v e="$te" -v p="$p" -v n="$(noise_db)" -v c="$c" \
      'BEGIN{printf "%.1f,%s,%s,%s,%.1f\n", a-b, p, n, c, e-a}' | tee -a "$OUT/events.csv"
    sleep "$(awk -v d="$d" -v a="$ts" -v b="$(date +%s.%N)" 'BEGIN{x = d-(b-a); printf "%.1f", (x > 0 ? x : 0)}')"
  done
  T1=$(date +%s.%N)
  api noise-off >/dev/null; api speed-stop >/dev/null; trap - EXIT
  # 1 s history of the RNTI that carried the test, and the RNTIs seen during the timeline
  dur=$(awk -v a="$T1" -v b="$T0" 'BEGIN{print int(a-b)+5}')
  curl -s -m 20 "$URL/api/history?seconds=$((dur + 5))" > "$OUT/history.json"
  curl -s -m 20 "$URL/api/kpi?domain=ue&seconds=$dur" > "$OUT/ue-kpi.json"
  python3 - "$OUT" "$T0" "$T1" <<'PY'
import csv, json, sys
out, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
h = json.load(open(out + "/history.json"))
ev = list(csv.DictReader(open(out + "/events.csv")))
ues = [u["rnti"] for u in json.load(open(out + "/ue-kpi.json"))["ues"] if u["first"] <= t1 and u["last"] >= t0]
def preset(t):
    p = ev[0]["preset"]
    for e in ev:
        if t >= float(e["t_s"]):
            p = e["preset"]
    return p
f = lambda v, n: "" if v is None else ("%." + str(n) + "f") % v
with open(out + "/timeline.csv", "w") as fh:
    fh.write("t_s,preset,rntis,sync,cqi,mcs_dl,bler_dl,goodput_dl,ue_sinr_dB\n")
    for r in h["rows"]:
        if not t0 <= r["t"] <= t1:
            continue
        t = r["t"] - t0
        fh.write(",".join([f(t, 1), preset(t), " ".join(ues), "out-of-sync" if r.get("oos") else "in-sync",
                           f(r.get("cqi"), 0), f(r.get("mcsDl"), 0), f(r.get("blerDl"), 5), f(r.get("goodputDl"), 2),
                           f(r.get("sinrUe"), 1)]) + "\n")
print("  info  rows %d, RNTI(s) during the timeline: %s" % (sum(1 for _ in open(out + "/timeline.csv")) - 1, " ".join(ues)))
PY
  rm -f "$OUT/history.json"
  echo "== Check each phase (samples after the first ${SKIP} s): MCS range, one UE context, in-sync"
  python3 - "$OUT/timeline.csv" "$OUT/events.csv" "$SKIP" <<'PY' | tee "$OUT/summary.txt"
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1]))); ev = list(csv.DictReader(open(sys.argv[2]))); skip = float(sys.argv[3])
want = {"off": (26, 28), "clean": (23, 28), "moderate": (12, 18), "poor": (3, 9)}   # ranges of the first run (old lab servers)
fail = 0
for e in ev:
    if e["http"] != "200": print(f"  FAIL  switch to {e['preset']} at {e['t_s']} s: HTTP {e['http']}"); fail += 1
print("  info  phase     from    noise  | UE SINR  CQI  DL MCS  DL BLER   DL goodput | samples")
for i, e in enumerate(ev):
    t0 = float(e["t_s"]); t1 = float(ev[i+1]["t_s"]) if i+1 < len(ev) else 1e9
    s = [r for r in rows if t0 + skip <= float(r["t_s"]) < t1 and r["mcs_dl"]]
    if not s: print(f"  FAIL  {e['preset']:8s} {t0:6.1f} s: no samples"); fail += 1; continue
    def med(k):
        v = [float(r[k]) for r in s if r[k] != ""]
        return st.median(v) if v else float("nan")
    m, c, g, b, sn = med("mcs_dl"), med("cqi"), med("goodput_dl"), med("bler_dl"), med("ue_sinr_dB")
    lo, hi = want[e["preset"]]; good = lo <= m <= hi; fail += not good
    print(f"  {'PASS' if good else 'FAIL'}  {e['preset']:8s} {t0:6.1f} s {float(e['noise_dB']):6.1f} dB | {sn:5.1f} dB  {c:3g}  {m:4g} (want {lo}-{hi})  {b:.5f}  {g:6.1f} Mbit/s | {len(s)}")
r = {x["rntis"] for x in rows}
okr = len(r) == 1 and all(len(x.split()) == 1 for x in r); fail += not okr
print(f"  {'PASS' if okr else 'FAIL'}  one UE context throughout: {sorted(r)}")
oos = sum(x["sync"] == "out-of-sync" for x in rows); fail += oos > 0
print(f"  {'PASS' if oos == 0 else 'FAIL'}  out-of-sync samples: {oos}")
print("RESULT:", "PASS" if fail == 0 else f"FAIL ({fail})")
PY
  [ "$(noise_db)" = "-100.0" ] && echo "  info  noise back at -100 dB" || echo "  WARNING  noise not back at -100 dB: $(noise_db)"
  echo "  info  saved in ${OUT#$REPO/} (events.csv, timeline.csv, ue-kpi.json, summary.txt)"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  DL speed test, presets $SCHEDULE through the dashboard, then noise off and speed test stopped" ;;
run) run ;;
*) echo "MODE must be preview or run"; exit 1 ;;
esac
