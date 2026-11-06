#!/usr/bin/env bash
# Experiment 16, stage S2: second cell = OCUDU gNB (own image, ZMQ) + OAI nrUE over ZMQ, one pod in namespace ran2 on
# tiny's k3s (10.42.0.2), attached to the same Open5GS core as the OAI cell. ZMQ virtual radio only.
# Run ON REDLAB from the repo root, as your user (no sudo; everything goes through ssh tiny + k3s kubectl):
#   MODE=preview bash infra/ran2/ran2.sh   show what would change (default, changes nothing)
#   MODE=apply   ConfigMaps + Secret ue2-sim (from tiny:~/testbed-secrets/ue2.env) + ocudu-cell.yaml, then check
#   MODE=check   tests only
#   MODE=restart delete the pod (ZMQ devices cannot reconnect: gNB and UE always restart together), then check
#   MODE=remove  delete namespace ran2 (the SIM file on tiny stays); needs CONFIRM=yes
# Prerequisites: image docker.io/fct/ocudu-gnb:26.10-zmq imported on tiny (Dockerfile.ocudu); subscriber ue2 in the core:
#   scp infra/core/open5gs.sh tiny:/tmp/ && ssh -t tiny 'sudo MODE=subscriber UE=ue2 bash /tmp/open5gs.sh'
# The SIM keys are never printed: they stay on tiny (file mode 600, Secret, in-memory volume, masked UE log).
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd)
NS=ran2; AMF=10.42.0.2; GNB_ID=3585
T(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
K(){ T "k3s kubectl -n $NS $*"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
FILES="gnb.yml nr-ue2.yaml.tpl uecap_ports1.xml ocudu-cell.yaml"
HASH=$(cd "$DIR" && cat $FILES | sha256sum | cut -c1-16)

pre(){
  echo "== Preconditions"
  T true 2>/dev/null && ok "ssh tiny" || { bad "cannot ssh tiny"; return; }
  T "k3s kubectl get nodes" 2>/dev/null | grep -q " Ready " && ok "tiny k3s node Ready" || bad "tiny k3s not ready"
  for f in $FILES; do [ -f "$DIR/$f" ] && ok "file $f" || bad "missing $DIR/$f"; done
  grep -q "device_driver: zmq" "$DIR/gnb.yml" && ok "gNB config: ZMQ radio only" || bad "gNB config is not ZMQ"
  ! grep -q "hostNetwork: true" "$DIR/ocudu-cell.yaml" && ok "pod without hostNetwork" || bad "hostNetwork found in ocudu-cell.yaml"
  T 'test -f ~/testbed-secrets/ue2.env && [ "$(stat -c %a ~/testbed-secrets/ue2.env)" = 600 ]' \
    && ok "SIM file tiny:~/testbed-secrets/ue2.env present, mode 600 (not shown)" \
    || bad "no tiny:~/testbed-secrets/ue2.env (run open5gs.sh MODE=subscriber UE=ue2 with sudo on tiny)"
  # a pod with imagePullPolicy Never is the reliable image test (node status lists only 50 images)
  T "k3s kubectl -n default run ran2-imgcheck --image=docker.io/fct/ocudu-gnb:26.10-zmq --image-pull-policy=Never --restart=Never --command -- true" >/dev/null 2>&1
  for i in $(seq 1 30); do ph=$(T "k3s kubectl -n default get pod ran2-imgcheck -o jsonpath='{.status.phase}{.status.containerStatuses[0].state.waiting.reason}'" 2>/dev/null)
    case "$ph" in Succeeded*|Failed*|*ErrImageNeverPull*) break;; esac; sleep 1; done
  T "k3s kubectl -n default delete pod ran2-imgcheck --wait=false" >/dev/null 2>&1
  case "$ph" in Succeeded*) ok "image docker.io/fct/ocudu-gnb:26.10-zmq present on tiny";; *) bad "OCUDU image not usable on tiny ($ph)";; esac
  T "k3s kubectl -n open5gs get pods --no-headers --field-selector=status.phase!=Succeeded" 2>/dev/null | awk '$3!="Running"{n++} END{exit n>0}' \
    && ok "core: all open5gs pods Running" || bad "core: not all open5gs pods Running"
}

amf_gnbs(){ T "curl -s -m 3 http://$AMF:9090/metrics" 2>/dev/null | awk '$1=="gnb"{print $2}'; }

check(){
  echo "== Checks"
  K "rollout status deploy/ocudu-cell --timeout=120s" >/dev/null 2>&1 && ok "ocudu-cell running" || bad "ocudu-cell not running"
  pod=$(K "get pod -l app=ocudu-cell -o jsonpath='{.items[0].metadata.name}'" 2>/dev/null)
  pip=$(K "get pod $pod -o jsonpath='{.status.podIP}'" 2>/dev/null)
  hn=$(K "get pod $pod -o jsonpath='{.spec.hostNetwork}'" 2>/dev/null)
  [ -n "$pod" ] && [ "$hn" != true ] && ok "pod $pod on pod IP $pip (no hostNetwork)" || bad "pod '$pod' hostNetwork='$hn'"
  rc=$(K "get pod $pod -o jsonpath='{.status.containerStatuses[*].restartCount}'" 2>/dev/null)
  [ "$(echo $rc | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')" = 0 ] && ok "no container restarts" || bad "container restarts: $rc (ZMQ needs MODE=restart)"
  K "logs $pod -c gnb" 2>/dev/null | grep -q "Available radio types: zmq" && ok "gNB: ZMQ radio available" || bad "gNB log: no ZMQ radio type"
  for i in $(seq 1 15); do K "logs $pod -c gnb" 2>/dev/null | grep -q "gNB started" && break; sleep 2; done   # about 5 s after start
  K "logs $pod -c gnb" 2>/dev/null | grep -q "gNB started" && ok "gNB started" || bad "gNB not started (see: logs -c gnb)"
  # NGAP: state, not log lines
  for i in $(seq 1 15); do T "ss -HnS state established src $AMF:38412 dst $pip" 2>/dev/null | grep -q . && break; sleep 2; done
  T "ss -HnS state established src $AMF:38412 dst $pip" 2>/dev/null | grep -q . \
    && ok "AMF side: SCTP association from $pip established (NGAP)" || bad "AMF side: no SCTP association from $pip"
  g=$(amf_gnbs); [ "${g:-0}" = 2 ] && ok "AMF metric gnb = 2 (OAI cell + OCUDU cell)" || bad "AMF metric gnb = '${g:-?}' (want 2)"
  # UE: tunnel, route to the UPF gateway through the radio, ping
  for i in $(seq 1 45); do ue=$(K "exec $pod -c ue -- ip -4 -br addr show oaitun_ue1" 2>/dev/null | awk '{print $3}'); case "$ue" in 10.45.*) break;; esac; sleep 2; done
  case "$ue" in 10.45.*) ok "UE registered, PDU session up: oaitun_ue1 $ue";; *) bad "no UE IP on oaitun_ue1 ('$ue')";; esac
  r=$(K "exec $pod -c ue -- ip route get 10.45.0.1" 2>/dev/null)
  echo "$r" | grep -q "dev oaitun_ue1" && ok "in the pod, 10.45.0.1 is routed via oaitun_ue1 (through the radio)" || bad "10.45.0.1 not via oaitun_ue1: $r"
  K "exec $pod -c ue -- ping -I oaitun_ue1 -c 3 -W 2 10.45.0.1" >/dev/null 2>&1 && ok "ping 10.45.0.1 through the UE tunnel" || bad "no ping to 10.45.0.1 through the UE tunnel"
  # host namespace on tiny must hold no 10.45 route other than ogstun
  T "ip -4 route | grep '^10\.45\.' | grep -v 'dev ogstun'" 2>/dev/null | grep -q . && bad "tiny host has a 10.45 route outside ogstun" || ok "tiny host: 10.45.0.0/16 only on ogstun"
  # listeners in the pod: ZMQ 4556/4557 and remote control 8001 on 127.0.0.1 only (/proc/net/tcp, hex)
  # ports in hex: 4556=11CC, 4557=11CD, 8001=1F41; 0100007F = 127.0.0.1 (tiny has mawk: no strtonum)
  L=$(K "exec $pod -c gnb -- cat /proc/net/tcp /proc/net/tcp6" 2>/dev/null | awk '$4=="0A"{split($2,a,":"); if (a[2]=="11CC"||a[2]=="11CD"||a[2]=="1F41") print a[1] ":" a[2]}' | sort -u | tr '\n' ' ')
  echo "$L" | grep -q ':11CC' && echo "$L" | grep -q ':1F41' && ! echo "$L" | tr ' ' '\n' | grep . | grep -qv '^0100007F:' \
    && ok "ZMQ 4556 and remote control 8001 listen on 127.0.0.1 only" || bad "listeners (hex addr:port): '$L' (want 0100007F:11CC and 0100007F:1F41 only)"
  # SIM masking: compare the UE log with the SIM values, on tiny (values never leave tiny)
  m=$(T "set -a; . ~/testbed-secrets/ue2.env; set +a; L=\$(k3s kubectl -n $NS logs $pod -c ue 2>/dev/null); n=0; for v in \"\$IMSI\" \"\$KI\" \"\$OPC\"; do printf '%s' \"\$L\" | grep -qiF -- \"\$v\" && n=\$((n+1)); done; echo \$n \$(printf '%s' \"\$L\" | grep -c 'IMSI=<IMSI masked>')")
  [ "${m%% *}" = 0 ] && ok "UE log contains none of the SIM values" || bad "UE log contains ${m%% *} SIM value(s)"
  [ "${m##* }" -ge 1 ] 2>/dev/null && ok "masked [SIM] line present in the UE log" || echo "  note  masked [SIM] line not found (log may have rotated)"
  T "k3s kubectl -n open5gs get pods --no-headers --field-selector=status.phase!=Succeeded" 2>/dev/null | awk '$3!="Running"{n++} END{exit n>0}' \
    && ok "core: all open5gs pods Running" || bad "core: not all open5gs pods Running"
  ss -HnS state established src 10.42.0.1 dst $AMF 2>/dev/null | grep -q ":38412" \
    && ok "OAI cell (REDLAB gNB): SCTP association to the AMF still established" || bad "OAI cell (REDLAB gNB): no SCTP association to the AMF"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

cm(){  # cm NAME FILE... -> ConfigMap manifest (JSON) for namespace ran2, built locally (no kubectl needed on REDLAB)
  python3 - "$NS" "$DIR" "$@" <<'PYEOF'
import json, os, sys
ns, d, name, files = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": ns},
                  "data": {f: open(os.path.join(d, f)).read() for f in files}}))
PYEOF
}

apply_all(){
  T "k3s kubectl create ns $NS --dry-run=client -o yaml | k3s kubectl apply -f -" >/dev/null && echo "  namespace $NS"
  T "k3s kubectl -n $NS create secret generic ue2-sim --from-env-file=\$HOME/testbed-secrets/ue2.env --dry-run=client -o yaml | k3s kubectl apply -f -" >/dev/null \
    && echo "  Secret ue2-sim (from tiny:~/testbed-secrets/ue2.env, not shown)"
  cm ran2-templates gnb.yml nr-ue2.yaml.tpl | T "k3s kubectl apply -f -" >/dev/null && echo "  ConfigMap ran2-templates"
  cm ran2-uecap uecap_ports1.xml | T "k3s kubectl apply -f -" >/dev/null && echo "  ConfigMap ran2-uecap"
  sed "s/CONFIG_HASH/$HASH/" "$DIR/ocudu-cell.yaml" | T "k3s kubectl apply -f -"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  namespace $NS; Secret ue2-sim from tiny:~/testbed-secrets/ue2.env (never shown); ConfigMaps ran2-templates, ran2-uecap"
  echo "  Deployment ocudu-cell (config hash $HASH): gNB ID $GNB_ID (0xe01), PCI 1, n78 20 MHz, ZMQ on the pod loopback, N2/N3 from the pod IP to $AMF"
  echo "  undo: MODE=remove CONFIRM=yes bash infra/ran2/ran2.sh" ;;
apply)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  apply_all; sleep 5; F=0; check ;;
restart)
  K "delete pod -l app=ocudu-cell --wait=true" >/dev/null; sleep 5; check ;;
check) check ;;
remove)
  [ "${CONFIRM:-}" = yes ] || { echo "This deletes namespace $NS (OCUDU cell, its Secret and ConfigMaps). Re-run with CONFIRM=yes"; exit 1; }
  T "k3s kubectl delete ns $NS --wait=true"; echo "kept: tiny:~/testbed-secrets/ue2.env and the ue2 subscriber in the core" ;;
*) echo "MODE must be preview, apply, check, restart or remove"; exit 1 ;;
esac
