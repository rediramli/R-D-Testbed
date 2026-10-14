#!/usr/bin/env bash
# Stage K1 of the bench testbed: switch on the Open5GS Prometheus metrics (the counters behind the core KPIs).
# Only the ConfigMaps of AMF, SMF, UPF, PCF and the Services of SMF, PCF change (infra/core/open5gs.yaml, generated).
# The NFs read their config at start, so they are restarted in dependency order: PCF, UPF, SMF, AMF. The gNB loses
# its NG link when the AMF restarts, so gNB and then UE are restarted afterwards (RAN on REDLAB).
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/core/metrics.sh
#   MODE=preview   kubectl diff of the new manifest (must touch only ConfigMaps/Services), ports free, nothing changed
#   MODE=apply     apply, ordered restarts, then check
#   MODE=check     NFs running, NRF registrations, PFCP, NGAP, metrics endpoints answer (names saved to a file), RAN back up
#   MODE=rollback  apply the committed manifest (git HEAD:infra/core/open5gs.yaml) with the same ordered restarts
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; CORE=10.42.0.2
OUT=$HOME/testbed-runs/core-metrics-$(date -u +%Y%m%dT%H%M%SZ).txt
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
tk(){ tiny "k3s kubectl -n open5gs $*"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  [ -f "$DIR/open5gs.yaml" ] && ok "open5gs.yaml ($(sha256sum "$DIR/open5gs.yaml" | cut -c1-16))" || bad "missing open5gs.yaml"
  [ "$(grep -c 'metrics:' "$DIR/open5gs.yaml")" = 4 ] && ok "metrics configured for 4 NFs (AMF, SMF, UPF, PCF)" || bad "metrics blocks in open5gs.yaml: $(grep -c 'metrics:' "$DIR/open5gs.yaml") (want 4)"
  d=$(tiny 'k3s kubectl diff -f -' < "$DIR/open5gs.yaml" 2>/dev/null)
  # kubectl diff prints one "--- /tmp/LIVE-<n>/<version>.<Kind>.<namespace>.<name>" header per changed object
  objs=$(echo "$d" | grep -E '^--- ' | awk '{print $2}' | sed 's#.*/##' | sed -E 's/^[a-z0-9]+\.(apps\.)?//; s/\.open5gs\./ /' | sort)
  echo "  info  objects that change: $(echo "$objs" | tr '\n' ';' | sed 's/;$//')"
  want="ConfigMap open5gs-amf
ConfigMap open5gs-pcf
ConfigMap open5gs-smf
ConfigMap open5gs-upf
Service open5gs-pcf-sbi
Service open5gs-smf-sbi"
  [ "$objs" = "$want" ] && ok "exactly the 4 ConfigMaps and 2 Services change, nothing else" \
    || bad "changed objects differ from the expected 4 ConfigMaps + 2 Services"
  echo "$d" | grep -E '^\+ ' | grep -vE '^\+\+\+' | sed 's/^/        /' | head -n 30
  for p in 9090 9091; do tiny "ss -Hltn '( sport = :$p )'" | grep -q . && bad "port $p already in use on the core host" || ok "port $p free on the core host"; done
  tiny 'k3s kubectl -n open5gs get deploy --no-headers' | awk '$2!="1/1"{b=1} END{exit b}' && ok "all core Deployments ready now" || bad "some core Deployments not ready before the change"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up before the change" || bad "UE tunnel down before the change"
}

roll(){  # roll NF -> restart one core NF and wait until it is ready
  tk rollout restart deploy/open5gs-$1 >/dev/null && tk rollout status deploy/open5gs-$1 --timeout=180s >/dev/null \
    && echo "  restarted open5gs-$1" || { echo "  STOP: open5gs-$1 did not come back"; exit 1; }
}
restart_all(){
  roll pcf; roll upf; sleep 3
  t=$(date -u +%Y-%m-%dT%H:%M:%SZ); roll smf
  for i in $(seq 1 30); do tk logs deploy/open5gs-smf --since-time=$t 2>/dev/null | grep -q "PFCP associated" && break; sleep 2; done
  tk logs deploy/open5gs-smf --since-time=$t 2>/dev/null | grep -q "PFCP associated" && echo "  SMF-UPF PFCP associated" || echo "  WARNING: no PFCP association yet"
  roll amf; sleep 5
  echo "  RAN: restart gNB (new NG Setup), then UE"
  $KC rollout restart deploy/oai-gnb >/dev/null; $KC rollout status deploy/oai-gnb --timeout=180s >/dev/null; sleep 10
  $KC rollout restart deploy/oai-nr-ue >/dev/null; $KC rollout status deploy/oai-nr-ue --timeout=180s >/dev/null
  for i in $(seq 1 60); do ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && break; sleep 2; done
}

check(){
  echo "== Checks"
  tiny 'k3s kubectl -n open5gs get deploy --no-headers' | awk '$2!="1/1"{print "  FAIL  " $1 " " $2; b=1} END{exit b}' && ok "12 core Deployments ready" || F=$((F+1))
  q=$(tiny "k3s kubectl run nrf-query-\$RANDOM -n open5gs --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c '
      for t in AMF SMF AUSF UDM UDR PCF BSF NSSF SCP; do
        n=\$(curl -s --http2-prior-knowledge -m 5 \"http://open5gs-nrf-sbi:7777/nnrf-nfm/v1/nf-instances?nf-type=\$t\" | grep -o \"nf-instances/[0-9a-f-]*\" | sort -u | wc -l)
        echo \"NRF \$t \$n\"; done
      for s in smf pcf; do echo \"== \$s\"; curl -s -m 5 http://open5gs-\$s-sbi:9090/metrics; done' 2>/dev/null")
  for t in AMF SMF AUSF UDM UDR PCF BSF NSSF SCP; do
    n=$(echo "$q" | awk -v t=$t '$1=="NRF" && $2==t {print $3}')
    [ "${n:-0}" = 1 ] && ok "NRF: $t registered once" || bad "NRF: $t registered ${n:-0} times (want 1)"; done
  tiny "ss -HlnS '( sport = :38412 )'" | grep -q "$CORE:38412" && ok "AMF NGAP on $CORE:38412" || bad "AMF NGAP not listening"
  tk logs deploy/open5gs-smf 2>/dev/null | grep -q "PFCP associated" && ok "SMF-UPF PFCP associated" || bad "no PFCP association in the SMF log"
  # metrics endpoints: AMF and UPF on the host address, SMF and PCF through their Services (fetched above)
  amf=$(curl -s -m 5 http://$CORE:9090/metrics); upf=$(curl -s -m 5 http://$CORE:9091/metrics)
  smf=$(echo "$q" | awk '/^== smf/{f=1;next} /^== /{f=0} f'); pcf=$(echo "$q" | awk '/^== pcf/{f=1;next} f')
  mkdir -p "$(dirname "$OUT")"; : > "$OUT"
  for nf in amf smf upf pcf; do
    m=${!nf}; n=$(echo "$m" | grep -c '^# TYPE')
    [ "$n" -gt 0 ] && ok "$nf metrics answer: $n metric families" || bad "$nf metrics endpoint gives nothing"
    { echo "== $nf"; echo "$m" | grep -E '^# (TYPE|HELP)'; } >> "$OUT"; done
  l=$(tiny "ss -Hltn '( sport = :9090 or sport = :9091 )'" | awk '{print $4}' | sort | tr '\n' ' ')
  [ "$l" = "$CORE:9090 $CORE:9091 " ] && ok "host metrics ports only on $CORE (AMF 9090, UPF 9091)" || bad "host listeners on 9090/9091: '$l'"
  echo "  info  metric names saved in $OUT"
  ss -HnS state established src 10.42.0.1 dst $CORE | grep -q ":38412" && ok "gNB: NG link (SCTP) to the new AMF" || bad "gNB has no NG link"
  ue=$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')
  case "$ue" in 10.45.*) ok "UE registered again: $ue";; *) bad "UE not registered ('$ue')";; esac
  ping -I oaitun_ue1 -c 3 -W 3 8.8.8.8 >/dev/null 2>&1 && ok "ping 8.8.8.8 through the UE tunnel" || bad "no ping through the UE tunnel"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  apply open5gs.yaml on the core (ConfigMaps of amf/smf/upf/pcf, Services of smf/pcf)"
  echo "  restart in order: open5gs-pcf, open5gs-upf, open5gs-smf (wait for PFCP), open5gs-amf; then oai-gnb, oai-nr-ue"
  echo "  the UE is down for about 1-2 minutes; undo: MODE=rollback bash infra/core/metrics.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  tiny 'k3s kubectl apply -f -' < "$DIR/open5gs.yaml" | grep -v unchanged
  restart_all
  F=0; check ;;
check) check ;;
rollback)
  git -C "$REPO" show HEAD:infra/core/open5gs.yaml | tiny 'k3s kubectl apply -f -' | grep -v unchanged
  restart_all; F=0; check ;;
*) echo "MODE must be preview, apply, check or rollback"; exit 1 ;;
esac
