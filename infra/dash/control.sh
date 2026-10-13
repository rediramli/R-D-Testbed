#!/usr/bin/env bash
# Stage 4b of the bench testbed: dashboard controls (gNB/UE start-stop, DL/UL speed test). Needs stage 4a (dash.sh).
# Run ON REDLAB from the repo root:   sudo MODE=preview bash infra/dash/control.sh
#   MODE=preview   show what would change (default, changes nothing)
#   MODE=apply     core: iperf3 servers on 10.45.0.1:5201/5202 (iperf-core.yaml). RAN: controller account + speed-test
#                  clients at 0 replicas (control-ran.yaml). Controller token -> core Secret fct-dash-ctl. Admin password
#                  -> core Secret fct-dash-admin (asked once, hidden; RESET_ADMIN=1 to change it). Restart the dashboard. Check.
#   MODE=check     account limits, controls enabled, one DL and one UL speed test started and stopped through the dashboard API
#   MODE=baseline  RUNS=3 DL and UL tests of DUR seconds each through the dashboard API; prints a table (stage 3 baseline)
#   MODE=remove    delete the speed-test clients, controller account, iperf servers and the two Secrets
# Safety: the controller may only scale oai-gnb, oai-nr-ue, speedtest-dl, speedtest-ul. Tokens and the password are never
# printed; the test reads the password from the core Secret into a variable only.
set -u
MODE=${MODE:-preview}; RUNS=${RUNS:-3}; DUR=${DUR:-20}
DIR=$(cd "$(dirname "$0")" && pwd)
KC="k3s kubectl"
USER_NAME=${SUDO_USER:-root}
URL=http://10.42.0.2:30880
CTL=system:serviceaccount:fct-dash:fct-dash-controller
asuser(){ sudo -u "$USER_NAME" -H "$@"; }
tiny(){ asuser ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  for f in control-ran.yaml iperf-core.yaml; do [ -f "$DIR/$f" ] && ok "$f ($(sha256sum "$DIR/$f" | cut -c1-16))" || bad "missing $DIR/$f"; done
  [ "$(grep -c -- '--bind-dev oaitun_ue1' "$DIR/control-ran.yaml")" = 2 ] && ! grep -q -- ' -B 10\.45' "$DIR/control-ran.yaml" \
    && ok "speed-test clients bind to oaitun_ue1 by device (no fixed UE address)" || bad "speed-test clients still use a fixed address"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers (stage 4a)" || bad "dashboard not answering (run dash.sh first)"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up: $(ip -4 -br addr show oaitun_ue1 | awk '{print $3}')" || bad "no UE tunnel"
  l=$(tiny "ss -Hltnp '( sport = :5201 or sport = :5202 )'" 2>/dev/null)
  if [ -z "$l" ]; then ok "ports 5201/5202 free on the core host"
  elif tiny 'k3s kubectl -n fct-dash get deploy iperf-server' >/dev/null 2>&1 && ! echo "$l" | awk '{print $4}' | grep -qv '^10\.45\.0\.1:'; then ok "ports 5201/5202 held by our iperf-server on 10.45.0.1 (re-apply)"
  else bad "ports 5201/5202 in use on the core host: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  tiny 'systemctl is-active iperf3 2>/dev/null' | grep -qx active && bad "iperf3.service is active on the core host (it would take the port)" || ok "no iperf3.service on the core host"
}

admin_key(){ tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d; }
api(){  # api ACTION -> HTTP code + message (key from the core Secret, not printed)
  curl -s -m 20 -X POST "$URL/api/control" -H "Content-Type: application/json" -H "X-Admin-Key: $KEY" \
    --data-binary "{\"action\":\"$1\"}" -w ' %{http_code}'; }
ready(){ $KC get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
wantrep(){ $KC get deploy "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null; }

# one_test DIR(dl|ul) -> prints "dir iperf_Mbps mac_goodput_Mbps mcs bler" from the last DUR-5 s, stops the test
one_test(){
  local d=$1 act=speed-$1 dep=speedtest-$1 r t0
  r=$(api "$act"); case "$r" in *" 200") ;; *) echo "ERR $d: dashboard refused $act: $r"; return 1;; esac
  for i in $(seq 1 40); do [ "$(ready $dep)" = 1 ] && break; sleep 1; done
  [ "$(ready $dep)" = 1 ] || { echo "ERR $d: $dep not ready"; api speed-stop >/dev/null; return 1; }
  sleep 6; t0=$(date +%s)   # skip TCP slow start
  sleep "$DUR"; t1=$(date +%s)
  ip=$($KC logs deploy/$dep --since=$((DUR))s 2>/dev/null | grep -E "sec .*bits/sec" | grep -vE "sender|receiver" \
       | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){v=$(i-1); u=$i; if(u ~ /^G/) v*=1000; if(u ~ /^K/) v/=1000; s+=v; n++}} END{if(n) printf "%.1f", s/n; else print "none"}')
  mac=$(curl -s -m 5 "$URL/api/history?seconds=$((DUR + 30))" | python3 -c '
import json, sys, statistics as st
d, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
rows = [r for r in json.load(sys.stdin)["rows"] if t0 <= r["t"] <= t1]
g = [r["goodputDl" if d == "dl" else "goodputUl"] for r in rows if r.get("goodputDl") is not None]
m = [r["mcsDl" if d == "dl" else "mcsUl"] for r in rows if r.get("mcsDl") is not None]
b = [r["blerDl" if d == "dl" else "blerUl"] for r in rows if r.get("blerDl") is not None]
f = lambda x, p: ("%." + str(p) + "f") % st.median(x) if x else "none"
print(f(g, 1), f(m, 0), f(b, 3), len(rows))' "$d" "$t0" "$t1")
  api speed-stop >/dev/null
  for i in $(seq 1 30); do [ -z "$(ready $dep)" ] || [ "$(ready $dep)" = 0 ] && break; sleep 1; done
  echo "$d $ip $mac"
}

check(){
  echo "== Checks"
  for n in oai-gnb oai-nr-ue speedtest-dl speedtest-ul; do
    [ "$($KC auth can-i patch deployments/$n --subresource=scale -n default --as=$CTL 2>/dev/null)" = yes ] || bad "controller may NOT scale $n"; done
  ok "controller may scale the four approved deployments"
  for q in "patch deployments/coredns --subresource=scale -n kube-system" "patch deployments/oai-gnb -n default" "create pods -n default" "get secrets -n default"; do
    [ "$($KC auth can-i $q --as=$CTL 2>/dev/null)" = no ] && ok "controller may not: $q" || bad "controller MAY: $q"; done
  tiny "ss -Hltn '( sport = :5201 or sport = :5202 )'" 2>/dev/null | awk '{print $4}' | sort | tr '\n' ' ' | grep -q "10.45.0.1:5201 10.45.0.1:5202" \
    && ok "iperf3 servers listen on 10.45.0.1:5201/5202 only" || bad "iperf3 servers not listening on 10.45.0.1:5201/5202"
  st=$(curl -s -m 8 $URL/api/state)
  echo "$st" | python3 -c 'import json,sys; c=json.load(sys.stdin)["controls"]; sys.exit(0 if c["enabled"] and len(c["targets"])==4 else 1)' 2>/dev/null \
    && ok "dashboard controls enabled, 4 targets visible" || bad "dashboard controls not enabled: $(echo "$st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["controls"]["reason"])' 2>/dev/null)"
  KEY=$(admin_key)
  [ -n "$KEY" ] || bad "cannot read the admin password Secret on the core"
  r=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $URL/api/control -H "X-Admin-Key: wrong-$RANDOM" --data-binary '{"action":"check"}')
  [ "$r" = 401 ] && ok "wrong admin password refused (401)" || bad "wrong admin password got HTTP $r"
  ueip=$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')
  rs0=$($KC get pods -l 'app in (oai-gnb,oai-nr-ue)' -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')
  DUR=10
  for d in dl ul; do
    out=$(one_test $d); echo "  info  $out"
    set -- $out
    case "$1" in dl|ul) ;; *) bad "$d speed test did not run"; continue;; esac
    [ "$2" != none ] && awk -v v="$2" 'BEGIN{exit !(v > 1)}' && ok "$d iperf3 through the tunnel: $2 Mbit/s" || bad "$d iperf3 shows no traffic ($2)"
    awk -v v="$3" 'BEGIN{exit !(v > 1)}' && ok "$d MAC goodput on the dashboard: $3 Mbit/s, median MCS $4" || bad "$d MAC goodput on the dashboard too low ($3)"
    [ "$(wantrep speedtest-$d)" = 0 ] && ok "$d test stopped (replicas 0)" || bad "$d test still scaled up"
  done
  [ "$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')" = "$ueip" ] && ok "UE kept its address ($ueip)" || bad "UE address changed during the tests"
  rs1=$($KC get pods -l 'app in (oai-gnb,oai-nr-ue)' -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}')
  [ "$rs0" = "$rs1" ] && ok "no gNB/UE restarts during the tests ($rs1)" || bad "gNB/UE restarted ($rs0 -> $rs1)"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  core (tiny): apply iperf-core.yaml (iperf-server, host network, 10.45.0.1:5201/5202)"
  echo "  RAN: apply control-ran.yaml (fct-dash-controller + token, Role scale 4 names, speedtest-dl/ul at 0 replicas)"
  echo "  core: Secret fct-dash-ctl (controller token), Secret fct-dash-admin (password asked here, hidden), restart fct-dash"
  echo "  undo: sudo MODE=remove bash infra/dash/control.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  tiny 'k3s kubectl apply -f -' < "$DIR/iperf-core.yaml"
  tiny 'k3s kubectl -n fct-dash rollout status deploy/iperf-server --timeout=180s'
  $KC apply -f "$DIR/control-ran.yaml"
  for i in $(seq 1 20); do [ -n "$($KC -n fct-dash get secret fct-dash-controller-token -o jsonpath='{.data.token}' 2>/dev/null)" ] && break; sleep 1; done
  $KC -n fct-dash get secret fct-dash-controller-token -o jsonpath='{.data.token}' | base64 -d \
    | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-ctl --from-file=token=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
    && echo "secret/fct-dash-ctl applied on the core (not shown)"
  if [ "${RESET_ADMIN:-0}" = 1 ] || ! tiny 'k3s kubectl -n fct-dash get secret fct-dash-admin' >/dev/null 2>&1; then
    # prompts go straight to the terminal, so a pipe on stdout/stderr cannot hide them
    printf "Choose the dashboard admin password (hidden): " >/dev/tty; read -r -s PW </dev/tty; echo >/dev/tty
    printf "Repeat it: " >/dev/tty; read -r -s PW2 </dev/tty; echo >/dev/tty
    [ -n "$PW" ] && [ "$PW" = "$PW2" ] || { echo "STOP: empty or not the same"; exit 1; }
    printf '%s' "$PW" | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-admin --from-file=password=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
      && echo "secret/fct-dash-admin applied on the core (not shown)"
    unset PW PW2
  fi
  tiny 'k3s kubectl -n fct-dash rollout restart deploy/fct-dash && k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=120s'
  sleep 8; F=0; check ;;
check) check ;;
baseline)
  KEY=$(admin_key); [ -n "$KEY" ] || { echo "STOP: cannot read the admin password Secret"; exit 1; }
  echo "== Baseline: $RUNS x DL and UL, $DUR s each (after 6 s warm-up), noise off, $(date -u +%FT%TZ)"
  echo "dir  iperf3_Mbps  MAC_goodput_Mbps  median_MCS  median_BLER  samples"
  for n in $(seq 1 "$RUNS"); do for d in dl ul; do one_test $d | awk '{printf "%-4s %11s %17s %11s %12s %8s\n", $1, $2, $3, $4, $5, $6}'; sleep 3; done; done ;;
remove)
  $KC -n default scale deploy speedtest-dl speedtest-ul --replicas=0 2>/dev/null
  $KC delete -f "$DIR/control-ran.yaml" --ignore-not-found
  tiny 'k3s kubectl -n fct-dash delete -f - --ignore-not-found; k3s kubectl -n fct-dash delete secret fct-dash-ctl fct-dash-admin --ignore-not-found; k3s kubectl -n fct-dash rollout restart deploy/fct-dash' < "$DIR/iperf-core.yaml" ;;
*) echo "MODE must be preview, apply, check, baseline or remove"; exit 1 ;;
esac
