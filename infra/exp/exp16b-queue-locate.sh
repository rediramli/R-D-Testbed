#!/usr/bin/env bash
# Experiment 16b on the bench: where does the downlink queue sit? Experiment 16 showed that a UDP DL flow above the link
# rate delays every other DL packet by about 3 s at noise Off (about 35 MB of queue). This script repeats that load for
# T seconds and, once a second, reads the three places where the queue can be:
#   1. the core host (P3 Tiny): qdisc backlog on the UPF tunnel interface (ogstun) and on the interface towards the gNB;
#   2. REDLAB: the receive queue of the gNB's GTP-U socket (UDP 2152) and the kernel's UDP buffer drops;
#   3. inside the gNB process (PDCP/RLC): not readable directly; it is what remains when 1 and 2 stay small while the
#      delay grows.
# Meanwhile it pings the core (10.45.0.1) through the UE tunnel every 0.2 s: the RTT shows the queueing delay over time,
# including how long the queue takes to drain after the load stops.
# Read-only on both hosts (tc -s, ss, nstat, ping); the only traffic is the UDP load, as in Experiments 0c/16. rfsim only.
# Client: temporary pod exp16b-load (alpine + iperf3, host network, bound to oaitun_ue1), deleted at the end.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp16b-queue-locate.sh
#   MODE=preview  preconditions and the interface names on the core host; changes nothing
#   MODE=run      about 1.5 min; results in docs/experiments/data/bench-queue-<UTC time>/
# Options: T=40 (s of load) RATE=200M  Noise stays Off; do not use the dashboard controls while it runs.
set -u
MODE=${MODE:-preview}; T=${T:-40}; RATE=${RATE:-200M}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp16b-load
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
N3IF=""; PP=""

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
  tiny "tc -s qdisc show dev ogstun" >/dev/null 2>&1 && ok "core host: ogstun qdisc readable" || bad "core host: cannot read the ogstun qdisc"
  N3IF=$(tiny "ip -o route get 10.42.0.1" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')
  [ -n "$N3IF" ] && ok "core host: interface towards the gNB = $N3IF" || bad "core host: no route to 10.42.0.1"
  ss -uanmH '( sport = :2152 )' | grep -q . && ok "gNB GTP-U socket (UDP 2152) visible on REDLAB" || bad "no UDP 2152 socket on REDLAB"
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-queue-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  trap '$KC delete pod $POD --wait=false >/dev/null 2>&1; kill $PP 2>/dev/null' EXIT
  $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache iperf3 >/dev/null && touch /tmp/ready && sleep 900' >/dev/null
  for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $POD -- test -f /tmp/ready 2>/dev/null && ok "load pod ready" || { bad "load pod not ready"; exit 1; }
  echo "== Ping through the tunnel (0.2 s), 10 s idle, $T s of UDP $RATE, 30 s drain"
  ping -D -I oaitun_ue1 -i 0.2 -W 30 10.45.0.1 > "$OUT/ping.txt" 2>&1 & PP=$!
  T0=$(date +%s.%N)
  echo "t,tiny_ogstun_backlog_b,tiny_ogstun_drops,tiny_n3_backlog_b,tiny_n3_drops,gnb_sock_recvq_b,udp_rcvbuf_errors" > "$OUT/queues.csv"
  sample(){
    local t=$(date +%s.%N)
    local tq=$(tiny "tc -s qdisc show dev ogstun; echo ===; tc -s qdisc show dev $N3IF" 2>/dev/null | python3 -c '
import re, sys
parts = sys.stdin.read().split("===")
def tot(s, k):  # the largest value: a root qdisc (mq) already sums its children
    return max([int(x) for x in re.findall(k, s)] or [0])
out = []
for p in parts[:2]:
    out += [tot(p, r"backlog (\d+)b"), tot(p, r"dropped (\d+)")]
print(",".join(map(str, out + [0] * (4 - len(out)))))')
    local rq=$(ss -uanH '( sport = :2152 )' | awk '{s += $2} END {print s + 0}')
    local ue=$(nstat -az UdpRcvbufErrors 2>/dev/null | awk '/UdpRcvbufErrors/ {print $2}')
    echo "$t,$tq,$rq,${ue:-0}" >> "$OUT/queues.csv"
  }
  for i in $(seq 1 10); do sample; sleep 0.6; done
  echo "load_start,$(date +%s.%N)" > "$OUT/events.csv"
  $KC exec $POD -- iperf3 -c 10.45.0.1 -p 5202 -R -u -b "$RATE" -t "$T" --bind-dev oaitun_ue1 -J > "$OUT/udp.json" 2>&1 &
  LP=$!
  while kill -0 $LP 2>/dev/null; do sample; sleep 0.6; done
  echo "load_end,$(date +%s.%N)" >> "$OUT/events.csv"
  for i in $(seq 1 30); do sample; sleep 0.6; done
  kill $PP 2>/dev/null; wait $PP 2>/dev/null
  $KC delete pod $POD --wait=false >/dev/null 2>&1; trap - EXIT
  python3 - "$OUT" "$T0" <<'PY' | tee "$OUT/summary.txt"
import csv, re, statistics as st, sys
out, t0 = sys.argv[1], float(sys.argv[2])
ev = {r[0]: float(r[1]) for r in csv.reader(open(out + "/events.csv"))}
a, b = ev["load_start"], ev["load_end"]
pings = []
for l in open(out + "/ping.txt"):
    m = re.match(r"\[(\d+\.\d+)\].*time=([\d.]+) ms", l)
    if m: pings.append((float(m.group(1)), float(m.group(2))))
sent = sum(1 for l in open(out + "/ping.txt") if "icmp_seq" in l)
q = list(csv.DictReader(open(out + "/queues.csv")))
def ph(t): return "idle" if t < a else ("load" if t <= b else "drain")
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
print("  info  phase | ping RTT median / max (ms) | answers | Tiny ogstun backlog max | Tiny N3 backlog max | gNB socket Recv-Q max")
for p in ("idle", "load", "drain"):
    rt = [v for t, v in pings if ph(t) == p]; qs = [x for x in q if ph(float(x["t"])) == p]
    mx = lambda k: max(int(x[k]) for x in qs) if qs else 0
    print("  info  %-5s | %8s / %-8s | %4d | %10d B | %10d B | %10d B" % (p, "%.1f" % st.median(rt) if rt else "-",
          "%.1f" % max(rt) if rt else "-", len(rt), mx("tiny_ogstun_backlog_b"), mx("tiny_n3_backlog_b"), mx("gnb_sock_recvq_b")))
d = lambda k: int(q[-1][k]) - int(q[0][k])
print("  info  drops during the run: Tiny ogstun %d, Tiny N3 %d, REDLAB UDP receive-buffer errors %d" % (
      d("tiny_ogstun_drops"), d("tiny_n3_drops"), d("udp_rcvbuf_errors")))
load = [v for t, v in pings if ph(t) == "load"]
r(len(q) >= 40, "%d queue samples" % len(q))
r(len(load) >= 10, "%d ping answers during the load" % len(load))
drain = [t for t, v in pings if ph(t) == "drain" and v < 100]
if drain: print("  info  RTT back under 100 ms %.1f s after the load stopped" % (min(drain) - b))
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
if load:
    mxq = max(max(int(x["tiny_ogstun_backlog_b"]), int(x["tiny_n3_backlog_b"]), int(x["gnb_sock_recvq_b"])) for x in q)
    print("FINDING: ping RTT under load median %.0f ms (idle %s ms); largest queue outside the gNB process %.2f MB"
          % (st.median(load), "%.1f" % st.median([v for t, v in pings if ph(t) == "idle"]) if any(ph(t) == "idle" for t, v in pings) else "-", mxq / 1e6))
    if st.median(load) > 500 and mxq < 2e6:
        print("FINDING: the delay is not in the core host's qdiscs or the gNB's socket buffer: the queue sits inside the gNB "
              "process (PDCP/RLC) (inference from the readings above)")
sys.exit(1 if fail else 0)
PY
  echo "  info  saved in ${OUT#$REPO/}"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  pod $POD, ping via oaitun_ue1, 10 s idle, UDP $RATE for $T s, 30 s drain; read-only queue samples"
         echo "RESULT (preview): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
run) run ;;
*) echo "MODE must be preview or run"; exit 1 ;;
esac
