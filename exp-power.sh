#!/usr/bin/env bash
# Observe uplink power control on the bench (rfsim). Changes no radio setting: it only starts/stops the dashboard
# speed tests and reads the gNB/UE logs.
# Phases (PHASE_S seconds each): idle, UL speed test, DL speed test. For each phase, from the gNB MAC statistics:
#   PH and PCMAX (-> PUSCH power = PCMAX - PH), how often PH changes, PUSCH/PUCCH SNR vs the 20 dB target
#   (pusch/pucch_TargetSNRx10 in gnb.yaml; the "(+x)" in the log is the deviation), UL PRBs and MCS.
# Run ON REDLAB as the login user (no sudo):   bash exp-power.sh        Options: PHASE_S=30
# Output: ~/testbed-runs/power-<time>/ (phase logs, samples.csv, summary.txt)
set -u
PHASE_S=${PHASE_S:-30}
KC="k3s kubectl"; URL=http://10.42.0.2:30880
RUN=$HOME/testbed-runs/power-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$RUN"
KEY=$(ssh -o BatchMode=yes tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
         -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }
stop(){ api speed-stop >/dev/null; }
trap 'echo; echo "Interrupted, stopping the speed test"; stop; exit 130' INT TERM

[ -n "$KEY" ] || { echo "STOP: cannot read the admin password Secret on the core"; exit 1; }
[ "$($KC get deploy oai-nr-ue -o jsonpath='{.status.readyReplicas}')" = 1 ] || { echo "STOP: UE not running"; exit 1; }
echo "== Settings in use (gnb.yaml in the running ConfigMap)"
$KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' \
  | grep -E "^\s*(pMax|p0_NominalWithGrant|p0_nominal|pusch_TargetSNRx10|pucch_TargetSNRx10|ssPBCH_BlockPower|preambleReceivedTargetPower|powerRampingStep|msg3_DeltaPreamble):" \
  | sed 's/^ */  /' | tee "$RUN/settings.txt"
stop; sleep 3
for ph in idle:none ul:speed-ul dl:speed-dl; do
  name=${ph%%:*}; act=${ph##*:}
  if [ "$act" != none ]; then c=$(api "$act"); [ "$c" = 200 ] || { echo "STOP: dashboard refused $act (HTTP $c)"; stop; exit 1; }; sleep 8; fi
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "== Phase $name: $PHASE_S s from $t0"
  sleep "$PHASE_S"
  $KC logs deploy/oai-gnb --since-time="$t0" --timestamps > "$RUN/gnb-$name.log" 2>/dev/null
  $KC logs deploy/oai-nr-ue -c nr-ue --since-time="$t0" --timestamps > "$RUN/ue-$name.log" 2>/dev/null
  stop; sleep 4
done
python3 - "$RUN" <<'PY' | tee "$RUN/summary.txt"
import re, sys, csv, statistics as st
from datetime import datetime
run = sys.argv[1]
HDR = re.compile(r"^(\S+) UE RNTI (\w{4}) .*?PH (-?\d+) dB PCMAX (-?\d+) dBm, average RSRP (-?\d+)")
DL = re.compile(r"^(\S+) UE (\w{4}): dlsch_rounds .*?\(SNR ([-\d.]+)([+-][\d.]+)\)")
UL = re.compile(r"^(\S+) UE (\w{4}): ulsch_rounds .*?MCS \(\d+\) (\d+).*?NPRB (\d+)\s+SNR ([-\d.]+) \(([+-]?[\d.]+)\)")
ts = lambda s: datetime.fromisoformat(s[:26].rstrip("Z")).timestamp()
med = lambda x: st.median(x) if x else float("nan")
rows = []
print("phase  samples  PH dB (min/med/max)  PH changes  mean s between  PCMAX  PUSCH P est dBm  "
      "PUSCH SNR med (dev min..max)  PUCCH SNR med (dev min..max)  |dev|>1dB  UL PRB med  UL MCS med")
for name in ("idle", "ul", "dl"):
    s = {"ph": [], "pc": [], "t": [], "us": [], "ud": [], "ps": [], "pd": [], "prb": [], "mcs": []}
    for line in open(f"{run}/gnb-{name}.log", errors="replace"):
        m = HDR.match(line)
        if m:
            s["t"].append(ts(m[1])); s["ph"].append(int(m[3])); s["pc"].append(int(m[4]))
            rows.append([name, m[1], m[2], m[3], m[4], m[5], "", "", "", "", "", ""]); continue
        m = DL.match(line)
        if m:
            s["ps"].append(float(m[3])); s["pd"].append(float(m[4]))
            if rows: rows[-1][6:8] = [m[3], m[4]]
            continue
        m = UL.match(line)
        if m:
            s["mcs"].append(int(m[3])); s["prb"].append(int(m[4])); s["us"].append(float(m[5])); s["ud"].append(float(m[6]))
            if rows: rows[-1][8:12] = [m[5], m[6], m[4], m[3]]
    ch = [i for i in range(1, len(s["ph"])) if s["ph"][i] != s["ph"][i - 1]]
    gap = (s["t"][-1] - s["t"][0]) / len(ch) if ch and len(s["t"]) > 1 else float("nan")
    big = sum(abs(d) > 1 for d in s["ud"] + s["pd"]); n2 = len(s["ud"] + s["pd"]) or 1
    rng = lambda d: f"{min(d):+.1f}..{max(d):+.1f}" if d else "-"
    print(f"{name:5s}  {len(s['ph']):7d}  {min(s['ph'], default=0):4d}/{med(s['ph']):4.0f}/{max(s['ph'], default=0):<4d}      "
          f"{len(ch):6d}  {gap:14.2f}  {med(s['pc']):5.0f}  {med(s['pc']) - med(s['ph']):15.1f}  "
          f"{med(s['us']):6.1f} ({rng(s['ud'])})  {med(s['ps']):18.1f} ({rng(s['pd'])})  {100 * big / n2:7.0f} %  "
          f"{med(s['prb']):10.0f}  {med(s['mcs']):10.0f}")
with open(f"{run}/samples.csv", "w", newline="") as f:
    w = csv.writer(f); w.writerow(["phase", "time", "rnti", "ph_dB", "pcmax_dBm", "rsrp_dBm", "pucch_snr", "pucch_dev",
                                   "pusch_snr", "pusch_dev", "ul_prb", "ul_mcs"]); w.writerows(rows)
PY
echo "== UE log: power-related lines (first 6 per phase, SIM values are masked in this log)"
for n in idle ul dl; do echo "-- $n"; grep -iE "tpc|tx.?power|pathloss|p_?cmax|power headroom|PHR" "$RUN/ue-$n.log" | head -n 6; done
echo "Saved in $RUN"
