#!/usr/bin/env bash
# Experiment 16, step 2: isolation. Both cells on the same core (tiny), at 51 PRB each, loaded with UDP DL above their
# link rate: OAI cell alone, OCUDU cell alone, then both at the same time. PASS when each cell's goodput with the other
# loaded stays within 5 % of its goodput alone and no core pod restarts.
# Needs (done by hand before, see EXP-16 "Step 2"): OAI UE running and the OAI cell on profile bw-51 (profile relay),
# the OCUDU cell up (infra/ran2/ran2.sh), and a temporary iperf3 server on tiny 10.45.0.1:5203 for the OCUDU cell
# (the OAI cell uses 10.45.0.1:5202 as in Experiments 0c and 1). rfsim (OAI) and ZMQ (OCUDU) only.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp16-step2.sh
#   T=30 s per phase; RATE_OAI=250M (as Experiment 1 at 51 PRB), RATE_OCUDU=600M (offered, wall clock)
set -u
MODE=${MODE:-preview}; T=${T:-30}; RATE_OAI=${RATE_OAI:-250M}; RATE_OCUDU=${RATE_OCUDU:-600M}
REPO=$(cd "$(dirname "$0")/../.." && pwd); KC="k3s kubectl"; CPOD=exp16-oai-iperf
T_(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
K(){ T_ "k3s kubectl -n ran2 $*"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
ticks(){ for p in $(pgrep -x "$1"); do awk '{print $14 + $15}' /proc/$p/stat; done | awk '{s += $1} END {print s + 0}'; }
# OCUDU container CPU from the host cgroup on tiny (as in exp16-ocudu.sh)
cpu_us(){ T_ "u=\$(k3s kubectl -n ran2 get pod $POD -o jsonpath='{.metadata.uid}' | tr - _); c=\$(k3s kubectl -n ran2 get pod $POD -o jsonpath='{.status.containerStatuses[?(@.name==\"$1\")].containerID}' | sed 's|.*://||'); cat /sys/fs/cgroup/kubepods.slice/*/*pod\${u}.slice/cri-containerd-\${c}.scope/cpu.stat" 2>/dev/null | awk '$1=="usage_usec"{print $2}'; }
upf_us(){ T_ "c=\$(k3s kubectl -n open5gs get pod -l app.kubernetes.io/name=upf -o jsonpath='{.items[0].status.containerStatuses[0].containerID}' | sed 's|.*://||'); cat /sys/fs/cgroup/kubepods.slice/*/*/cri-containerd-\${c}.scope/cpu.stat /sys/fs/cgroup/kubepods.slice/*/cri-containerd-\${c}.scope/cpu.stat 2>/dev/null" | awk '$1=="usage_usec"{print $2; exit}'; }
restarts(){ T_ "k3s kubectl -n open5gs get pods --no-headers --field-selector=status.phase!=Succeeded" | awk '{s+=$4} END{print s+0}'; }

pre(){
  echo "== Preconditions"
  p=$(curl -s -m 10 http://10.42.0.1:8093/profile | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('current'), d.get('state'))" 2>/dev/null)
  [ "$p" = "bw-51 ok" ] && ok "OAI cell on profile bw-51" || bad "OAI cell profile/state: '$p' (want bw-51 ok)"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "OAI UE tunnel up ($(ip -4 -br addr show oaitun_ue1 | awk '{print $3}'))" || bad "OAI UE tunnel down"
  POD=$(K "get pod -l app=ocudu-cell -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null)
  K "exec $POD -c tools -- test -f /tmp/wsdump.py" 2>/dev/null && ok "OCUDU pod $POD with metrics reader" || bad "OCUDU pod/tools not ready (run exp16-ocudu.sh MODE=preview once)"
  for p in 5202 5203; do T_ "ss -Hltn '( sport = :$p )'" | grep -q "10.45.0.1:$p" && ok "iperf3 server 10.45.0.1:$p" || bad "no iperf3 server on 10.45.0.1:$p"; done
  r=$($KC get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running ('$r')"
}

client(){
  $KC run $CPOD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 1800' >/dev/null
  for i in $(seq 1 60); do $KC exec $CPOD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $CPOD -- test -f /tmp/ready 2>/dev/null && ok "OAI-side client pod ready" || { bad "client pod not ready"; exit 1; }
}

run_oai(){ $KC exec $CPOD -- iperf3 -c 10.45.0.1 -p 5202 -R -u -b "$RATE_OAI" -t "$T" --bind-dev oaitun_ue1 --connect-timeout 3000 -J > "$1" 2>&1; }
run_ocudu(){
  K "exec $POD -c tools -- sh -c 'MAXS=$((T+2)) python3 /tmp/wsdump.py 100000 > /tmp/ws.jsonl 2>/dev/null & iperf3 -c 10.45.0.1 -p 5203 -R -u -b $RATE_OCUDU -t $T --connect-timeout 3000 -J > /tmp/ip.json 2>&1; wait; cat /tmp/ip.json'" > "$1" 2>&1
  K "exec $POD -c tools -- cat /tmp/ws.jsonl" | gzip -9 > "${1%.iperf.json}.ws.jsonl.gz"
}

phase(){  # phase NAME (oai | ocudu | both)
  local ph=$1 r0 r1
  r0=$(restarts); og0=$(ticks nr-softmodem); ou0=$(ticks nr-uesoftmodem); cg0=$(cpu_us gnb); cu0=$(cpu_us ue); up0=$(upf_us); t0=$(date +%s.%N)
  case $ph in
    oai)   run_oai "$OUT/oai.oai.iperf.json" ;;
    ocudu) run_ocudu "$OUT/ocudu.ocudu.iperf.json" ;;
    both)  run_oai "$OUT/both.oai.iperf.json" & a=$!; run_ocudu "$OUT/both.ocudu.iperf.json"; wait $a ;;
  esac
  t1=$(date +%s.%N); og1=$(ticks nr-softmodem); ou1=$(ticks nr-uesoftmodem); cg1=$(cpu_us gnb); cu1=$(cpu_us ue); up1=$(upf_us); r1=$(restarts)
  T_ "uptime" | sed 's/.*load average: //' > "$OUT/$ph.load"
  echo "$t0 $t1 $og0 $og1 $ou0 $ou1 $cg0 $cg1 $cu0 $cu1 $up0 $up1 $r0 $r1 $(getconf CLK_TCK)" > "$OUT/$ph.cpu"
  echo "  $ph done"
}

analyze(){
python3 - "$OUT" <<'PYEOF'
import gzip, json, os, statistics as st, sys
out = sys.argv[1]
def ip(p):
    try: j = json.load(open(p))
    except (OSError, ValueError): return None, None
    s = j.get("end", {}).get("sum", {})
    if "lost_percent" not in s: return None, None
    return s["bits_per_second"] * (1 - s["lost_percent"] / 100) / 1e6, s["lost_percent"]
def ws(p):
    try: rows = [json.loads(l) for l in gzip.open(p, "rt") if l.startswith("{")]
    except OSError: return None, None
    du = [r["wall"] for r in rows if "du" in r]; iv = [b - a for a, b in zip(du, du[1:])]
    ues = [c["cells"][0]["ue_list"][0] for c in rows if "cells" in c and c["cells"] and c["cells"][0].get("ue_list")]
    dl = [u["dl_brate"] / 1e6 for u in ues if u["dl_brate"] > 1e6]
    return (1 / st.median(iv) if iv else None), (st.median(dl) if dl else None)
res = {}
print("  info  phase | OAI iperf Mbit/s (loss) | OCUDU iperf Mbit/s (loss) | OCUDU speed, MAC DL (sim) | CPU OAI gNB/UE | CPU OCUDU gNB/UE | UPF cores | core restarts | tiny load")
for ph in ("oai", "ocudu", "both"):
    try: v = list(map(float, open(os.path.join(out, ph + ".cpu")).read().split()))
    except OSError: continue
    t0, t1, og0, og1, ou0, ou1, cg0, cg1, cu0, cu1, up0, up1, r0, r1, hz = v; w = t1 - t0
    oai = ip(os.path.join(out, ph + ".oai.iperf.json")); oc = ip(os.path.join(out, ph + ".ocudu.iperf.json"))
    sp, mac = ws(os.path.join(out, ph + ".ocudu.ws.jsonl.gz"))
    r = dict(oai_mbit=oai[0], oai_loss=oai[1], ocudu_mbit=oc[0], ocudu_loss=oc[1], ocudu_speed=sp, ocudu_mac_dl=mac,
             oai_gnb=(og1 - og0) / hz / w, oai_ue=(ou1 - ou0) / hz / w, ocudu_gnb=(cg1 - cg0) / 1e6 / w,
             ocudu_ue=(cu1 - cu0) / 1e6 / w, upf=(up1 - up0) / 1e6 / w, restarts=r1 - r0,
             load=open(os.path.join(out, ph + ".load")).read().strip())
    res[ph] = r
    f = lambda x, n=1: "-" if x is None else ("%." + str(n) + "f") % x
    print("  info  %-5s | %6s (%5s %%)          | %6s (%5s %%)            | %5s, %5s               | %4s / %4s    | %4s / %4s      | %5s     | %d             | %s" % (
        ph, f(r["oai_mbit"]), f(r["oai_loss"]), f(r["ocudu_mbit"]), f(r["ocudu_loss"]), f(sp, 2), f(mac),
        f(r["oai_gnb"], 2), f(r["oai_ue"], 2), f(r["ocudu_gnb"], 2), f(r["ocudu_ue"], 2), f(r["upf"], 3), r["restarts"], r["load"]))
json.dump(res, open(os.path.join(out, "summary.json"), "w"), indent=1)
F = 0
def chk(name, alone, both):
    global F
    if alone is None or both is None: print("  FAIL  %s: missing data" % name); F += 1; return
    d = 100 * (both - alone) / alone
    print("  %s  %s: %.1f Mbit/s alone, %.1f with the other cell loaded (%+.1f %%, limit -5 %%)" % ("PASS" if d >= -5 else "FAIL", name, alone, both, d))
    F += d < -5
if "both" in res:
    chk("OAI cell", res.get("oai", {}).get("oai_mbit"), res["both"]["oai_mbit"])
    chk("OCUDU cell", res.get("ocudu", {}).get("ocudu_mbit"), res["both"]["ocudu_mbit"])
    rs = sum(r["restarts"] for r in res.values())
    print("  %s  core pod restarts during the phases: %d" % ("PASS" if rs == 0 else "FAIL", rs)); F += rs > 0
print("RESULT: %s" % ("PASS" if F == 0 else "FAIL (%d)" % F))
PYEOF
}

case "$MODE" in
preview) pre; echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
run)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-ocudu-step2-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  trap '$KC delete pod $CPOD --wait=false >/dev/null 2>&1' EXIT
  client
  echo "== Phases: OAI alone, OCUDU alone, both; $T s each (no dashboard controls meanwhile)"
  for ph in oai ocudu both; do phase $ph; sleep 5; done
  echo "== Summary (${OUT#$REPO/})"; analyze ;;
analyze) case "${OUT:-}" in /*) ;; "") echo "OUT=... needed"; exit 1;; *) OUT="$REPO/$OUT";; esac; analyze ;;
*) echo "MODE must be preview, run or analyze"; exit 1 ;;
esac
