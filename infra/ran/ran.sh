#!/usr/bin/env bash
# Stage 2b of the bench testbed: OAI gNB + nrUE (RF simulator only) on REDLAB's k3s, attached to the core on the P3 Tiny.
# Run ON REDLAB from the repo root:   sudo MODE=preview bash infra/ran/ran.sh
#   MODE=preview  show what would change (default; pulls images, changes nothing else)
#   MODE=apply    copy the test SIM from the core host if missing, create ConfigMaps + Secret, apply ran.yaml, then check
#   MODE=check    tests only: NG link, UE registered with an IP, pings through the UE tunnel, SIM masking,
#                 UE channel model (AWGN -100 dB) and telnet on 127.0.0.1:9090 only
#   MODE=remove   delete both Deployments, ConfigMaps and the Secret (the SIM file stays)
# Safety: --rfsim is checked in the manifest; the SIM keys are never printed (file mode 600, Secret, in-memory volume).
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd)
KC="k3s kubectl"
USER_NAME=${SUDO_USER:-root}; UHOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
SECRETS=$UHOME/testbed-secrets/ue1.env
AMF=10.42.0.2; GNB_IP=10.42.0.1
asuser(){ sudo -u "$USER_NAME" -H "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
tn(){  # tn "command" -> output of one OAI telnet command on the UE (127.0.0.1:9090)
python3 - "$1" <<'TNEOF'
import socket, sys, time
try:
    s = socket.create_connection(("127.0.0.1", 9090), 3)
except OSError as e:
    print("TELNET CONNECT FAILED:", e); sys.exit(0)
s.settimeout(1)
def drain():
    out = b""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            out += d
    except Exception:
        pass
    return out.decode(errors="replace")
time.sleep(0.4); drain()
s.sendall((sys.argv[1] + "\n").encode()); time.sleep(0.8)
print(drain().strip()); s.close()
TNEOF
}

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  $KC get nodes 2>/dev/null | grep -q " Ready " && ok "k3s (RAN) node Ready" || bad "k3s not ready (stage 2a)"
  for f in ran.yaml gnb.yaml nr-ue.yaml.tpl; do [ -f "$DIR/$f" ] && ok "$f ($(sha256sum "$DIR/$f" | cut -c1-16))" || bad "missing $DIR/$f"; done
  [ "$(grep -c -- '--rfsim ' "$DIR/ran.yaml")" -ge 2 ] && ok "--rfsim set for gNB and UE" || bad "--rfsim missing in ran.yaml"
  ip -4 -o addr | grep -q " $GNB_IP/" && ok "host has $GNB_IP" || bad "host has no $GNB_IP"
  lsmod | grep -q '^sctp' && ok "SCTP loaded" || bad "SCTP not loaded"
  ping -c1 -W2 $AMF >/dev/null && ok "core host $AMF reachable" || bad "core host $AMF not reachable"
  asuser ssh -o BatchMode=yes -o ConnectTimeout=5 tiny 'k3s kubectl -n open5gs get deploy open5gs-amf open5gs-upf -o name' >/dev/null 2>&1 \
    && ok "core: AMF and UPF deployed (ssh tiny)" || bad "cannot see AMF/UPF on the core (ssh tiny as $USER_NAME)"
  # only a socket on the gNB address or a wildcard collides (e.g. a local Open5GS SGW-U on 127.0.0.6:2152 does not)
  for p in 2152/u 4043/t; do port=${p%/*}; fl=${p#*/}
    line=$(ss -Hlnp$fl "( sport = :$port )" | awk -v ip="$GNB_IP" -v p=":$port" '$4==ip p || $4=="0.0.0.0"p || $4=="*"p || $4=="[::]"p' | head -1)
    if [ -z "$line" ]; then ok "host port $port free on $GNB_IP (other bindings: $(ss -Hln$fl "( sport = :$port )" | awk '{print $4}' | tr '\n' ' ')none else)"
    elif echo "$line" | grep -q '"nr-softmodem"'; then ok "host port $port held by our running gNB (re-apply)"
    else bad "host port $port in use: $(echo "$line" | awk '{print $4, $NF}')"; fi; done
  [ -f "$SECRETS" ] && ok "SIM file $SECRETS present (not shown)" || echo "  note  SIM file missing; apply copies it from the core host (ssh tiny), mode 600"
  for img in $(grep -oE 'image: [^ ]+' "$DIR/ran.yaml" | awk '{print $2}' | sort -u); do
    k3s crictl pull "$img" >/dev/null 2>&1 && ok "image available: $img" || bad "image NOT available: $img"; done
  line=$(ss -Hltnp "( sport = :9090 )" | head -1)
  if [ -z "$line" ]; then ok "port 9090 free (UE telnet)"
  elif echo "$line" | grep -q '"nr-uesoftmodem"'; then ok "port 9090 held by our UE telnet (re-apply)"
  else bad "port 9090 in use: $(echo "$line" | awk '{print $4, $NF}')"; fi
}

check(){
  echo "== Checks"
  for d in oai-gnb oai-nr-ue; do $KC rollout status deploy/$d --timeout=120s >/dev/null 2>&1 && ok "$d running" || bad "$d not running"; done
  $KC get deploy oai-gnb oai-nr-ue -o jsonpath='{.items[*].spec.template.spec.containers[0].args} {.items[*].spec.template.spec.containers[0].env}' | grep -q -- "--rfsim" \
    && ok "rfsim mode in the live Deployments" || bad "rfsim not found in the live Deployments"
  # State, not startup log lines: kubelet rotates the gNB log (~10 MB), so NGSetupResponse scrolls away.
  for i in $(seq 1 15); do ss -HnS state established src "$GNB_IP" dst "$AMF" | grep -q ":38412" && break; sleep 2; done
  ss -HnS state established src "$GNB_IP" dst "$AMF" | grep -q ":38412" \
    && ok "gNB: SCTP association $GNB_IP -> $AMF:38412 (NGAP) established" || bad "gNB: no established SCTP association to $AMF:38412"
  asuser ssh -o BatchMode=yes tiny "ss -HnS state established src $AMF:38412 dst $GNB_IP" 2>/dev/null | grep -q . \
    && ok "core AMF side: association from $GNB_IP established" || bad "core AMF side: no established association from $GNB_IP"
  for i in $(seq 1 30); do ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && break; sleep 2; done
  ue=$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')
  case "$ue" in 10.45.*) ok "UE registered, PDU session up: oaitun_ue1 $ue";; *) bad "no UE IP on oaitun_ue1 ('$ue')";; esac
  ping -I oaitun_ue1 -c 3 -W 2 10.45.0.1 >/dev/null 2>&1 && ok "ping UPF gateway 10.45.0.1 through the UE tunnel" || bad "no ping to 10.45.0.1 through the UE tunnel"
  ping -I oaitun_ue1 -c 3 -W 3 8.8.8.8 >/dev/null 2>&1 && ok "ping 8.8.8.8 through the UE tunnel (N6 NAT)" || bad "no ping to 8.8.8.8 through the UE tunnel"
  # SIM masking: scan every log file of the running UE pod on disk, rotated and gzipped ones included.
  $KC get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q "K masked" \
    && ok "UE Deployment runs the key-masking filter" || bad "UE Deployment has no key-masking filter"
  uid=$($KC get pod -l app=oai-nr-ue -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null)
  files=$(ls /var/log/pods/default_oai-nr-ue-*_"$uid"/nr-ue/* 2>/dev/null)
  [ -n "$uid" ] && [ -n "$files" ] && ok "UE log files on disk: $(echo "$files" | wc -l)" || bad "no UE log files found for pod uid '$uid'"
  for v in IMSI KI OPC; do val=$(grep -o "^$v=.*" "$SECRETS" 2>/dev/null | cut -d= -f2)
    [ -n "$val" ] || { bad "cannot read $v from $SECRETS"; continue; }
    n=$(for f in $files; do zgrep -qiF -- "$val" "$f" && echo "$f"; done | wc -l)
    [ "$n" = 0 ] && ok "no UE log file contains the SIM $v" || bad "$n UE log file(s) contain the SIM $v"; done
  n=$(for f in $files; do zgrep -q "UICC simulation: IMSI=<IMSI masked>.*Ki=<K masked>.*OPc=<OPc masked>" "$f" && echo "$f"; done | wc -l)
  [ "$n" -ge 1 ] && ok "masked [SIM] line present in the UE logs" || bad "masked [SIM] line not found in any UE log file"
  [ "$(ip -4 route show default | grep -c oaitun)" = 0 ] && ok "host default route not via the UE tunnel" || bad "default route goes through oaitun_ue1"
  a=$($KC get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}')
  echo "$a" | grep -q "options.*chanmod" && echo "$a" | grep -q "listenaddr 127.0.0.1" \
    && ok "UE runs with the channel model and telnet on 127.0.0.1" || bad "UE args without chanmod / telnet listenaddr"
  L=$(ss -Hltn "( sport = :9090 )" | awk '{print $4}' | sort -u | tr '\n' ' ')
  [ "$L" = "127.0.0.1:9090 " ] && ok "UE telnet listens on 127.0.0.1:9090 only" || bad "telnet listeners on 9090: '$L' (want only 127.0.0.1:9090)"
  cm=$(tn "channelmod show current")
  echo "$cm" | grep -q "rfsimu_channel_enB0" && echo "$cm" | grep -qi "AWGN" && echo "$cm" | grep -qE -- "-100" \
    && ok "UE channel model 0: rfsimu_channel_enB0, AWGN, noise -100 dB" || bad "channel model not as expected: $(echo "$cm" | head -4 | tr '\n' ' ')"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  SIM: $SECRETS (copied from tiny:~/testbed-secrets/ue1.env if missing; mode 600; never shown)"
  echo "  ConfigMaps oai-gnb-config (gnb.yaml), oai-ue-config (nr-ue.yaml.tpl); Secret ue1-sim"
  echo "  apply ran.yaml: oai-gnb, oai-nr-ue (default namespace, host network, rfsim only)"
  echo "  undo: sudo MODE=remove bash infra/ran/ran.sh" ;;
apply)
  pre
  if [ ! -f "$SECRETS" ]; then
    install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$(dirname "$SECRETS")"
    ( umask 077; asuser ssh -o BatchMode=yes tiny 'cat ~/testbed-secrets/ue1.env' > "$SECRETS" ) && chown "$USER_NAME:$USER_NAME" "$SECRETS"
    grep -qE '^IMSI=[0-9]{15}$' "$SECRETS" && grep -qE '^KI=[0-9a-f]{32}$' "$SECRETS" && grep -qE '^OPC=[0-9a-f]{32}$' "$SECRETS" \
      && echo "  SIM copied from the core host (not shown)" || { echo "STOP: SIM copy incomplete"; rm -f "$SECRETS"; exit 1; }
  fi
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  $KC create configmap oai-gnb-config --from-file=gnb.yaml="$DIR/gnb.yaml" --dry-run=client -o yaml | $KC apply -f -
  $KC create configmap oai-ue-config --from-file=nr-ue.yaml.tpl="$DIR/nr-ue.yaml.tpl" --dry-run=client -o yaml | $KC apply -f -
  $KC create secret generic ue1-sim --from-env-file="$SECRETS" --dry-run=client -o yaml | $KC apply -f - >/dev/null && echo "secret/ue1-sim applied"
  GH=$(sha256sum "$DIR/gnb.yaml" | cut -c1-12); UH=$(sha256sum "$DIR/nr-ue.yaml.tpl" | cut -c1-12)
  sed -e "s/GNB_CONFIG_HASH/$GH/" -e "s/UE_CONFIG_HASH/$UH/" "$DIR/ran.yaml" | $KC apply -f -
  $KC rollout status deploy/oai-gnb --timeout=180s; sleep 10
  $KC rollout status deploy/oai-nr-ue --timeout=180s
  # The UE must attach to the gNB that is running now: if the gNB pod is newer, restart the UE once.
  gs=$($KC get pods -l app=oai-gnb -o jsonpath='{.items[0].status.startTime}'); us=$($KC get pods -l app=oai-nr-ue -o jsonpath='{.items[0].status.startTime}')
  if [[ "$us" < "$gs" ]]; then echo "UE started before the current gNB: restarting the UE"
    $KC rollout restart deploy/oai-nr-ue; $KC rollout status deploy/oai-nr-ue --timeout=180s; sleep 10; fi
  F=0; check ;;
check) check ;;
remove)
  $KC delete -f "$DIR/ran.yaml" --ignore-not-found
  $KC delete configmap oai-gnb-config oai-ue-config --ignore-not-found
  $KC delete secret ue1-sim --ignore-not-found
  echo "kept: $SECRETS" ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
