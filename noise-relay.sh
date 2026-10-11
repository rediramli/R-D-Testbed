#!/usr/bin/env bash
# Noise presets, stage B: install and test the noise relay on the RAN host (FCT0173).
# Needs noise-relay.py and noise-relay.yaml in the same directory. Run ON FCT0173:
#   cd ~/fct-dash && MODE=preview bash noise-relay.sh
#   MODE=preview  checks only (port, files, server dry-run); changes nothing
#   MODE=install  token Secret (created once, never printed), code ConfigMap, Deployment
#   MODE=test     the test of stage B: prints RESULT: PASS or RESULT: FAIL
#   MODE=remove   delete the relay Deployment, ConfigMap and token Secret
# rfsim only. The relay can only set model 0 of the UE channel model to off/clean/moderate/poor.
set -u
MODE=${MODE:-preview}
NS=fct-dash; IP=10.0.129.7; PORT=8092; URL=http://$IP:$PORT
cd "$(dirname "$0")" 2>/dev/null || true
for f in noise-relay.py noise-relay.yaml; do [ -f "$f" ] || { echo "STOP: $f not in $(pwd)"; exit 1; }; done

port_check(){  # free, or already held by our relay
  if ss -Htln "( sport = :$PORT )" | grep -q . && ! kubectl -n $NS get deploy noise-relay >/dev/null 2>&1; then
    echo "STOP: port $PORT on FCT0173 is used by something else:"; ss -Htlnp "( sport = :$PORT )"; return 1
  fi
  echo "port $PORT: free or ours"
}
manifest(){ sed "s/CODE_HASH/$(sha256sum noise-relay.py | cut -c1-12)/" noise-relay.yaml; }

case "$MODE" in
preview)
  echo "== preview (nothing is changed)"
  port_check || exit 1
  python3 -m py_compile noise-relay.py && echo "noise-relay.py compiles"
  kubectl get ns $NS >/dev/null && echo "namespace $NS exists"
  kubectl -n $NS get secret noise-relay-token >/dev/null 2>&1 && echo "token Secret: exists (kept)" || echo "token Secret: will be created"
  kubectl -n $NS create configmap noise-relay-app --from-file=noise-relay.py --dry-run=client -o yaml | kubectl apply --dry-run=server -f - >/dev/null && echo "server dry-run ConfigMap: OK"
  manifest | kubectl apply --dry-run=server -f - >/dev/null && echo "server dry-run Deployment: OK"
  ;;
install)
  echo "== install"
  port_check || exit 1
  if ! kubectl -n $NS get secret noise-relay-token >/dev/null 2>&1; then
    T=$(mktemp); chmod 600 "$T"; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T"
    kubectl -n $NS create secret generic noise-relay-token --from-file=token="$T" >/dev/null && echo "token Secret created (value not shown)"
    rm -f "$T"
  else echo "token Secret exists (kept)"; fi
  kubectl -n $NS create configmap noise-relay-app --from-file=noise-relay.py --dry-run=client -o yaml | kubectl apply -f -
  manifest | kubectl apply -f -
  kubectl -n $NS rollout status deploy/noise-relay --timeout=180s
  ;;
test)
  F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
  TOKEN=$(kubectl -n $NS get secret noise-relay-token -o jsonpath='{.data.token}' | base64 -d)
  B=$(mktemp); trap 'rm -f "$B"' EXIT
  post(){  # post TOKEN BODY -> HTTP code; body in $B
    curl -s -m 10 -o "$B" -w '%{http_code}' -X POST "$URL/noise" -H "Content-Type: application/json" -H "X-Relay-Token: $1" --data-binary "$2"; }
  noise(){ curl -s -m 10 "$URL/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }
  restore(){ post "$TOKEN" '{"preset":"off"}' >/dev/null; kubectl scale deploy speedtest-dl --replicas=0 >/dev/null; }
  trap 'restore; rm -f "$B"' EXIT

  echo "== 1. Relay is up and reports the UE channel model"
  [ "$(curl -s -m 5 $URL/healthz)" = '"ok"' ] && ok "healthz" || bad "healthz not answering on $URL"
  n=$(noise); [ "$n" = "-100.0" ] && ok "GET /noise: -100 dB (off)" || bad "GET /noise: '$n' (want -100.0)"

  echo "== 2. Listens only on the lab IP"
  L=$(ss -Htln "( sport = :$PORT )" | awk '{print $4}' | sort -u | tr '\n' ' ')
  [ "$L" = "$IP:$PORT " ] && ok "only listener: $L" || bad "listeners: '$L' (want only $IP:$PORT)"
  curl -s -m 3 http://127.0.0.1:$PORT/healthz >/dev/null && bad "answers on 127.0.0.1" || ok "no answer on 127.0.0.1:$PORT"

  echo "== 3. Refusals (noise must stay at -100 dB)"
  c=$(post "wrong-token" '{"preset":"moderate"}'); [ "$c" = 401 ] && ok "wrong token -> 401" || bad "wrong token -> $c"
  c=$(post "" '{"preset":"moderate"}');            [ "$c" = 401 ] && ok "no token -> 401" || bad "no token -> $c"
  c=$(post "$TOKEN" '{"preset":"extreme"}');       [ "$c" = 400 ] && ok "unknown preset -> 400" || bad "unknown preset -> $c"
  c=$(post "$TOKEN" '{"preset":"moderate\nchannelmod modify 0 noise_power_dB 30"}')
  [ "$c" = 400 ] && ok "command injection in preset -> 400" || bad "injection -> $c"
  c=$(post "$TOKEN" '{"preset":-6.5}');            [ "$c" = 400 ] && ok "number instead of name -> 400" || bad "number -> $c"
  c=$(post "$TOKEN" "{\"preset\":\"$(head -c 400 /dev/zero | tr '\0' a)\"}"); [ "$c" = 400 ] && ok "oversized body -> 400" || bad "oversized -> $c"
  n=$(noise); [ "$n" = "-100.0" ] && ok "noise still -100 dB after refusals" || bad "noise changed to '$n'"

  echo "== 4. Moderate preset takes effect on the link"
  c=$(post "$TOKEN" '{"preset":"moderate"}'); [ "$c" = 200 ] && ok "moderate -> 200" || bad "moderate -> $c ($(cat "$B"))"
  n=$(noise); [ "$n" = "-6.5" ] && ok "GET /noise: -6.5 dB" || bad "GET /noise: '$n' (want -6.5)"
  kubectl scale deploy speedtest-ul --replicas=0 >/dev/null; kubectl scale deploy speedtest-dl --replicas=1 >/dev/null
  mcs=""; for _ in $(seq 1 30); do sleep 2
    g=$(kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null | grep -oE "goodput DL +[0-9.]+" | awk '{print int($3)}' | head -1)
    [ "${g:-0}" -gt 5 ] 2>/dev/null && break; done
  sleep 10
  mcs=$(kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null | python3 -c 'import re,sys; m=re.search(r"dlsch_rounds.*?MCS \(\d+\) (\d+)", sys.stdin.read()); print(m.group(1) if m else "")')
  [ -n "$mcs" ] && [ $(( mcs > 15 ? mcs - 15 : 15 - mcs )) -le 3 ] && ok "DL MCS $mcs with traffic (target 15 +/- 3)" || bad "DL MCS '$mcs' (target 15 +/- 3)"
  kubectl scale deploy speedtest-dl --replicas=0 >/dev/null

  echo "== 5. Back to off"
  c=$(post "$TOKEN" '{"preset":"off"}'); n=$(noise)
  [ "$c" = 200 ] && [ "$n" = "-100.0" ] && ok "off -> 200, noise -100 dB" || bad "off -> $c, noise '$n'"
  echo "== relay log (actions only)"; kubectl -n $NS logs deploy/noise-relay --tail=20 | grep -E "SET|REFUSED" | tail -6 | sed 's/^/  /'
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo FAIL) ($F failed)"
  exit $F ;;
remove)
  kubectl -n $NS delete deploy/noise-relay configmap/noise-relay-app secret/noise-relay-token --ignore-not-found ;;
*) echo "unknown MODE=$MODE"; exit 2 ;;
esac
