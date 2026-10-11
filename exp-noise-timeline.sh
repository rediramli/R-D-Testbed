#!/usr/bin/env bash
# LAB-0 timeline: switch the DL channel presets ON A RUNNING DL speed test and record how CQI, MCS,
# BLER, goodput and UE SINR follow, with the time of every switch (for an annotated graph).
# The switches go through the noise relay (the same path as the dashboard buttons).
# Runs ON FCT0173:   ssh fct0173 'bash -s' < exp-noise-timeline.sh
# Do not press the dashboard DL channel buttons while it runs (about 4 minutes).
# Options (env): SCHEDULE="off:40 clean:40 moderate:40 poor:40 off:40"  STEP=1  SKIP=10
# Output: ~/fct-testbed/exp-noise/timeline-<time>/ (timeline.csv, events.csv, summary.txt, raw.log, gnb.log, ue.log);
# the two CSV files are also printed at the end so they can be pasted for the graph.
set -u
RUN=~/fct-testbed/exp-noise/timeline-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$RUN"
URL=http://10.0.129.7:8092; NS=fct-dash
T_START=$(date -u +%Y-%m-%dT%H:%M:%SZ); T0=$(date +%s.%N)
STEP=${STEP:-1}; SKIP=${SKIP:-10}
SCHEDULE=${SCHEDULE:-off:40 clean:40 moderate:40 poor:40 off:40}
say(){ printf '\n== %s  (%s UTC)\n' "$1" "$(date -u +%T)" | tee -a "$RUN/summary.txt"; }
log(){ echo "$*" | tee -a "$RUN/summary.txt"; }
now(){ awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN{printf "%.1f", a-b}'; }

TOKEN=$(kubectl -n $NS get secret noise-relay-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
setp(){  # setp PRESET -> HTTP code (token never printed)
  curl -s -m 12 -o /dev/null -w '%{http_code}' -X POST "$URL/noise" -H "Content-Type: application/json" \
    -H "X-Relay-Token: $TOKEN" --data-binary "{\"preset\":\"$1\"}"; }
relay_db(){ curl -s -m 3 "$URL/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
gnb_stats(){ kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null; }
sample(){  # sample PRESET -> one CSV row
  local t raw ue; t=$(now); raw=$(gnb_stats); ue=$(kubectl logs deploy/oai-nr-ue --since=3s 2>/dev/null)
  { echo "### t=$t preset=$1"; echo "$raw"; } >> "$RUN/raw.log"
  python3 -c '
import re, sys
raw, ue, t, p = sys.argv[1:5]
g = lambda pat: (re.search(pat, raw) or [None, ""])[1]
sinr = re.findall(r"SINR ([-\d.]+) dB", ue)
print(",".join([t, p, " ".join(re.findall(r"UE RNTI ([0-9a-f]{4})", raw)),
  g(r"UE RNTI [0-9a-f]{4}.*?\b(in-sync|out-of-sync)\b"), g(r"CQI (\d+)"),
  g(r"dlsch_rounds.*?MCS \(\d+\) (\d+)"), g(r"dlsch_rounds.*?BLER ([\d.]+)"),
  g(r"goodput DL\s+([\d.]+)"), sinr[-1] if sinr else ""]))' "$raw" "$ue" "$t" "$1"
}
restore(){
  say "Restore: preset off, speed test stopped (logs saved first)"
  kubectl logs deploy/oai-nr-ue --timestamps --since-time="$T_START" > "$RUN/ue.log" 2>&1
  kubectl logs deploy/oai-gnb --timestamps --since-time="$T_START" > "$RUN/gnb.log" 2>&1
  kubectl scale deploy speedtest-dl --replicas=0 >/dev/null
  setp off >/dev/null; sleep 1
  [ "$(relay_db)" = "-100.0" ] && log "Noise back at -100 dB (off)" || log "WARNING: relay does not report -100 dB; check the dashboard"
}
trap 'echo; echo "Interrupted"; restore; exit 130' INT TERM

say "1. Preconditions"
[ -n "$TOKEN" ] || { log "STOP: cannot read the relay token Secret"; exit 1; }
[ "$(kubectl get deploy oai-gnb -o jsonpath='{.status.readyReplicas}')" = 1 ] || { log "STOP: gNB not running"; exit 1; }
[ "$(kubectl get deploy oai-nr-ue -o jsonpath='{.status.readyReplicas}')" = 1 ] || { log "STOP: UE not running"; exit 1; }
kubectl get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q '"--rfsim"' \
  && log "rfsim flag present" || { log "STOP: no --rfsim"; exit 1; }
[ "$(curl -s -m 5 $URL/healthz)" = '"ok"' ] && log "relay up" || { log "STOP: relay not answering on $URL"; exit 1; }
c=$(setp off); [ "$c" = 200 ] || { log "STOP: relay refused 'off' (HTTP $c)"; exit 1; }
kubectl scale deploy speedtest-ul --replicas=0 >/dev/null
kubectl scale deploy speedtest-dl --replicas=1 >/dev/null
gp(){ gnb_stats | grep -oE "goodput DL +[0-9.]+" | awk '{print int($3)}' | head -1; }
ok=0; for i in $(seq 1 30); do [ "$(gp)" -gt 50 ] 2>/dev/null && { ok=1; break; }; sleep 2; done
[ $ok = 1 ] || { log "STOP: DL speed test not running (goodput $(gp))"; restore; exit 1; }
log "DL speed test running (goodput $(gp) Mbit/s)"

say "2. Timeline: $SCHEDULE (sample every ${STEP} s)"
T0=$(date +%s.%N)
echo "t_s,preset,rntis,sync,cqi,mcs_dl,bler_dl,goodput_dl,ue_sinr_dB" > "$RUN/timeline.csv"
echo "t_s,preset,noise_dB,http,apply_s" > "$RUN/events.csv"
for ph in $SCHEDULE; do
  p=${ph%%:*}; d=${ph##*:}
  ts=$(now); c=$(setp "$p"); te=$(now)
  echo "$ts,$p,$(relay_db),$c,$(awk -v a=$te -v b=$ts 'BEGIN{printf "%.1f", a-b}')" | tee -a "$RUN/events.csv"
  end=$(awk -v a=$ts -v d=$d 'BEGIN{print a+d}')
  while awk -v n="$(now)" -v e=$end 'BEGIN{exit !(n < e)}'; do
    sample "$p" | tee -a "$RUN/timeline.csv"; sleep "$STEP"
  done
done
trap - INT TERM
restore

say "3. Check each phase (samples after the first ${SKIP} s): MCS range, same RNTI, in-sync"
python3 - "$RUN/timeline.csv" "$RUN/events.csv" "$SKIP" <<'PY' | tee -a "$RUN/summary.txt"
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1]))); ev = list(csv.DictReader(open(sys.argv[2]))); skip = float(sys.argv[3])
want = {"off": (26, 28), "clean": (23, 28), "moderate": (12, 18), "poor": (3, 9)}
fail = 0
for e in ev:
    if e["http"] != "200": print(f"  FAIL  switch to {e['preset']} at {e['t_s']} s: HTTP {e['http']}"); fail += 1
for i, e in enumerate(ev):
    t0 = float(e["t_s"]); t1 = float(ev[i+1]["t_s"]) if i+1 < len(ev) else 1e9
    s = [r for r in rows if t0 + skip <= float(r["t_s"]) < t1 and r["mcs_dl"]]
    if not s: print(f"  FAIL  {e['preset']:8s} {t0:6.1f} s: no samples"); fail += 1; continue
    m = st.median(int(r["mcs_dl"]) for r in s); c = st.median(int(r["cqi"]) for r in s if r["cqi"])
    g = st.median(float(r["goodput_dl"] or 0) for r in s)
    lo, hi = want[e["preset"]]; good = lo <= m <= hi
    fail += not good
    print(f"  {'PASS' if good else 'FAIL'}  {e['preset']:8s} from {t0:6.1f} s: median CQI {c:g}, MCS {m:g} (want {lo}-{hi}), goodput {g:.1f} Mbit/s, {len(s)} samples")
r = {x["rntis"] for x in rows if x["rntis"]}
ok = len(r) == 1 and all(len(x.split()) == 1 for x in r); fail += not ok
print(f"  {'PASS' if ok else 'FAIL'}  one UE context throughout: {sorted(r)}")
oos = sum(x["sync"] == "out-of-sync" for x in rows); fail += oos > 0
print(f"  {'PASS' if oos == 0 else 'FAIL'}  out-of-sync samples: {oos}")
print("RESULT:", "PASS" if fail == 0 else f"FAIL ({fail})")
PY
say "Data for the graph (paste everything between the BEGIN/END lines)"
echo "----- BEGIN events.csv"; cat "$RUN/events.csv"; echo "----- END events.csv"
echo "----- BEGIN timeline.csv"; cat "$RUN/timeline.csv"; echo "----- END timeline.csv"
log "Saved in $RUN"
