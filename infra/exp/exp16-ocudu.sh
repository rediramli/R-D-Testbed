#!/usr/bin/env bash
# Experiment 16 on the bench: the OCUDU cell (infra/ran2, pod ocudu-cell on tiny) under load. Phases: idle, UDP DL and
# UL above the link rate (Experiment 0c method), one TCP flow DL and UL. For every phase it records the iperf3 JSON,
# the gNB's JSON metrics (remote control 127.0.0.1:8001, read in the pod's tools container) and the CPU time of the gNB
# and UE containers (cgroup cpu.stat), and derives:
#   speed   = simulated seconds per wall second (the gNB reports every 1000 ms of SIMULATED time; ZMQ is not paced)
#   MAC DL/UL goodput in simulated time (dl_brate/ul_brate) and iperf goodput in wall time; wall/sim = speed under load
#   CPU cores (wall), cores per simulated second (= cores / speed) and CPU-seconds per Mbit (= cores / wall Mbit/s)
# ZMQ only; nothing is reconfigured. Uses the iperf3 servers on tiny (10.45.0.1:5201 TCP / :5202 UDP), one client at a time.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp16-ocudu.sh
#   MODE=preview  preconditions only
#   MODE=run      T=30 s per phase, RATE_DL=600M, RATE_UL=300M (UDP offered, wall clock), PHASES="idle udp-dl udp-ul tcp-dl tcp-ul"
#   MODE=analyze OUT=docs/experiments/data/<run>  recompute the summary of a finished run
# Do not use the dashboard speed test while it runs (same iperf3 servers).
set -u
MODE=${MODE:-preview}; T=${T:-30}; RATE_DL=${RATE_DL:-600M}; RATE_UL=${RATE_UL:-300M}
PHASES=${PHASES:-idle udp-dl udp-ul tcp-dl tcp-ul}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
T_(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
K(){ T_ "k3s kubectl -n ran2 $*"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  POD=$(K "get pod -l app=ocudu-cell -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null)
  [ -n "$POD" ] && ok "pod $POD" || { bad "no ocudu-cell pod (MODE=apply bash infra/ran2/ran2.sh)"; return; }
  K "exec $POD -c tools -- test -f /tmp/ready" 2>/dev/null && ok "tools container ready" || bad "tools container not ready"
  UEIP=$(K "exec $POD -c ue -- ip -4 -br addr show oaitun_ue1" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  case "$UEIP" in 10.45.*) ok "UE tunnel up ($UEIP)";; *) bad "no UE tunnel";; esac
  K "exec $POD -c ue -- ip route get 10.45.0.1" 2>/dev/null | grep -q "dev oaitun_ue1" && ok "10.45.0.1 via oaitun_ue1 (through the radio)" || bad "10.45.0.1 not via the UE tunnel"
  r=$(k3s kubectl get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running (replicas '$r'): press Stop"
  for p in 5201 5202; do T_ "ss -Hltn '( sport = :$p )'" 2>/dev/null | grep -q "10.45.0.1:$p" && ok "iperf3 server 10.45.0.1:$p" || bad "no iperf3 server on 10.45.0.1:$p"; done
  scp -q "$REPO/infra/ran2/wsdump.py" tiny:/tmp/wsdump.py && K "cp /tmp/wsdump.py $POD:/tmp/wsdump.py -c tools" >/dev/null; T_ "rm -f /tmp/wsdump.py"
  K "exec $POD -c tools -- test -f /tmp/wsdump.py" && ok "metrics reader in the tools container" || bad "cannot copy wsdump.py"
}

# CPU time of one container from the host side (the privileged UE container sees the host's root cgroup, not its own)
cpu_us(){ T_ "u=\$(k3s kubectl -n ran2 get pod $POD -o jsonpath='{.metadata.uid}' | tr - _); c=\$(k3s kubectl -n ran2 get pod $POD -o jsonpath='{.status.containerStatuses[?(@.name==\"$1\")].containerID}' | sed 's|.*://||'); cat /sys/fs/cgroup/kubepods.slice/*/*pod\${u}.slice/cri-containerd-\${c}.scope/cpu.stat" 2>/dev/null | awk '$1=="usage_usec"{print $2}'; }

phase(){  # phase NAME -> $OUT/NAME.{iperf.json,ws.jsonl,cpu}
  local ph=$1 args=""
  case $ph in
    idle)   args="" ;;
    udp-dl) args="-p 5202 -R -u -b $RATE_DL" ;;
    udp-ul) args="-p 5202 -u -b $RATE_UL" ;;
    tcp-dl) args="-p 5201 -R" ;;
    tcp-ul) args="-p 5201" ;;
  esac
  g0=$(cpu_us gnb); u0=$(cpu_us ue); t0=$(date +%s.%N)
  if [ $ph = idle ]; then
    K "exec $POD -c tools -- env MAXS=$T python3 /tmp/wsdump.py 100000" > "$OUT/$ph.ws.jsonl" 2>/dev/null; echo '{}' > "$OUT/$ph.iperf.json"
  else
    K "exec $POD -c tools -- sh -c 'MAXS=$((T+2)) python3 /tmp/wsdump.py 100000 > /tmp/ws.jsonl 2>/dev/null & iperf3 -c 10.45.0.1 $args -t $T --connect-timeout 3000 -J > /tmp/ip.json 2>&1; wait; cat /tmp/ip.json'" > "$OUT/$ph.iperf.json" 2>&1
    K "exec $POD -c tools -- cat /tmp/ws.jsonl" > "$OUT/$ph.ws.jsonl" 2>/dev/null
  fi
  t1=$(date +%s.%N); g1=$(cpu_us gnb); u1=$(cpu_us ue)
  echo "$t0 $t1 $g0 $g1 $u0 $u1" > "$OUT/$ph.cpu"
  echo "  $ph done ($(wc -l < "$OUT/$ph.ws.jsonl") metric reports)"
}

analyze(){
python3 - "$OUT" $PHASES <<'PYEOF'
import gzip, json, os, statistics as st, sys
out, phases = sys.argv[1], sys.argv[2:]
def opn(p): return open(p) if os.path.exists(p) else gzip.open(p + ".gz", "rt")
def med(x): return st.median(x) if x else None
def f(v, n=1): return "-" if v is None else ("%." + str(n) + "f") % v
rows = []
print("  info  phase   | speed (sim s/wall s) | MAC DL / UL Mbit/s (sim) | iperf Mbit/s (wall) loss | DL MCS CQI BLER  UL MCS BLER | CPU cores gNB  UE | cores/sim s gNB UE | CPU-s per Mbit")
for ph in phases:
    try:
        ws = [json.loads(l) for l in opn(os.path.join(out, ph + ".ws.jsonl")) if l.startswith("{")]
        t0, t1, g0, g1, u0, u1 = map(float, open(os.path.join(out, ph + ".cpu")).read().split())
    except (OSError, ValueError) as e:
        print("  info  %s: no data (%s)" % (ph, e)); continue
    du = [r["wall"] for r in ws if "du" in r]
    iv = [b - a for a, b in zip(du, du[1:])]
    speed = 1 / med(iv) if iv else None
    ues = [c["cells"][0]["ue_list"][0] for c in ws if "cells" in c and c["cells"] and c["cells"][0].get("ue_list")]
    busy = [u for u in ues if u["dl_brate"] > 1e6 or u["ul_brate"] > 1e6] or ues
    dl = med([u["dl_brate"] / 1e6 for u in busy]); ul = med([u["ul_brate"] / 1e6 for u in busy])   # bit/s
    def bler(ok, nok):
        a, b = sum(u[ok] for u in busy), sum(u[nok] for u in busy)
        return 100.0 * b / (a + b) if a + b else None
    wall = t1 - t0; cg = (g1 - g0) / 1e6 / wall; cu = (u1 - u0) / 1e6 / wall
    ip = json.load(open(os.path.join(out, ph + ".iperf.json"))) if os.path.getsize(os.path.join(out, ph + ".iperf.json")) > 2 else {}
    end = ip.get("end", {}); rx = None; loss = None
    if "sum" in end and "lost_percent" in end["sum"]:            # UDP
        rx = end["sum"]["bits_per_second"] * (1 - end["sum"]["lost_percent"] / 100) / 1e6; loss = end["sum"]["lost_percent"]
    elif "sum_received" in end:                                    # TCP
        rx = end["sum_received"]["bits_per_second"] / 1e6
    if ip.get("error"): print("  info  %s: iperf3 error: %s" % (ph, ip["error"][:80]))
    cps = (cg + cu) / rx if rx else None
    r = dict(phase=ph, speed=speed, mac_dl=dl, mac_ul=ul, iperf=rx, loss=loss,
             dl_mcs=med([u["dl_mcs"] for u in busy]), cqi=med([u["cqi"] for u in busy]), dl_bler=bler("dl_nof_ok", "dl_nof_nok"),
             ul_mcs=med([u["ul_mcs"] for u in busy]), ul_bler=bler("ul_nof_ok", "ul_nof_nok"),
             cpu_gnb=cg, cpu_ue=cu, cps_gnb=cg / speed if speed else None, cps_ue=cu / speed if speed else None,
             cpu_s_per_mbit=cps, reports=len(du))
    rows.append(r)
    print("  info  %-7s | %5s                | %6s / %6s             | %6s  %5s%%              | %4s %4s %5s   %4s %5s  | %5s %5s      | %5s %5s      | %s" % (
        ph, f(speed, 2), f(dl), f(ul), f(rx), f(loss), f(r["dl_mcs"], 0), f(r["cqi"], 0), f(r["dl_bler"], 2), f(r["ul_mcs"], 0),
        f(r["ul_bler"], 2), f(cg, 2), f(cu, 2), f(r["cps_gnb"], 2), f(r["cps_ue"], 2), f(cps, 3)))
json.dump(rows, open(os.path.join(out, "summary.json"), "w"), indent=1)
print("  info  wall/sim check: iperf (wall) / MAC (sim) should equal the speed column for the saturated direction")
PYEOF
}

case "$MODE" in
preview) pre; echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
run)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-ocudu-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  K "get pod $POD -o jsonpath='{.spec.containers[*].image}'" > "$OUT/images.txt"
  echo "== Phases: $PHASES; $T s each; UDP DL $RATE_DL, UL $RATE_UL (offered, wall clock)"
  for ph in $PHASES; do phase $ph; done
  T_ "k3s kubectl -n open5gs top pods --no-headers; k3s kubectl top node --no-headers" > "$OUT/core-after.txt" 2>&1
  gzip -9 "$OUT"/*.ws.jsonl
  echo "== Summary ($OUT)"; analyze
  echo "RESULT: data in ${OUT#$REPO/}" ;;
analyze) [ -n "${OUT:-}" ] || { echo "OUT=docs/experiments/data/<run> needed"; exit 1; }; case "$OUT" in /*) ;; *) OUT="$REPO/$OUT";; esac; analyze ;;
*) echo "MODE must be preview, run or analyze"; exit 1 ;;
esac
