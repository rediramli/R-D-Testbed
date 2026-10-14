#!/usr/bin/env bash
# Experiment 0c on the bench: is the DL speed test (one TCP flow) what keeps the DL MAC goodput near 50 Mbit/s while the link
# carries about 88 Mbit/s at MCS 28 (Experiment 0 bench rerun)? Three DL phases with noise off: TCP, UDP at a fixed rate above
# the link capacity, TCP again. Hypothesis supported when UDP reaches about the link capacity and TCP stays well below.
# Client: a temporary pod exp0c-iperf (alpine + iperf3, host network on REDLAB, bound to oaitun_ue1), deleted at the end.
# Server: the iperf3 UL server on the core host (10.45.0.1:5202), used with -R (server sends). Nothing else changes.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp00c-tcp-udp.sh
#   MODE=preview  speed tests stopped, noise off, UE tunnel up, port 5202 listening on the core; changes nothing
#   MODE=run      about 2.5 min; results in docs/experiments/data/bench-tcpudp-<UTC time>/
# Options: T=30 (s per phase)  RATE=200M (UDP offered rate, wall clock; rfsim runs faster than real time, so
# 88 Mbit/s of simulated-time goodput needs about 140-170 Mbit/s of wall-clock offered load). Do not use the dashboard
# controls while it runs.
set -u
MODE=${MODE:-preview}; T=${T:-30}; RATE=${RATE:-200M}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp0c-iperf
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }

pre(){
  echo "== Preconditions"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  $KC get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--rfsim' \
    && ok "UE runs with --rfsim" || bad "UE without --rfsim: STOP"
  r=$($KC get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running (replicas '$r'): press Stop"
  $KC get pod $POD >/dev/null 2>&1 && bad "pod $POD already exists (delete it: $KC delete pod $POD)" || ok "no leftover pod $POD"
  tiny "ss -Hltn '( sport = :5202 )'" 2>/dev/null | grep -q "10.45.0.1:5202" && ok "iperf3 server listening on 10.45.0.1:5202 (core)" \
    || bad "no iperf3 server on 10.45.0.1:5202"
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-tcpudp-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  trap '$KC delete pod $POD --wait=false >/dev/null 2>&1' EXIT
  $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 900' >/dev/null
  for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $POD -- test -f /tmp/ready 2>/dev/null && ok "client pod ready (iperf3 $($KC exec $POD -- iperf3 --version | head -1 | awk '{print $2}'))" \
    || { bad "client pod not ready"; exit 1; }
  echo "== Phases: TCP, UDP at $RATE, TCP; $T s each (do not use the dashboard controls until RESULT)"
  T0=$(date +%s.%N)
  echo "phase,start,end" > "$OUT/phases.csv"
  for ph in tcp udp tcp2; do
    args=""; [ $ph = udp ] && args="-u -b $RATE"
    ts=$(date +%s.%N)
    $KC exec $POD -- iperf3 -c 10.45.0.1 -p 5202 -R -t "$T" --bind-dev oaitun_ue1 --connect-timeout 3000 -J $args > "$OUT/$ph.json" 2>&1
    te=$(date +%s.%N); echo "$ph,$ts,$te" >> "$OUT/phases.csv"
    echo "  info  $ph done ($(awk -v a=$te -v b=$ts 'BEGIN{printf "%.0f", a-b}') s)"
    sleep 8     # the server (-s -1) restarts after each test
  done
  T1=$(date +%s.%N)
  dur=$(awk -v a="$T1" -v b="$T0" 'BEGIN{print int(a-b)+10}')
  curl -s -m 20 "$URL/api/history?seconds=$dur" > "$OUT/history.json"
  curl -s -m 20 "$URL/api/kpi?domain=ue&seconds=$dur" > "$OUT/ue-kpi.json"
  $KC delete pod $POD --wait=false >/dev/null 2>&1; trap - EXIT
  python3 - "$OUT" "$T0" "$T1" "$T" "$RATE" <<'PY' | tee "$OUT/summary.txt"
import csv, json, statistics as st, sys
out, t0, t1, T, rate = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
h = json.load(open(out + "/history.json"))["rows"]
ph = list(csv.DictReader(open(out + "/phases.csv")))
ues = [u["rnti"] for u in json.load(open(out + "/ue-kpi.json"))["ues"] if u["first"] <= t1 and u["last"] >= t0]
# the same timeline/events format as Experiment 0, so plot-noise-timeline.py can draw it (preset column = phase)
f = lambda v, n: "" if v is None else ("%." + str(n) + "f") % v
def phase_at(t):
    p = ""
    for x in ph:
        if float(x["start"]) <= t <= float(x["end"]) + 8:
            p = x["phase"]
    return p
with open(out + "/timeline.csv", "w") as fh:
    fh.write("t_s,preset,rntis,sync,cqi,mcs_dl,bler_dl,goodput_dl,ue_sinr_dB\n")
    for r in h:
        if t0 <= r["t"] <= t1:
            fh.write(",".join([f(r["t"] - t0, 1), phase_at(r["t"]), " ".join(ues), "out-of-sync" if r.get("oos") else "in-sync",
                               f(r.get("cqi"), 0), f(r.get("mcsDl"), 0), f(r.get("blerDl"), 5), f(r.get("goodputDl"), 2),
                               f(r.get("sinrUe"), 1)]) + "\n")
with open(out + "/events.csv", "w") as fh:
    fh.write("t_s,preset,noise_dB,http,apply_s\n")
    for x in ph:
        fh.write("%.1f,%s,-100.0,200,0.0\n" % (float(x["start"]) - t0, x["phase"]))
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
res = {}
print("  info  phase | iperf3 receiver (wall clock)   loss | MAC goodput median (p90), sim time | MCS  BLER | samples")
for x in ph:
    a, b = float(x["start"]) + 5, float(x["end"]) - 2     # skip the TCP ramp-up and the tail
    s = [y for y in h if a <= y["t"] <= b and y.get("goodputDl") is not None]
    try:
        j = json.load(open(out + "/" + x["phase"] + ".json"))
        e = j["end"]
        if x["phase"] == "udp":
            ip, loss = e["sum"]["bits_per_second"] / 1e6, e["sum"].get("lost_percent")
        else:
            ip, loss = e["sum_received"]["bits_per_second"] / 1e6, None
        err = j.get("error")
    except Exception as ex:
        ip, loss, err = None, None, str(ex)[:80]
    g = sorted(y["goodputDl"] for y in s)
    med = st.median(g) if g else None
    res[x["phase"]] = med
    mcs = st.median(y["mcsDl"] for y in s if y.get("mcsDl") is not None) if s else None
    bl = st.median(y["blerDl"] for y in s if y.get("blerDl") is not None) if s else None
    print("  info  %-5s | %7s Mbit/s  %s | %6s (%s) Mbit/s | %s  %s | %d" % (
        x["phase"], f(ip, 1), ("loss %5.1f %%" % loss) if loss is not None else "            ", f(med, 1),
        f(g[9 * len(g) // 10] if g else None, 1), f(mcs, 0), f(bl, 4), len(s)))
    r(ip is not None and not err, "%s: iperf3 completed%s" % (x["phase"], "" if not err else " (" + err + ")"))
    r(len(s) >= T - 10, "%s: %d MAC samples (want >= %d)" % (x["phase"], len(s), T - 10))
r(len(ues) == 1, "one UE context throughout: %s" % ues)
oos = sum(1 for y in h if t0 <= y["t"] <= t1 and y.get("oos")); r(oos == 0, "out-of-sync samples: %d" % oos)
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
tcp = [v for k, v in res.items() if k.startswith("tcp") and v is not None]; udp = res.get("udp")
if tcp and udp:
    supported = udp >= 75 and udp >= 1.4 * max(tcp)
    print("VERDICT: hypothesis %s: UDP MAC goodput %.1f vs TCP %s Mbit/s (supported if UDP >= 75 and >= 1.4 x TCP)"
          % ("SUPPORTED" if supported else "NOT supported", udp, " / ".join("%.1f" % v for v in tcp)))
PY
  rm -f "$OUT/history.json"
  echo "  info  saved in ${OUT#$REPO/}"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  temporary pod $POD (alpine + iperf3, host network), DL TCP / UDP $RATE / TCP, $T s each, then delete the pod" ;;
run) run ;;
*) echo "MODE must be preview or run"; exit 1 ;;
esac
