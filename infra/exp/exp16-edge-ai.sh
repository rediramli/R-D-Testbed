#!/usr/bin/env bash
# Experiment 16 on the bench: edge AI over 5G (MEC). A UE sends camera frames through the 5G link (UE -> gNB -> UPF on
# the core host -> bench LAN) to an object-detection server (YOLO, TensorRT FP16) on the Jetson (10.42.0.3) and waits
# for the answer. For every frame: total latency, server time (decode + inference) and the rest (the network both ways).
# Cells: the bench LAN directly (reference, no 5G), then for each DL channel preset: no other traffic, and a UDP DL flow
# above the link rate in the background (does the deep DL buffer seen in Experiment 1 delay the answers?).
# rfsim only. Nothing on the core changes. On the Jetson only the temporary container edge-yolo runs (started with --rm,
# stopped at the end); other containers (open-webui) and folders are not touched.
# Client: temporary pod exp16-edge (alpine + python3 + iperf3, host network); 5G frames bound to oaitun_ue1.
# Always ends with noise Off, the pod deleted and edge-yolo stopped.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=run bash infra/exp/exp16-edge-ai.sh
#   MODE=preview  preconditions (bench, Jetson over ssh, model, port, GPU idle); changes nothing
#   MODE=run      about 20 min with the defaults; results in docs/experiments/data/bench-edge-<UTC time>/
#   MODE=stop     stop edge-yolo on the Jetson, delete the pod, noise Off (if anything was left behind)
#   MODE=analyze OUT=docs/experiments/data/<run>   recompute the summary of a finished run
# One-time setup: key-based ssh from REDLAB to the Jetson (ssh-copy-id jetson@10.42.0.3).
# Options: PRESETS="off clean moderate poor" LOADS="none udp" SIZES=360,720,1080 N=100 MAXS=60 (s per size)
#          SETTLE=15 (s after a preset change) FILL=12 (s of background UDP before measuring) RATE=200M
# Do not use the dashboard controls while it runs.
set -u
MODE=${MODE:-preview}; PRESETS=${PRESETS:-off clean moderate poor}; LOADS=${LOADS:-none udp}
SIZES=${SIZES:-360,720,1080}; N=${N:-100}; MAXS=${MAXS:-60}; SETTLE=${SETTLE:-15}; FILL=${FILL:-12}; RATE=${RATE:-200M}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092; POD=exp16-edge
JET=jetson@10.42.0.3; EDGE=http://10.42.0.3:8500; CT=edge-yolo; MODEL=yolo11n.engine
IMG=ultralytics/ultralytics@sha256:802ab8f148cd494ba2e7ed1b1704f74b174cc26ce7e76250b025fc96277fdff3
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
jet(){ ssh -o BatchMode=yes -o ConnectTimeout=5 "$JET" "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
KEY=""; api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
                 -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }

pre(){
  echo "== Preconditions (bench)"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  $KC get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--rfsim' \
    && ok "UE runs with --rfsim" || bad "UE without --rfsim: STOP"
  r=$($KC get deploy speedtest-dl speedtest-ul -o jsonpath='{.items[*].spec.replicas}' 2>/dev/null)
  [ "$r" = "0 0" ] && ok "dashboard speed tests stopped" || bad "dashboard speed tests running (replicas '$r'): press Stop"
  $KC get pod $POD >/dev/null 2>&1 && bad "pod $POD already exists (MODE=stop)" || ok "no leftover pod $POD"
  tiny "ss -Hltn '( sport = :5202 )'" 2>/dev/null | grep -q "10.45.0.1:5202" && ok "iperf3 server on 10.45.0.1:5202 (core)" \
    || bad "no iperf3 server on 10.45.0.1:5202"
  ping -I oaitun_ue1 -c 2 -W 3 10.42.0.3 >/dev/null 2>&1 && ok "Jetson reachable through the 5G tunnel" \
    || bad "Jetson not reachable through oaitun_ue1"
  echo "== Preconditions (Jetson $JET)"
  if ! jet true 2>/dev/null; then bad "no key-based ssh to $JET (run once: ssh-copy-id $JET)"; return; fi
  ok "ssh to the Jetson"
  jet "docker image inspect $IMG >/dev/null 2>&1" && ok "YOLO image present (pinned digest)" || bad "image $IMG not on the Jetson"
  jet "test -s edge/$MODEL && test -s edge/bus.jpg" && ok "edge/$MODEL and edge/bus.jpg present" || bad "edge/$MODEL or edge/bus.jpg missing"
  jet "docker ps -a --format '{{.Names}}' | grep -qx $CT" && bad "container $CT already exists (MODE=stop)" || ok "no leftover container $CT"
  jet "ss -Hltn '( sport = :8500 )' | grep -q ." && bad "port 8500 busy on the Jetson" || ok "port 8500 free on the Jetson"
  g=$(jet "timeout 3 tegrastats --interval 1000" 2>/dev/null | sed -n 's/.*GR3D_FREQ \([0-9]*\)%.*/\1/p' | sort -n | tail -1)
  [ -n "$g" ] && [ "$g" -le 20 ] && ok "Jetson GPU idle (GR3D ${g} %)" || bad "Jetson GPU busy or unknown (GR3D '${g}' %): another job is running"
}

stop(){
  jet "docker stop $CT >/dev/null 2>&1; true" 2>/dev/null
  $KC delete pod $POD --wait=false >/dev/null 2>&1
  [ -n "$KEY" ] && api noise-off >/dev/null
}

analyze(){
  python3 - "$OUT" <<'PY' | tee "$OUT/summary.txt"; [ "${PIPESTATUS[0]}" = 0 ] || F=$((F+1))
import csv, glob, json, os, statistics as st, sys
out = sys.argv[1]
rows = [r for r in csv.reader(l for l in open(out + "/frames.csv") if not l.startswith("#")) if len(r) >= 11 and r[0] != "label"]
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
q = lambda v, p: sorted(v)[min(len(v) - 1, int(p * len(v)))] if v else None
f = lambda v, d=1: "-" if v is None else ("%." + str(d) + "f") % v
cells, res = [], {}
for x in rows:
    k = (x[0], x[1])
    if k not in res: cells.append(k); res[k] = []
    res[k].append(x)
radio = {}
for p in glob.glob(out + "/history-*.json"):
    lab = os.path.basename(p)[8:-5]
    h = json.load(open(p)).get("rows", [])
    m = [y["mcsDl"] for y in h if y.get("mcsDl") is not None]; s = [y["sinrUe"] for y in h if y.get("sinrUe") is not None]
    radio[lab] = (st.median(s) if s else None, st.median(m) if m else None, sum(1 for y in h if y.get("oos")))
print("  info  cell                  size | frames ok/sent | total median p90 p99 (ms) | server  inference | network median | detections | SINR MCS")
summ = {}
for k in cells:
    v = res[k]; okv = [y for y in v if y[4] == "1"]
    tot = [float(y[5]) for y in okv]; srv = [float(y[6]) for y in okv]; inf = [float(y[7]) for y in okv]; net = [float(y[8]) for y in okv]
    dets = sorted({y[9] for y in okv})
    lab = k[0]; rd = radio.get(lab.replace("|", "-"), (None, None, 0))
    summ[k] = dict(n=len(okv), sent=len(v), tot=st.median(tot) if tot else None, p90=q(tot, .9), p99=q(tot, .99),
                   srv=st.median(srv) if srv else None, inf=st.median(inf) if inf else None, net=st.median(net) if net else None)
    s = summ[k]
    print("  info  %-20s %5s | %4d/%-4d | %7s %7s %7s | %6s %6s | %7s | %-6s | %s %s" % (lab, k[1], s["n"], s["sent"], f(s["tot"]),
          f(s["p90"]), f(s["p99"]), f(s["srv"]), f(s["inf"]), f(s["net"]), "/".join(dets), f(rd[0]), f(rd[1], 0)))
    required = not lab.endswith("|udp")
    if required:
        r(s["n"] >= 20, "%s %s: %d answered frames (want >= 20)" % (lab, k[1], s["n"]))
        r(len(dets) == 1, "%s %s: the same detection count on every frame (%s)" % (lab, k[1], "/".join(dets) or "none"))
    else:
        print("  info  %s %s: %d of %d frames answered under background load (timeouts are data, not a failure)" % (lab, k[1], s["n"], s["sent"]))
oos = sum(v[2] for v in radio.values()); r(oos == 0, "out-of-sync samples during the run: %d" % oos)
try:
    u = json.load(open(out + "/ue.json")); r(u["before"] == u["after"], "UE kept its tunnel address (%s -> %s)" % (u["before"], u["after"]))
except Exception as e:
    r(False, "UE address record missing (%s)" % e)
print("RESULT:", "PASS" if fail == 0 else "FAIL (%d)" % fail)
g = lambda lab, size: summ.get((lab, size))
for size in ("720", "1080"):
    a, b = g("off|none", size), g("lan|none", size)
    if a and a["tot"]:
        print("FINDING: %sp, 5G noise off: total %.1f ms, of which inference %.1f ms (%.0f %%) and server %.1f ms; network %.1f ms"
              % (size, a["tot"], a["inf"], 100 * a["inf"] / a["tot"], a["srv"], a["net"]))
    if a and b and a["net"] and b["net"]:
        print("FINDING: %sp network: 5G %.1f ms vs bench LAN %.1f ms (5G adds %.1f ms)" % (size, a["net"], b["net"], a["net"] - b["net"]))
    c = g("poor|none", size)
    if a and c and a["tot"] and c["tot"]:
        print("FINDING: %sp total: Poor %.1f ms vs Off %.1f ms (x %.1f)" % (size, c["tot"], a["tot"], c["tot"] / a["tot"]))
    d = g("off|udp", size)
    if a and d and d["tot"]:
        print("FINDING: %sp with background UDP at Off: total median %.0f ms, p99 %s ms, answered %d/%d (no load: %.1f ms)"
              % (size, d["tot"], f(d["p99"], 0), d["n"], d["sent"], a["tot"]))
sys.exit(1 if fail else 0)
PY
}

run(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  OUT="$REPO/docs/experiments/data/bench-edge-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  [ -n "$KEY" ] || { bad "dashboard admin key not readable"; exit 1; }
  trap 'stop' EXIT
  ue0=$(ip -4 -br addr show oaitun_ue1 | awk '{print $3}')
  echo "== Start the MEC server on the Jetson"
  scp -q -o BatchMode=yes "$REPO/infra/edge/edge_server.py" "$JET:edge/edge_server.py" || { bad "copy edge_server.py"; exit 1; }
  jet "docker run -d --rm --name $CT --runtime nvidia --ipc=host --network host -v \$HOME/edge:/work -w /work $IMG \
       python3 /work/edge_server.py --port 8500 --model $MODEL --image bus.jpg" >/dev/null || { bad "start $CT"; exit 1; }
  for i in $(seq 1 90); do curl -s -m 2 $EDGE/health | grep -q '"ok": true' && break; sleep 2; done
  curl -s -m 2 $EDGE/health | grep -q '"ok": true' && ok "MEC server ready ($(curl -s -m 2 $EDGE/health))" || { bad "MEC server not ready"; exit 1; }
  echo "== Client pod"
  $KC run $POD --restart=Never --image=docker.io/library/alpine:3.20 \
    --overrides='{"apiVersion":"v1","spec":{"hostNetwork":true,"terminationGracePeriodSeconds":1}}' \
    --command -- sh -c 'apk add --no-cache python3 iperf3 >/dev/null && touch /tmp/ready && sleep 7200' >/dev/null
  for i in $(seq 1 60); do $KC exec $POD -- test -f /tmp/ready 2>/dev/null && break; sleep 2; done
  $KC exec $POD -- test -f /tmp/ready 2>/dev/null && ok "client pod ready" || { bad "client pod not ready"; exit 1; }
  echo "label,size,i,bytes,ok,total_ms,server_ms,inf_ms,net_ms,n_det,t_wall" > "$OUT/frames.csv"
  echo "cell,start,end" > "$OUT/cells.csv"
  cell(){  # cell LABEL DEV
    local ts=$(date +%s); echo "  info  cell $1 ..."
    $KC exec -i $POD -- python3 - --dev "$2" --sizes "$SIZES" --n "$N" --max-s "$MAXS" --label "$1" \
      < "$REPO/infra/edge/edge_client.py" >> "$OUT/frames.csv"
    local te=$(date +%s); echo "$1,$ts,$te" >> "$OUT/cells.csv"
    [ "$2" = "" ] || curl -s -m 20 "$URL/api/history?seconds=$((te - ts + 5))" > "$OUT/history-${1/|/-}.json"
    echo "  info  cell $1 done ($((te - ts)) s, $(grep -c "^$1," "$OUT/frames.csv") frames)"
  }
  echo "== Reference: bench LAN, no 5G"
  cell "lan|none" ""
  for p in $PRESETS; do
    echo "== Channel $p"
    c=$(api "noise-$p"); [ "$c" = 200 ] || { bad "dashboard refused noise-$p (HTTP $c)"; break; }
    sleep "$SETTLE"
    for l in $LOADS; do
      if [ "$l" = udp ]; then
        $KC exec $POD -- sh -c "nohup iperf3 -c 10.45.0.1 -p 5202 -R -u -b $RATE -t 3600 --bind-dev oaitun_ue1 >/dev/null 2>&1 &"
        sleep "$FILL"
        $KC exec $POD -- pgrep iperf3 >/dev/null 2>&1 && echo "  info  background UDP $RATE running" \
          || echo "  WARNING  background UDP not running: the $p|udp cell measures without load"
        cell "$p|udp" oaitun_ue1
        $KC exec $POD -- pkill iperf3 >/dev/null 2>&1; sleep 8   # the core iperf3 server restarts after each test
      else
        cell "$p|none" oaitun_ue1
      fi
    done
  done
  api noise-off >/dev/null; sleep 5
  ue1=$(ip -4 -br addr show oaitun_ue1 | awk '{print $3}')
  printf '{"before": "%s", "after": "%s"}\n' "$ue0" "$ue1" > "$OUT/ue.json"
  jet "docker logs $CT 2>&1 | tail -3" > "$OUT/server-log.txt" 2>/dev/null
  stop; trap - EXIT
  analyze
  for f in "$OUT"/history-*.json; do python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); d['rows']=[{k:r.get(k) for k in ('t','cqi','mcsDl','blerDl','goodputDl','sinrUe','oos')} for r in d.get('rows',[])]; json.dump(d,open(sys.argv[1],'w'))" "$f"; done
  [ "$(noise_db)" = "-100.0" ] && echo "  info  noise back at -100 dB" || echo "  WARNING  noise not back at -100 dB: $(noise_db)"
  echo "  info  saved in ${OUT#$REPO/}"
  echo "RESULT (run): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview) pre; echo "== Would do"
         echo "  start $CT on the Jetson ($MODEL), pod $POD; cells: lan|none, then for each of [$PRESETS] x [$LOADS];"
         echo "  sizes $SIZES, up to $N frames or $MAXS s per size; then stop $CT, delete the pod, noise Off"
         echo "RESULT (preview): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
run) run ;;
stop) KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
      stop; echo "  info  $CT stopped, pod deleted, noise Off requested" ;;
analyze) F=0; OUT=${OUT:?set OUT=docs/experiments/data/<run folder>}; case $OUT in /*) ;; *) OUT=$REPO/$OUT ;; esac
         analyze; echo "RESULT (analyze): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
*) echo "MODE must be preview, run, stop or analyze"; exit 1 ;;
esac
