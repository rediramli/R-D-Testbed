#!/usr/bin/env bash
# Regression test for the "iperf3 server is busy" bug. Runs on REDLAB (needs ssh to fct0172 and fct0173):
#   bash iperf-regress.sh
# For DL and then UL: start the speed test, kill the UE in the middle of it,
# bring the UE back, and require traffic to return WITHOUT restarting the server.
# On a failure it prints the server and client logs with timestamps.
FAILS=0
ran(){ ssh -o BatchMode=yes fct0173 "$@"; }
core(){ ssh -o BatchMode=yes fct0172 "$@"; }
gp(){  # gp DL|UL -> MAC goodput (simulated time) from the gNB statistics, as an integer
  ran 'kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null' \
    | grep -oE "goodput DL +[0-9.]+ UL +[0-9.]+" | head -1 | awk -v d=$1 '{print int(d=="DL" ? $3 : $5)}'; }
wait_gp(){ for i in $(seq 1 45); do [ "$(gp $1)" -gt $2 ] 2>/dev/null && return 0; sleep 2; done; return 1; }
tunnel(){ ran 'ip -4 addr show oaitun_ue1 2>/dev/null' | grep -q "inet "; }
srv_id(){ core 'kubectl -n fct-dash get pod -l app=iperf-server -o jsonpath="{.items[0].metadata.name} restarts={.items[0].status.containerStatuses[*].restartCount}"'; }
srv_conns(){ core "ss -Htn state established '( sport = :5201 or sport = :5202 )' | wc -l"; }
dump(){  # dump CONTAINER CLIENT_DEPLOYMENT
  echo "  --- server ($1) log, last 12 lines:"; core "kubectl -n fct-dash logs deploy/iperf-server -c $1 --timestamps --tail=12" | sed 's/^/    /'
  echo "  --- server sockets on 5201/5202:"; core "ss -tni '( sport = :5201 or sport = :5202 )'" | sed 's/^/    /'
  echo "  --- client ($2) log, last 8 lines:"; ran "kubectl logs deploy/$2 --timestamps --tail=8" | sed 's/^/    /'
}

SRV0=$(srv_id)
echo "iperf3 server: $SRV0 | established connections now: $(srv_conns)"
echo "server version: $(core 'kubectl -n fct-dash logs deploy/iperf-server -c dl | grep -m1 "^iperf"')"
ran 'kubectl scale deploy speedtest-dl speedtest-ul --replicas=0 >/dev/null'
if core 'for c in dl ul; do kubectl -n fct-dash logs deploy/iperf-server -c $c --tail=3; done' | grep -q "Address in use"; then
  echo "STOP: another process holds port 5201/5202 on FCT0172, our iperf3 server cannot listen. Listeners:"
  core "ss -Htlnp '( sport = :5201 or sport = :5202 )' 2>/dev/null; ps -eo pid,lstart,args | grep '[i]perf3'" | sed 's/^/  /'
  exit 1
fi

for t in "DL dl 50" "UL ul 25"; do
  set -- $t; DIR=$1; C=$2; DEP=speedtest-$2; MIN=$3
  echo; echo "== $DIR"
  echo "1. Speed test $DIR on the running UE"
  ran "kubectl scale deploy $DEP --replicas=1 >/dev/null"
  if wait_gp $DIR $MIN; then echo "  PASS goodput $DIR $(gp $DIR) Mbit/s"; else echo "  FAIL goodput $DIR only $(gp $DIR) Mbit/s"; FAILS=$((FAILS+1)); dump $C $DEP; fi
  echo "2. Kill the UE in the middle of the test, then bring it back  ($(date +%T))"
  ran 'kubectl scale deploy oai-nr-ue --replicas=0 >/dev/null; kubectl wait --for=delete pod -l app=oai-nr-ue --timeout=60s >/dev/null 2>&1'
  for i in $(seq 1 20); do tunnel || break; sleep 1; done
  ran 'kubectl scale deploy oai-nr-ue --replicas=1 >/dev/null'
  for i in $(seq 1 45); do tunnel && break; sleep 2; done
  tunnel && echo "  UE back ($(date +%T))" || echo "  UE NOT back"
  T0=$SECONDS
  echo "3. The speed test must recover without restarting the server"
  if wait_gp $DIR $MIN; then echo "  PASS goodput $DIR $(gp $DIR) Mbit/s, $((SECONDS-T0)) s after the UE came back"; else echo "  FAIL goodput $DIR only $(gp $DIR) Mbit/s"; FAILS=$((FAILS+1)); dump $C $DEP; fi
  echo "  watchdog restarts: client $(ran "kubectl logs deploy/$DEP" | grep -c watchdog), server $(core "kubectl -n fct-dash logs deploy/iperf-server -c $C" | grep -c watchdog)"
  ran "kubectl scale deploy $DEP --replicas=0 >/dev/null; kubectl wait --for=delete pod -l app=$DEP --timeout=30s >/dev/null 2>&1"
done

SRV1=$(srv_id)
echo; echo "iperf3 server at end: $SRV1"
[ "$SRV0" != "$SRV1" ] && { echo "  FAIL the server pod was restarted or replaced"; FAILS=$((FAILS+1)); }
echo; echo "HASIL: $([ $FAILS = 0 ] && echo PASS || echo FAIL) ($FAILS failed)"
