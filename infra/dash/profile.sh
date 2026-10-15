#!/usr/bin/env bash
# Stage E1 of the bench testbed: RAN profile relay on REDLAB, so the dashboard Experiments page can switch the carrier
# between the tested Experiment 1 profiles (bw-24, bw-51, bw-106 = baseline, bw-273). rfsim only.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/dash/profile.sh
#   MODE=preview  files, port 8093, the relay's self-test against the repo baseline, baseline running; changes nothing
#   MODE=apply    token Secret (RAN) if missing, ConfigMaps ran-profile-relay-app (code) and ran-profile-base
#                 (infra/ran/gnb.yaml + ran.yaml), profile-ran.yaml (ServiceAccount, Role, Deployment), copy the token
#                 to the core Secret fct-dash-profile (for the dashboard, next stage), then check
#   MODE=check    relay on 10.42.0.1:8093 only, token enforced, reads the baseline; with FULL=1 also a real switch
#                 bw-51 and back to bw-106 (about 4-6 min, UE down meanwhile; no speed tests or controls meanwhile)
#   MODE=remove   delete the relay, its RBAC, ConfigMaps, token Secret and the core copy (only while at the baseline)
set -u
MODE=${MODE:-preview}; FULL=${FULL:-0}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; RAN=10.42.0.1; PORT=8093; URL=http://10.42.0.2:30880; RELAY=http://$RAN:$PORT
CODE="$REPO/ran-profile-relay.py"; MAN="$DIR/profile-ran.yaml"; GNB="$REPO/infra/ran/gnb.yaml"; RANY="$REPO/infra/ran/ran.yaml"
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
jget(){ python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1" 2>/dev/null; }

pre(){
  echo "== Preconditions"
  for f in "$CODE" "$MAN" "$GNB" "$RANY"; do [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  $KC get ns fct-dash >/dev/null 2>&1 && ok "namespace fct-dash exists on the RAN cluster" || bad "namespace fct-dash missing"
  l=$(ss -Hltn "( sport = :$PORT )")
  if [ -z "$l" ]; then ok "port $PORT free on REDLAB"
  elif $KC -n fct-dash get deploy ran-profile-relay >/dev/null 2>&1; then ok "port $PORT held by our ran-profile-relay (re-apply)"
  else bad "port $PORT in use on REDLAB: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  python3 "$CODE" --selftest "$GNB" "$RANY" > /tmp/profile-selftest.$$ 2>&1 && ok "relay self-test against the repo baseline (4 profiles)" \
    || { bad "relay self-test failed:"; sed 's/^/        /' /tmp/profile-selftest.$$; }
  rm -f /tmp/profile-selftest.$$
  $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | cmp -s - "$GNB" \
    && ok "running gNB config = repo infra/ran/gnb.yaml (baseline)" || bad "running gNB config differs from the repo (restore the baseline first)"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
}

state(){ curl -s -m 15 $RELAY/profile; }
wait_switch(){  # wait_switch PROFILE -> prints the final state; up to 7 min
  local s="" i
  for i in $(seq 1 84); do
    sleep 5; s=$(state | jget 'd["state"]')
    case "$s" in ok|failed|rolled-back) break ;; esac
  done
  echo "$s"
}

check(){
  echo "== Checks"
  if $KC -n fct-dash rollout status deploy/ran-profile-relay --timeout=180s >/dev/null 2>&1; then ok "ran-profile-relay running"
  else bad "ran-profile-relay not running (run MODE=apply first); stopping before any switch"; return; fi
  ls=$(ss -Hltn "( sport = :$PORT )" | awk '{print $4}' | tr '\n' ' ')
  [ "$ls" = "$RAN:$PORT " ] && ok "listens on $RAN:$PORT only" || bad "listeners on port $PORT: '$ls'"
  others=$(ip -4 -o addr | awk '{print $4}' | cut -d/ -f1 | grep -vE "^(127\.|$RAN$)" | tr '\n' ' ')
  open=""; for ip in $others; do curl -s -m 3 -o /dev/null "http://$ip:$PORT/healthz" && open="$open $ip"; done
  [ -z "$open" ] && ok "not answering on REDLAB's other addresses" || bad "also answers on:$open"
  r=$(tiny "curl -s -m 15 $RELAY/profile")
  [ "$(echo "$r" | jget 'd["current"]')" = bw-106 ] && ok "core host reads the relay: current profile bw-106 (baseline), state $(echo "$r" | jget 'd["state"]')" \
    || bad "relay state from the core host: $(echo "$r" | head -c 300)"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/profile --data-binary '{"profile":"bw-51"}')
  [ "$c" = 401 ] && ok "POST without token refused (401)" || bad "POST without token got HTTP $c"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/profile -H "X-Relay-Token: wrong-$RANDOM" --data-binary '{"profile":"bw-51"}')
  [ "$c" = 401 ] && ok "POST with a wrong token refused (401)" || bad "POST with a wrong token got HTTP $c"
  TOKEN=$($KC -n fct-dash get secret profile-relay-token -o jsonpath='{.data.token}' | base64 -d)
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/profile -H "X-Relay-Token: $TOKEN" --data-binary '{"profile":"bw-999"}')
  [ "$c" = 400 ] && ok "unknown profile refused (400)" || bad "unknown profile got HTTP $c"
  [ "$(state | jget 'd["current"]')" = bw-106 ] && ok "refused requests changed nothing (bw-106)" || bad "profile changed by a refused request"
  if [ "$FULL" = 1 ]; then
    echo "== Full switch: bw-51, then back to bw-106 (UE down for about 1-2 min each time)"
    t0=$(date +%s)
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST $RELAY/profile -H "X-Relay-Token: $TOKEN" --data-binary '{"profile":"bw-51"}')
    [ "$c" = 202 ] && ok "switch to bw-51 accepted" || bad "switch to bw-51: HTTP $c"
    s=$(wait_switch); t1=$(date +%s)
    [ "$s" = ok ] && ok "switch to bw-51 done in $((t1 - t0)) s" || bad "switch to bw-51 ended '$s': $(state | jget 'd["error"]')"
    [ "$(state | jget 'd["current"]')" = bw-51 ] && ok "relay reports bw-51" || bad "relay reports $(state | jget 'd["current"]')"
    $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | grep -q "dl_carrierBandwidth: 51" && ok "gNB ConfigMap has 51 PRB" || bad "gNB ConfigMap not at 51 PRB"
    $KC logs deploy/oai-gnb 2>/dev/null | grep -m1 -q "N_RB_DL 51" && ok "gNB log: N_RB_DL 51" || bad "gNB log does not show N_RB_DL 51"
    ping -I oaitun_ue1 -c 2 -W 3 10.45.0.1 >/dev/null 2>&1 && ok "UE tunnel answers at 51 PRB" || bad "UE tunnel does not answer at 51 PRB"
    t0=$(date +%s)
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST $RELAY/profile -H "X-Relay-Token: $TOKEN" --data-binary '{"profile":"bw-106"}')
    [ "$c" = 202 ] && ok "switch back to bw-106 accepted" || bad "switch back to bw-106: HTTP $c"
    s=$(wait_switch); t1=$(date +%s)
    [ "$s" = ok ] && ok "back at bw-106 in $((t1 - t0)) s" || bad "switch back ended '$s': $(state | jget 'd["error"]')"
    $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | cmp -s - "$GNB" && ok "gNB ConfigMap = repo gnb.yaml again" || bad "gNB ConfigMap differs from the repo"
    ping -I oaitun_ue1 -c 2 -W 3 10.45.0.1 >/dev/null 2>&1 && ok "UE tunnel answers at the baseline" || bad "UE tunnel does not answer at the baseline"
  fi
  unset TOKEN
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  RAN: Secret fct-dash/profile-relay-token (random, if missing; not shown), ConfigMaps ran-profile-relay-app and"
  echo "       ran-profile-base, apply profile-ran.yaml (ServiceAccount + Role on oai-gnb-config, oai-gnb, oai-nr-ue only)"
  echo "  core: Secret fct-dash-profile (copy of the token) for the dashboard; the dashboard itself is not changed yet"
  echo "  check FULL=1 switches to bw-51 and back (about 4-6 min, UE down meanwhile)"
  echo "  undo: MODE=remove bash infra/dash/profile.sh"
  echo "RESULT (preview): $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  if ! $KC -n fct-dash get secret profile-relay-token >/dev/null 2>&1; then
    T=$(mktemp); chmod 600 "$T"; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T"
    $KC -n fct-dash create secret generic profile-relay-token --from-file=token="$T" >/dev/null; rm -f "$T"
    echo "secret/profile-relay-token created (value not shown)"
  fi
  $KC -n fct-dash create configmap ran-profile-relay-app --from-file="$CODE" --dry-run=client -o yaml | $KC apply -f -
  $KC -n fct-dash create configmap ran-profile-base --from-file=gnb.yaml="$GNB" --from-file=ran.yaml="$RANY" --dry-run=client -o yaml | $KC apply -f -
  HASH=$(cat "$CODE" "$MAN" "$GNB" "$RANY" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$MAN" | $KC apply -f -
  $KC -n fct-dash rollout status deploy/ran-profile-relay --timeout=180s
  $KC -n fct-dash get secret profile-relay-token -o jsonpath='{.data.token}' | base64 -d \
    | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-profile --from-file=token=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
    && echo "secret/fct-dash-profile applied on the core (not shown)"
  sleep 5; F=0; check ;;
check) check ;;
remove)
  cur=$(state | jget 'd["current"]')
  [ "$cur" = bw-106 ] || [ "${FORCE:-0}" = 1 ] || { echo "STOP: current profile is '$cur', not the baseline; switch back first (or FORCE=1)"; exit 1; }
  $KC delete -f "$MAN" --ignore-not-found
  $KC -n fct-dash delete configmap ran-profile-relay-app ran-profile-base --ignore-not-found
  $KC -n fct-dash delete secret profile-relay-token --ignore-not-found
  tiny 'k3s kubectl -n fct-dash delete secret fct-dash-profile --ignore-not-found' ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
