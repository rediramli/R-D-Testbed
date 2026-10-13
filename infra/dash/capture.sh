#!/usr/bin/env bash
# Stage 4c of the bench testbed: N2 capture (tshark on NGAP, SCTP 38412) on REDLAB for the dashboard message flow.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/dash/capture.sh
#   MODE=preview  show what would change (default, changes nothing)
#   MODE=apply    ConfigMap n2-capture-app (capture.py) + capture-ran.yaml in namespace fct-dash, then check
#   MODE=check    service up on 10.42.0.1:8091 only; dashboard sees it; the UE is stopped and started once through the
#                 dashboard so a full registration appears in the flow; no SIM key in the flow
#   MODE=remove   delete the Deployment and the ConfigMap
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; RAN=10.42.0.1; PORT=8091; URL=http://10.42.0.2:30880
SECRETS=$HOME/testbed-secrets/ue1.env
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  for f in "$DIR/capture-ran.yaml" "$REPO/capture.py"; do [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  grep -q 'BIND = os.environ.get("BIND"' "$REPO/capture.py" && ok "capture.py has the BIND setting" || bad "capture.py without BIND (would listen on all addresses)"
  $KC get ns fct-dash >/dev/null 2>&1 && ok "namespace fct-dash exists on the RAN cluster" || bad "namespace fct-dash missing (run dash.sh first)"
  l=$(ss -Hltn "( sport = :$PORT )")
  if [ -z "$l" ]; then ok "port $PORT free on REDLAB"
  elif $KC -n fct-dash get deploy n2-capture >/dev/null 2>&1; then ok "port $PORT held by our n2-capture (re-apply)"
  else bad "port $PORT in use on REDLAB: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
}

api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
         -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }

check(){
  echo "== Checks"
  $KC -n fct-dash rollout status deploy/n2-capture --timeout=180s >/dev/null 2>&1 && ok "n2-capture running" || bad "n2-capture not running"
  ls=$(ss -Hltn "( sport = :$PORT )" | awk '{print $4}' | tr '\n' ' ')
  [ "$ls" = "$RAN:$PORT " ] && ok "listens on $RAN:$PORT only" || bad "listeners on port $PORT: '$ls'"
  others=$(ip -4 -o addr | awk '{print $4}' | cut -d/ -f1 | grep -vE "^(127\.|$RAN$)" | tr '\n' ' ')
  open=""; for ip in $others; do curl -s -m 3 -o /dev/null "http://$ip:$PORT/healthz" && open="$open $ip"; done
  [ -z "$open" ] && ok "not answering on REDLAB's other addresses ($others)" || bad "also answers on:$open"
  [ "$(tiny "curl -s -m 5 http://$RAN:$PORT/healthz")" = ok ] && ok "core host reaches $RAN:$PORT (tshark running)" || bad "core host cannot reach $RAN:$PORT"
  st=$(curl -s -m 8 "$URL/api/flow?after=0")
  echo "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d.get("error") and d["status"]["running"] else 1)' 2>/dev/null \
    && ok "dashboard reads the capture service" || bad "dashboard flow: $(echo "$st" | head -c 200)"
  # A full registration only happens when the UE attaches, so restart the UE once through the dashboard.
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  last=$(echo "$st" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last", 0))' 2>/dev/null)
  c=$(api ue-stop); [ "$c" = 200 ] && ok "UE stopped through the dashboard" || bad "dashboard refused ue-stop (HTTP $c)"
  for i in $(seq 1 30); do [ -z "$($KC get pods -l app=oai-nr-ue -o name 2>/dev/null)" ] && break; sleep 2; done
  c=$(api ue-start); [ "$c" = 200 ] && ok "UE started through the dashboard" || bad "dashboard refused ue-start (HTTP $c)"
  for i in $(seq 1 60); do ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && break; sleep 2; done
  ue=$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')
  case "$ue" in 10.45.*) ok "UE registered again: oaitun_ue1 $ue";; *) bad "UE did not come back ('$ue')";; esac
  sleep 3
  fl=$(curl -s -m 8 "$URL/api/flow?after=${last:-0}")
  echo "$fl" | python3 -c '
import json, sys
m = [x["msg"] for x in json.load(sys.stdin)["messages"]]
want = ["InitialUEMessage", "Registration request", "Authentication request", "Authentication response",
        "Security mode command", "InitialContextSetupRequest", "InitialContextSetupResponse",
        "PDUSessionResourceSetupRequest", "PDUSessionResourceSetupResponse"]
miss = [w for w in want if not any(w in x for x in m)]
print(("  PASS  " if not miss else "  FAIL  ") + "registration in the flow: %d new messages%s" % (len(m), "" if not miss else ", missing: " + ", ".join(miss)))
sys.exit(1 if miss else 0)' || F=$((F+1))
  hit=0; for v in KI OPC; do val=$(grep -o "^$v=.*" "$SECRETS" 2>/dev/null | cut -d= -f2)
    [ -n "$val" ] && echo "$fl$st" | grep -qiF -- "$val" && { hit=1; bad "$v found in the message flow"; }; done
  [ -f "$SECRETS" ] && [ $hit = 0 ] && ok "no SIM key in the message flow"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  RAN: ConfigMap fct-dash/n2-capture-app (capture.py), apply capture-ran.yaml (tshark, host network, HTTP $RAN:$PORT)"
  echo "  check restarts the UE once through the dashboard (new registration for the flow)"
  echo "  undo: MODE=remove bash infra/dash/capture.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  $KC -n fct-dash create configmap n2-capture-app --from-file="$REPO/capture.py" --dry-run=client -o yaml | $KC apply -f -
  HASH=$(cat "$REPO/capture.py" "$DIR/capture-ran.yaml" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$DIR/capture-ran.yaml" | $KC apply -f -
  $KC -n fct-dash rollout status deploy/n2-capture --timeout=240s
  sleep 3; F=0; check ;;
check) check ;;
remove)
  $KC delete -f "$DIR/capture-ran.yaml" --ignore-not-found
  $KC -n fct-dash delete configmap n2-capture-app --ignore-not-found ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
