#!/usr/bin/env bash
# Experiment 1 on the bench: carrier bandwidth (PRB count) and capacity. For every bandwidth: reconfigure the gNB carrier
# and the UE, wait for the UE to register, measure the DL capacity with UDP above the link rate (Experiment 0c method),
# the radio values and the CPU load of the rfsim processes; at the end the bench always goes back to 106 PRB.
# The carrier parameters come from OAI's own configurations at tag 2026.w40 (ci-scripts/conf_files):
#   PRB  pointA  SSB     CORESET0  BWP RIV  UE -C (Hz)   UE --ssb   source
#   24   640032  640320  2         6325     3604800000   24         gnb.sa.band78.24prb.rfsim.conf
#   51   639996  640704  12        13750    3609120000   234        gnb.sa.band78.51prb.usrpb200.conf
#   106  620040  621312  11        28875    3319680000   516        gnb.sa.band78.106prb.rfsim (our baseline)
#   273  626772  630048  12        1099     3450720000   1518       gnb.sa.band78.273prb.rfsim.2x2.conf (used 1x1 here)
# 24 PRB runs without -E (3/4 sampling): OAI asserts on 11.52 MHz at numerology 1 (log of run 20261014T103040Z).
# -C is the DL carrier centre (pointA + PRB x 6 x 30 kHz); --ssb is the first SSB subcarrier from pointA.
# Only infra/ran/gnb.yaml values and the UE command line change, in temporary copies: the repo files are not touched.
# rfsim only (--rfsim stays on both); the core is not touched. Each change restarts gNB and UE (about 1 min without UE).
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp01-bandwidth.sh
#   MODE=preview  preconditions; builds and checks the temporary configs for every bandwidth; changes nothing
#   MODE=run      BWS="24 51 106" (default; 273 on its own: BWS=273), T=30 s of UDP per bandwidth; then back to 106
#   MODE=restore  put the repo configuration (106 PRB) back and wait for the UE
#   MODE=analyze OUT=docs/experiments/data/<run>  recompute the summary of a finished run; changes nothing on the bench
# Do not use the dashboard controls while it runs.
set -u
MODE=${MODE:-preview}; BWS=${BWS:-"24 51 106"}; T=${T:-30}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd); RAN=$REPO/infra/ran
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp01-iperf
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

params(){  # params PRB -> "pointA ssb coreset0 riv centreHz ssbOffset rateUDP"
  case $1 in
    24)  echo "640032 640320 2 6325 3604800000 24 150M" ;;
    51)  echo "639996 640704 12 13750 3609120000 234 250M" ;;
    106) echo "620040 621312 11 28875 3319680000 516 200M" ;;
    273) echo "626772 630048 12 1099 3450720000 1518 600M" ;;
    *) return 1 ;;
  esac
}

build(){  # build PRB -> temporary gnb.yaml and ran.yaml for that bandwidth in $TMP/PRB/
  set -- $1 $(params $1) || return 1
  mkdir -p "$TMP/$1"
  python3 - "$RAN" "$TMP/$1" "$@" <<'PYEOF'
import re, sys
src, out, prb, pa, ssb, cs0, riv, c, so, _ = sys.argv[1:]
g = open(src + "/gnb.yaml").read()
for key, val in (("absoluteFrequencySSB", ssb), ("dl_absoluteFrequencyPointA", pa), ("dl_carrierBandwidth", prb),
                 ("ul_carrierBandwidth", prb), ("initialDLBWPlocationAndBandwidth", riv),
                 ("initialULBWPlocationAndBandwidth", riv), ("initialDLBWPcontrolResourceSetZero", cs0)):
    g, n = re.subn(r"(?m)^(\s*%s:\s*)\S+\s*$" % key, r"\g<1>%s" % val, g)
    assert n == 1, "%s found %d times" % (key, n)
open(out + "/gnb.yaml", "w").write(g)
r = open(src + "/ran.yaml").read()
old = "-r 106 --numerology 1 -C 3319680000"
assert r.count(old) == 1, "UE command line not found once in ran.yaml"
r = r.replace(old, "-r %s --numerology 1 -C %s --ssb %s" % (prb, c, so))
assert r.count("--rfsim") >= 2
if prb == "24":
    # OAI 2026.w40 asserts in get_prach_ru_params(): with -E (3/4 sampling) 24 PRB gives 11.52 MHz, "not supported for
    # numerology 1". Without -E it samples at 15.36 MHz (FFT 512). gNB and UE must both drop it (same sample rate in rfsim).
    assert r.count("-E --rfsim") == 2, "-E not found on both gNB and UE"
    r = r.replace("-E --rfsim", "--rfsim")
open(out + "/ran.yaml", "w").write(r)
PYEOF
}

deploy(){  # deploy DIR -> apply gnb.yaml/ran.yaml from DIR (as ran.sh apply does), gNB first, then the UE
  local d=$1
  $KC create configmap oai-gnb-config --from-file=gnb.yaml="$d/gnb.yaml" --dry-run=client -o yaml | $KC apply -f - >/dev/null
  local GH=$(sha256sum "$d/gnb.yaml" | cut -c1-12) UH=$(sha256sum "$RAN/nr-ue.yaml.tpl" | cut -c1-12)
  sed -e "s/GNB_CONFIG_HASH/$GH/" -e "s/UE_CONFIG_HASH/$UH/" "$d/ran.yaml" | $KC apply -f - >/dev/null
  $KC rollout status deploy/oai-gnb --timeout=180s >/dev/null || return 1
  sleep 10
  $KC rollout restart deploy/oai-nr-ue >/dev/null; $KC rollout status deploy/oai-nr-ue --timeout=180s >/dev/null || return 1
  for i in $(seq 1 60); do ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ping -I oaitun_ue1 -c 1 -W 2 10.45.0.1 >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

restore(){
  echo "== Restore: repo configuration (106 PRB)"
  $KC delete pod $POD --wait=false >/dev/null 2>&1
  if deploy "$RAN"; then ok "back at 106 PRB, UE registered ($(ip -4 -br addr show oaitun_ue1 | awk '{print $3}'))"
  else bad "UE not back after restoring 106 PRB: run sudo MODE=apply bash infra/ran/ran.sh"; fi
  $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | grep -q "dl_carrierBandwidth: 106" \
    && ok "gNB ConfigMap holds the repo gnb.yaml (106 PRB)" || bad "gNB ConfigMap is not the 106 PRB repo file"
}

cpu_ticks(){ for p in $(pgrep -x "$1"); do awk '{print $14 + $15}' /proc/$p/stat; done | awk '{s += $1} END {print s + 0}'; }

pre(){
  echo "== Preconditions"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  r=$($KC get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running (replicas '$r'): press Stop"
  $KC get pod $POD >/dev/null 2>&1 && bad "pod $POD already exists ($KC delete pod $POD)" || ok "no leftover pod $POD"
  tiny "ss -Hltn '( sport = :5202 )'" 2>/dev/null | grep -q "10.45.0.1:5202" && ok "iperf3 server on 10.45.0.1:5202 (core)" \
    || bad "no iperf3 server on 10.45.0.1:5202"
  $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | cmp -s - "$RAN/gnb.yaml" \
    && ok "running gNB config = repo infra/ran/gnb.yaml" || bad "running gNB config differs from the repo file (restore first)"
  for b in $BWS; do
    if build $b 2>"$TMP/err"; then
      n=$(diff "$RAN/gnb.yaml" "$TMP/$b/gnb.yaml" | grep -c '^>'); u=$(grep -o -- "-r $b --numerology 1 -C [0-9]* --ssb [0-9]*" "$TMP/$b/ran.yaml")
      if [ "$b" = 106 ]; then
        [ "$n" = 0 ] && ok "106 PRB: baseline, the repo files are used as they are" || bad "106 PRB: gnb.yaml would change ($n lines)"
      else
        e=$(grep -c -- "-E --rfsim" "$TMP/$b/ran.yaml"); [ "$e" = 2 ] && e="3/4 sampling (-E)" || e="full sampling (no -E, $e left)"
        [ "$n" -ge 5 ] && [ -n "$u" ] && ok "$b PRB: $n gNB lines changed; UE: $u; $e" || bad "$b PRB: unexpected diff ($n lines, UE '$u')"
      fi
    else bad "$b PRB: config not built: $(tail -1 "$TMP/err")"; fi
  done
  echo "  info  each bandwidth restarts gNB and UE (~1-2 min); the run ends with 106 PRB restored"
}

analyze(){  # analyze: summary and checks for the run folder $OUT (also MODE=analyze OUT=docs/experiments/data/<run>)
  python3 - "$OUT" "$T" <<'PY' | tee "$OUT/summary.txt"; [ "${PIPESTATUS[0]}" = 0 ] || F=$((F+1))
import csv, json, statistics as st, sys
out, T = sys.argv[1], float(sys.argv[2])
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
rows = []
print("  info  PRB  MHz | MAC goodput median (p90)  per PRB | MCS  BLER   | iperf rx wall  loss  | wall/sim | CPU gNB  UE")
for x in csv.DictReader(open(out + "/runs.csv")):
    prb = int(x["prb"])
    if not x["t_start"]:
        r(False, "%d PRB: no measurement (UE did not register)" % prb); continue
    a, b = float(x["t_start"]) + 8, float(x["t_end"]) - 2
    h = [y for y in json.load(open(out + "/history-%d.json" % prb))["rows"] if a <= y["t"] <= b and y.get("goodputDl") is not None]
    g = sorted(y["goodputDl"] for y in h)
    med = st.median(g) if g else None
    mcs = st.median(y["mcsDl"] for y in h if y.get("mcsDl") is not None) if h else None
    bl = st.median(y["blerDl"] for y in h if y.get("blerDl") is not None) if h else None
    rx = loss = q = None
    try:
        j, _ = json.JSONDecoder().raw_decode(open(out + "/udp-%d.json" % prb).read())
        iv = [i["sum"] for i in j.get("intervals", [])]
        e = j.get("end", {}).get("sum")
        if e:
            rx = e["bits_per_second"] / 1e6 * (1 - e.get("lost_percent", 0) / 100); loss = e.get("lost_percent", 0)
        elif iv:   # no end summary (iperf3 error at the end): use the per-second intervals
            rx = sum(x["bytes"] for x in iv) * 8 / sum(x["seconds"] for x in iv) / 1e6
            loss = 100 * sum(x["lost_packets"] for x in iv) / max(1, sum(x["packets"] for x in iv))
        q = next((k for k, x in enumerate(iv) if x["lost_percent"] > 5), None)   # second in which drops start
        if j.get("error"):
            print("  info  %d PRB: iperf3 ended with '%s' (results taken from %d intervals)" % (prb, j["error"][:60], len(iv)))
    except Exception as ex:
        print("  info  %d PRB: iperf3 output not readable: %s" % (prb, str(ex)[:80]))
    mhz = {24: 10, 51: 20, 106: 40, 273: 100}.get(prb, 0)
    rows.append({"prb": prb, "mhz": mhz, "goodput": med, "mcs": mcs, "bler": bl, "rx": rx, "loss": loss,
                 "cpuGnb": int(x["cpu_gnb_pct"]), "cpuUe": int(x["cpu_ue_pct"]), "n": len(g), "firstDropS": q})
    f = lambda v, d: "-" if v is None else ("%." + str(d) + "f") % v
    print("  info  %3d  %3d | %6s (%s) Mbit/s  %5s  | %4s %6s | %6s Mbit/s %5s %% | %5s | %4d %% %4d %%" % (
        prb, mhz, f(med, 1), f(g[9 * len(g) // 10] if g else None, 1), f(med / prb if med else None, 3), f(mcs, 0), f(bl, 4),
        f(rx, 1), f(loss, 1), f(rx / med if rx and med else None, 2), int(x["cpu_gnb_pct"]), int(x["cpu_ue_pct"])))
    r(len(g) >= T - 12, "%d PRB: %d MAC samples" % (prb, len(g)))
    r(mcs is not None and mcs >= 27, "%d PRB: DL MCS %s with noise off (want >= 27)" % (prb, f(mcs, 0)))
    r(bl is not None and bl < 0.01, "%d PRB: DL BLER %s (want < 0.01)" % (prb, f(bl, 4)))
    r(loss is not None and loss >= 5, "%d PRB: link saturated, UDP loss %s %% (want >= 5 %%; below that the offered rate"
      " was under the capacity and the goodput is only a lower bound)" % (prb, f(loss, 1)))
    rows[-1]["saturated"] = loss is not None and loss >= 5
json.dump(rows, open(out + "/results.json", "w"), indent=1)
for x in rows:
    if x["firstDropS"] is not None:
        print("  info  %d PRB: UDP drops start after %d s (wall clock): the path buffers that long before it drops" % (x["prb"], x["firstDropS"]))
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
ref = next((x for x in rows if x["prb"] == 106 and x["goodput"]), None)
if ref:
    for x in rows:
        if x["goodput"] and x["prb"] != 106:
            exp = ref["goodput"] * x["prb"] / 106
            print("FINDING: %d PRB carries %.1f Mbit/s = %.0f %% of the PRB-proportional %.1f (106 PRB: %.1f)%s"
                  % (x["prb"], x["goodput"], 100 * x["goodput"] / exp, exp, ref["goodput"],
                     "" if x["saturated"] and ref["saturated"] else " [NOT saturated: lower bound only]"))
sys.exit(1 if fail else 0)
PY
  for f in "$OUT"/history-*.json; do python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); d['rows']=[{k:r.get(k) for k in ('t','cqi','mcsDl','blerDl','goodputDl','sinrUe','oos')} for r in d['rows']]; json.dump(d,open(sys.argv[1],'w'))" "$f"; done
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-bandwidth-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  trap 'restore; rm -rf "$TMP"' EXIT
  echo "prb,t_start,t_end,iperf_json,cpu_gnb_pct,cpu_ue_pct" > "$OUT/runs.csv"
  for b in $BWS; do
    set -- $(params $b); rate=$7
    echo "== $b PRB: reconfigure gNB and UE"
    d="$TMP/$b"; [ "$b" = 106 ] && d="$RAN"
    if ! deploy "$d"; then
      bad "$b PRB: UE did not register"; echo "$b,,,,," >> "$OUT/runs.csv"
      L="$HOME/exp-logs/$(basename "$OUT")"; mkdir -p "$L"
      for c in oai-gnb oai-nr-ue; do
        $KC logs deploy/$c --tail=600 2>&1 | sed -E 's/(ki|opc|op|key|k)=[0-9a-fA-Fx]+/\1=<removed>/Ig' > "$L/fail-$b-$c.log"
      done
      echo "  info  $b PRB: gNB/UE logs in $L (outside the repo, SIM values removed)"
      continue
    fi
    ok "$b PRB: UE registered ($(ip -4 -br addr show oaitun_ue1 | awk '{print $3}'))"
    $KC logs deploy/oai-gnb 2>/dev/null | grep -m3 -iE 'N_RB_DL|nr_band|carrier.*bandwidth|dl_CarrierFreq' > "$OUT/gnb-carrier-$b.txt"
    $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
      --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
      --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 900' >/dev/null
    for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
    sleep 5
    g0=$(cpu_ticks nr-softmodem); u0=$(cpu_ticks nr-uesoftmodem); ts=$(date +%s.%N)
    $KC exec $POD -- iperf3 -c 10.45.0.1 -p 5202 -R -u -b "$rate" -t "$T" --bind-dev oaitun_ue1 --connect-timeout 3000 -J \
      > "$OUT/udp-$b.json" 2>&1
    te=$(date +%s.%N); g1=$(cpu_ticks nr-softmodem); u1=$(cpu_ticks nr-uesoftmodem)
    cg=$(awk -v a=$g0 -v b=$g1 -v s=$ts -v e=$te -v h=$(getconf CLK_TCK) 'BEGIN{printf "%.0f", (b-a)/h/(e-s)*100}')
    cu=$(awk -v a=$u0 -v b=$u1 -v s=$ts -v e=$te -v h=$(getconf CLK_TCK) 'BEGIN{printf "%.0f", (b-a)/h/(e-s)*100}')
    echo "$b,$ts,$te,udp-$b.json,$cg,$cu" >> "$OUT/runs.csv"
    echo "  info  $b PRB: UDP $rate for $T s done; CPU gNB $cg %, UE $cu % (100 % = one core)"
    curl -s -m 20 "$URL/api/history?seconds=$((T + 20))" > "$OUT/history-$b.json"
    $KC delete pod $POD --wait=false >/dev/null 2>&1; sleep 3
  done
  trap 'rm -rf "$TMP"' EXIT
  restore
  analyze
  echo "  info  saved in ${OUT#$REPO/}"
  echo "RESULT (run and restore): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  for PRB in $BWS: reconfigure gNB + UE, UDP for $T s, record; then restore 106 PRB" ;;
run) run ;;
analyze) F=0; OUT=${OUT:?set OUT=docs/experiments/data/<run folder>}; case $OUT in /*) ;; *) OUT=$REPO/$OUT ;; esac
         analyze; echo "RESULT (analyze): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
restore) F=0; restore; echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
*) echo "MODE must be preview, run, restore or analyze"; exit 1 ;;
esac
