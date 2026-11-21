#!/usr/bin/env bash
# Experiment 12 (stage R1): FlexRIC nearRT-RIC + KPM monitor xApp on REDLAB, E2 to the OAI gNB, KPM on the dashboard.
# Needs: RAN with e2_agent in infra/ran/gnb.yaml (sudo MODE=apply bash infra/ran/ran.sh), dashboard (dash.sh), Prometheus (prom.sh).
# Run ON REDLAB from the repo root:
#   sudo MODE=image bash infra/dash/ric.sh   build docker.io/fct/flexric:d7a71285-e2ap3 (infra/ric/Dockerfile.flexric) with docker
#                                            as the login user and import it into k3s (the only step that needs sudo)
#   MODE=preview  preconditions, what would change; changes nothing
#   MODE=apply    token Secret (RAN) if missing, ConfigMap flexric-ric-app, ric-ran.yaml, copy the token to the core Secret
#                 fct-dash-ric, restart the dashboard and Prometheus so they mount it, then check
#   MODE=check    RIC on 127.0.0.1:36421/36422 only, one RIC on the host, E2 SETUP from the gNB accepted (KPM + RC),
#                 relay on 10.42.0.1:8095 only with the token enforced, KPM indications flowing, a DL speed test through
#                 the dashboard raises the KPM DL throughput, dashboard and Prometheus show the E2 state and KPM values
#   After the RIC pod restarts (apply with a change, remove + apply) restart the gNB, then the UE: the gNB re-connects
#   SCTP but does not repeat E2 SETUP, so the new RIC has no E2 node.
#   MODE=remove   delete the RIC pod, its ConfigMap, the token Secret and the core copy (keeps the image; the gNB keeps
#                 running, its E2 agent just has no RIC)
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; RAN=10.42.0.1; PORT=8095; URL=http://10.42.0.2:30880; RELAY=http://$RAN:$PORT
IMG=docker.io/fct/flexric:d7a71285-e2ap3
USER_NAME=${SUDO_USER:-$(id -un)}
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
tok(){ $KC -n fct-dash get secret ric-relay-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d; }
st(){ curl -s -m 5 -H "X-Relay-Token: $(tok)" "$RELAY/status"; }
jq_(){ python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
sctp_eps(){ awk 'NR>1 && ($6=="36421" || $6=="36422") {print $6, $9, $10}' /proc/net/sctp/eps; }   # LPORT LADDRS
ric_pids(){ pgrep -x nearRT-RIC | tr '\n' ' '; }
pod_ric_pid(){ local p; for p in $(pgrep -x nearRT-RIC); do grep -q "kubepods" /proc/$p/cgroup 2>/dev/null && echo "$p"; done; }

pre(){
  echo "== Preconditions"
  for f in "$DIR/ric-ran.yaml" "$REPO/infra/ric/ric-relay.py" "$REPO/infra/ric/flexric.conf"; do
    [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  $KC get ns fct-dash >/dev/null 2>&1 && ok "namespace fct-dash on the RAN cluster" || bad "namespace fct-dash missing"
  $KC -n fct-dash get pods -o name >/dev/null 2>&1 || bad "kubectl cannot read fct-dash (run as the login user with the k3s kubeconfig)"
  # crictl needs root; a throwaway pod with imagePullPolicy Never tells whether k3s has the image (as ran2.sh does)
  $KC -n fct-dash delete pod ric-imgcheck --ignore-not-found >/dev/null 2>&1
  $KC run ric-imgcheck -n fct-dash --image=$IMG --image-pull-policy=Never --restart=Never \
      --overrides='{"spec":{"automountServiceAccountToken":false}}' --command -- true >/dev/null 2>&1
  for i in $(seq 1 15); do ph=$($KC -n fct-dash get pod ric-imgcheck -o jsonpath='{.status.phase}' 2>/dev/null); [ "$ph" = Succeeded ] && break; sleep 1; done
  [ "$ph" = Succeeded ] && ok "image $IMG present in k3s" || bad "image $IMG not in k3s ($ph): sudo MODE=image bash infra/dash/ric.sh"
  $KC -n fct-dash delete pod ric-imgcheck --ignore-not-found >/dev/null 2>&1
  $KC -n default get cm oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | grep -A1 '^e2_agent:' | grep -q 'near_ric_ip_addr: "127.0.0.1"' \
    && ok "live gNB config has e2_agent -> 127.0.0.1" || bad "live gNB config has no e2_agent (infra/ran/gnb.yaml, ran.sh apply)"
  $KC -n default get deploy oai-gnb -o jsonpath='{.status.readyReplicas}' | grep -qx 1 && ok "gNB running" || bad "gNB not running"
  # A second nearRT-RIC on a busy port does not exit: its bind fails and its SCTP sockets end up on 0.0.0.0 (ephemeral ports).
  mine=$(pod_ric_pid); others=$(for p in $(pgrep -x nearRT-RIC); do [ "$p" = "$mine" ] || echo -n "$p "; done)
  [ -z "$others" ] && ok "no nearRT-RIC outside the pod on this host" \
    || bad "nearRT-RIC running outside the pod (pid $others): stop it first (Ctrl-C in its terminal)"
  l=$(ss -Hltn "( sport = :$PORT )")
  if [ -z "$l" ]; then ok "port $PORT free on REDLAB"
  elif $KC -n fct-dash get deploy flexric-ric >/dev/null 2>&1; then ok "port $PORT held by our relay (re-apply)"
  else bad "port $PORT in use: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
}

check(){
  echo "== Checks"
  $KC -n fct-dash rollout status deploy/flexric-ric --timeout=120s >/dev/null 2>&1 && ok "flexric-ric running (RIC + KPM relay)" || bad "flexric-ric not running"
  [ "$($KC -n fct-dash get deploy flexric-ric -o jsonpath='{.spec.template.spec.containers[0].image}')" = "$IMG" ] && ok "image $IMG" || bad "unexpected image"
  pids=$(ric_pids); n=$(echo "$pids" | wc -w); mine=$(pod_ric_pid)
  [ "$n" = 1 ] && [ -n "$mine" ] && ok "exactly one nearRT-RIC on REDLAB, in the pod (pid $mine)" || bad "nearRT-RIC processes: '$pids' (pod: '$mine')"
  e=$(sctp_eps | sort | tr '\n' ';')
  [ "$e" = "36421 127.0.0.1 ;36422 127.0.0.1 ;" ] && ok "SCTP endpoints: E2 36421 and E42 36422 on 127.0.0.1 only" || bad "SCTP endpoints on 36421/36422: '$e'"
  for i in $(seq 1 30); do a=$(st | jq_ 'd["e2"]["associations"]'); [ "${a:-0}" -ge 1 ] && break; sleep 2; done
  [ "${a:-0}" -ge 1 ] && ok "E2: $a SCTP association(s) on 127.0.0.1:36421 established" \
    || bad "no E2 association: the gNB E2 agent connects at start; restart the gNB (sudo MODE=apply bash infra/ran/ran.sh after scaling oai-gnb to 0, or the dashboard gNB Stop/Start)"
  rl=$($KC -n fct-dash logs deploy/flexric-ric -c ric 2>/dev/null)
  # The OAI E2 agent re-connects SCTP to a restarted RIC but does not repeat E2 SETUP (bench, 2026-11-20): the new RIC
  # then has 0 E2 nodes and drops the old subscriptions' indications. Only a gNB restart repeats E2 SETUP.
  echo "$rl" | grep -q "E2 SETUP-REQUEST rx from PLMN   1.70" && ok "RIC log: E2 SETUP-REQUEST from the gNB (PLMN 001/70)" \
    || bad "RIC log: no E2 SETUP-REQUEST from PLMN 1.70 since the RIC started$(echo "$rl" | grep -q 'but no xApp associated' && echo ' (gNB re-connected without E2 SETUP: restart the gNB, then the UE)')"
  echo "$rl" | grep -q "Accepting RAN function ID 2 with def = ORAN-E2SM-KPM" && echo "$rl" | grep -q "Accepting RAN function ID 3 with def = ORAN-E2SM-RC" \
    && ok "RIC accepted the gNB's KPM (2) and RC (3) RAN functions" || bad "RIC did not accept KPM and RC"
  $KC -n default logs deploy/oai-gnb 2>/dev/null | grep -q "E2 AGENT\]: nearRT-RIC IP Address = 127.0.0.1, PORT = 36421" \
    && ok "gNB log: E2 agent towards 127.0.0.1:36421" || echo "  info  gNB E2 agent line not in the current gNB log (log rotated?)"
  ls=$(ss -Hltn "( sport = :$PORT )" | awk '{print $4}' | tr '\n' ' ')
  [ "$ls" = "$RAN:$PORT " ] && ok "relay listens on $RAN:$PORT only" || bad "listeners on port $PORT: '$ls'"
  others=$(ip -4 -o addr | awk '{print $4}' | cut -d/ -f1 | grep -vE "^(127\.|$RAN$)" | tr '\n' ' ')
  open=""; for ip in $others; do curl -s -m 3 -o /dev/null "http://$ip:$PORT/healthz" && open="$open $ip"; done
  [ -z "$open" ] && ok "relay not answering on REDLAB's other addresses" || bad "relay also answers on:$open"
  for p in status metrics; do
    c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' $RELAY/$p); [ "$c" = 401 ] && ok "GET /$p without token refused (401)" || bad "GET /$p without token: HTTP $c"
    c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -H "X-Relay-Token: wrong-$RANDOM" $RELAY/$p); [ "$c" = 401 ] && ok "GET /$p with a wrong token refused (401)" || bad "GET /$p with a wrong token: HTTP $c"; done
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST -H "X-Relay-Token: $(tok)" $RELAY/status); [ "$c" = 405 ] && ok "relay is read only (POST 405)" || bad "POST answered HTTP $c"
  s=$(st)
  echo "$s" | jq_ 'd["ric"]["loopbackOnly"] and d["ric"]["listening"]' | grep -qx True && ok "relay: RIC listening, loopback only, commit $(echo "$s" | jq_ 'd["ric"]["commit"][:8]')" || bad "relay RIC state: $(echo "$s" | jq_ 'd["ric"]')"
  for i in $(seq 1 20); do n1=$(st | jq_ 'd["xapp"]["indications"]'); [ "${n1:-0}" -gt 0 ] && break; sleep 2; done
  sleep 5; s=$(st); n2=$(echo "$s" | jq_ 'd["xapp"]["indications"]')
  [ "${n2:-0}" -gt "${n1:-0}" ] && ok "KPM xApp running, indications flowing ($n1 -> $n2 in 5 s, latency $(echo "$s" | jq_ 'd["xapp"]["latencyUs"]') us)" \
    || bad "no new KPM indications ($n1 -> $n2): $(echo "$s" | jq_ 'd["xapp"]["error"]')"
  echo "$s" | jq_ 'len(d["ues"]) >= 1 and "thpDlKbps" in d["ues"][0]' | grep -qx True \
    && ok "KPM per UE: $(echo "$s" | jq_ '", ".join("%s=%s" % (k, v) for k, v in d["ues"][0].items() if k not in ("idType", "ageS"))')" || bad "no UE in the KPM reports"
  # DRB.UEThpDl must follow real traffic: DL speed test through the dashboard API.
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }
  idle=$(st | jq_ 'max(u.get("thpDlKbps", 0) for u in d["ues"])')
  trap 'api speed-stop >/dev/null' EXIT
  c=$(api speed-dl); [ "$c" = 200 ] || bad "dashboard refused speed-dl (HTTP $c)"
  sleep 12; peak=0
  for i in $(seq 1 8); do v=$(st | jq_ 'max(u.get("thpDlKbps", 0) for u in d["ues"])'); peak=$(awk -v a="$peak" -v b="${v:-0}" 'BEGIN{print (b > a ? b : a)}'); sleep 1; done
  api speed-stop >/dev/null; trap - EXIT
  awk -v p="$peak" 'BEGIN{exit !(p >= 5000)}' && ok "KPM DRB.UEThpDl follows the DL speed test: idle $idle kbps, peak $peak kbps" \
    || bad "KPM DRB.UEThpDl did not rise with the DL speed test (idle $idle, peak $peak kbps)"
  d=$(curl -s -m 8 $URL/api/state | jq_ 'json.dumps(d.get("ric"))')
  echo "$d" | jq_ 'd and d["available"] and d["e2"]["associations"] >= 1 and len(d["ues"]) >= 1' | grep -qx True \
    && ok "dashboard /api/state shows the RIC, E2 up and KPM per UE" || bad "dashboard RIC state: ${d:0:300}"
  pq(){ tiny "k3s kubectl get --raw '/api/v1/namespaces/fct-dash/services/prometheus:9090/proxy$1'" 2>/dev/null; }
  if tiny 'k3s kubectl -n fct-dash get deploy prometheus' >/dev/null 2>&1; then
    for i in $(seq 1 12); do u=$(pq '/api/v1/query?query=up%7Bjob%3D%22flexric%22%7D' | jq_ 'd["data"]["result"][0]["value"][1]'); [ "$u" = 1 ] && break; sleep 5; done
    [ "$u" = 1 ] && ok "Prometheus job flexric up (bearer token)" || bad "Prometheus job flexric not up ($u)"
    v=$(pq '/api/v1/query?query=count(flexric_kpm_ue_thp_dl_kbps)' | jq_ 'd["data"]["result"][0]["value"][1]')
    [ "${v:-0}" -ge 1 ] 2>/dev/null && ok "Prometheus stores the KPM series (flexric_kpm_ue_thp_dl_kbps: $v)" || bad "no flexric_kpm_ue_thp_dl_kbps in Prometheus ($v)"
  else echo "  info  no Prometheus on the core: job flexric not checked"; fi
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
image)
  [ "$(id -u)" = 0 ] || { echo "MODE=image needs sudo (k3s image import)"; exit 1; }
  sudo -u "$USER_NAME" -H docker build -t "$IMG" -f "$REPO/infra/ric/Dockerfile.flexric" "$REPO/infra/ric" || { echo "STOP: docker build failed"; exit 1; }
  sudo -u "$USER_NAME" -H docker save "$IMG" | k3s ctr images import - && k3s crictl images | grep -q "fct/flexric" \
    && echo "  PASS  $IMG imported into k3s" || { echo "  FAIL  import"; exit 1; } ;;
preview)
  pre
  echo "== Would do"
  echo "  RAN: Secret fct-dash/ric-relay-token (random, if missing; not shown), ConfigMap flexric-ric-app (ric-relay.py, flexric.conf),"
  echo "       apply ric-ran.yaml: Deployment flexric-ric (host network, RIC on 127.0.0.1:36421/36422, relay on $RAN:$PORT)"
  echo "  core: Secret fct-dash/fct-dash-ric (copy of the token), restart fct-dash and prometheus (they mount it)"
  echo "  check runs a DL speed test (about 25 s) through the dashboard"
  echo "  undo: MODE=remove bash infra/dash/ric.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  if ! $KC -n fct-dash get secret ric-relay-token >/dev/null 2>&1; then
    T=$(mktemp); chmod 600 "$T"; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T"
    $KC -n fct-dash create secret generic ric-relay-token --from-file=token="$T" >/dev/null; rm -f "$T"
    echo "secret/ric-relay-token created (value not shown)"
  fi
  $KC -n fct-dash create configmap flexric-ric-app --from-file="$REPO/infra/ric/ric-relay.py" --from-file="$REPO/infra/ric/flexric.conf" \
    --dry-run=client -o yaml | $KC apply -f -
  HASH=$(cat "$REPO/infra/ric/ric-relay.py" "$REPO/infra/ric/flexric.conf" "$DIR/ric-ran.yaml" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$DIR/ric-ran.yaml" | $KC apply -f -
  $KC -n fct-dash rollout status deploy/flexric-ric --timeout=120s
  tok | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-ric --from-file=token=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
    && echo "secret/fct-dash-ric applied on the core (not shown)"
  for d in fct-dash prometheus; do tiny "k3s kubectl -n fct-dash get deploy $d" >/dev/null 2>&1 && \
    tiny "k3s kubectl -n fct-dash rollout restart deploy/$d && k3s kubectl -n fct-dash rollout status deploy/$d --timeout=180s"; done
  sleep 10; F=0; check ;;
check) check ;;
remove)
  $KC delete -f "$DIR/ric-ran.yaml" --ignore-not-found
  $KC -n fct-dash delete configmap flexric-ric-app --ignore-not-found; $KC -n fct-dash delete secret ric-relay-token --ignore-not-found
  tiny 'k3s kubectl -n fct-dash delete secret fct-dash-ric --ignore-not-found; k3s kubectl -n fct-dash rollout restart deploy/fct-dash' ;;
*) echo "MODE must be image, preview, apply, check or remove"; exit 1 ;;
esac
