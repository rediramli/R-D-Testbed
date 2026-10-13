#!/usr/bin/env bash
# Stage 4d-2 of the bench testbed: noise relay on REDLAB, so the dashboard DL channel buttons set the UE's AWGN noise.
# Needs 4a-4c and the UE with chanmod + telnet (ran.sh, stage 4d-1).
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/dash/noise.sh
#   MODE=preview  read the UE channel model through telnet and parse it the way the relay does; changes nothing
#   MODE=apply    token Secret (RAN) if missing, ConfigMap noise-relay-app (noise-relay.py), noise-ran.yaml,
#                 copy the token to the core Secret fct-dash-noise, restart the dashboard, then check
#   MODE=check    relay on 10.42.0.1:8092 only, token enforced, dashboard sees it; a DL speed test with the presets
#                 off -> poor -> off through the dashboard API (MCS must fall and come back). Ends with noise off.
#   MODE=remove   noise off, then delete the relay, its ConfigMap, the token Secret and the core copy
set -u
MODE=${MODE:-preview}; PH=${PH:-15}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; RAN=10.42.0.1; PORT=8092; URL=http://10.42.0.2:30880; RELAY=http://$RAN:$PORT
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

relay_parse(){  # print the noise value the relay would read from the UE right now (relay's own telnet and parser)
  python3 - "$REPO/noise-relay.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("relay", sys.argv[1]); r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)
out = r.telnet("channelmod show current")
try:
    print("noise", r.parse_noise(out))
except Exception as e:
    print("PARSE FAILED:", e); print(out[:600])
PYEOF
}

pre(){
  echo "== Preconditions"
  for f in "$DIR/noise-ran.yaml" "$REPO/noise-relay.py"; do [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  $KC get ns fct-dash >/dev/null 2>&1 && ok "namespace fct-dash exists on the RAN cluster" || bad "namespace fct-dash missing"
  l=$(ss -Hltn "( sport = :$PORT )")
  if [ -z "$l" ]; then ok "port $PORT free on REDLAB"
  elif $KC -n fct-dash get deploy noise-relay >/dev/null 2>&1; then ok "port $PORT held by our noise-relay (re-apply)"
  else bad "port $PORT in use on REDLAB: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  p=$(relay_parse)
  echo "$p" | grep -qx "noise -100.0" && ok "relay parser reads the UE channel model: AWGN model 0 at -100 dB" \
    || bad "relay cannot parse the UE channel model: $(echo "$p" | head -8 | tr '\n' ' ')"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
}

KEY=""; api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
                 -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }
phase(){  # phase NAME -> median CQI and DL MCS over the last PH-5 s of the dashboard history
  sleep "$PH"; curl -s -m 5 "$URL/api/history?seconds=30" | python3 -c '
import json, sys, time, statistics as st
rows = [r for r in json.load(sys.stdin)["rows"] if r["t"] >= time.time() - float(sys.argv[1])]
c = [r["cqi"] for r in rows if r.get("cqi") is not None]; m = [r["mcsDl"] for r in rows if r.get("mcsDl") is not None]
g = [r["goodputDl"] for r in rows if r.get("goodputDl") is not None]
print("%s %s %s" % (st.median(c) if c else "nan", st.median(m) if m else "nan", round(st.median(g), 1) if g else "nan"))' "$((PH - 5))"; }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }

check(){
  echo "== Checks"
  $KC -n fct-dash rollout status deploy/noise-relay --timeout=180s >/dev/null 2>&1 && ok "noise-relay running" || bad "noise-relay not running"
  ls=$(ss -Hltn "( sport = :$PORT )" | awk '{print $4}' | tr '\n' ' ')
  [ "$ls" = "$RAN:$PORT " ] && ok "listens on $RAN:$PORT only" || bad "listeners on port $PORT: '$ls'"
  others=$(ip -4 -o addr | awk '{print $4}' | cut -d/ -f1 | grep -vE "^(127\.|$RAN$)" | tr '\n' ' ')
  open=""; for ip in $others; do curl -s -m 3 -o /dev/null "http://$ip:$PORT/healthz" && open="$open $ip"; done
  [ -z "$open" ] && ok "not answering on REDLAB's other addresses" || bad "also answers on:$open"
  r=$(tiny "curl -s -m 5 $RELAY/noise")
  echo "$r" | grep -q '"preset": "off"' && echo "$r" | grep -q '"noiseDb": -100' && ok "core host reads the relay: preset off, -100 dB" || bad "relay state from the core host: $r"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/noise --data-binary '{"preset":"poor"}')
  [ "$c" = 401 ] && ok "POST without token refused (401)" || bad "POST without token got HTTP $c"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/noise -H "X-Relay-Token: wrong-$RANDOM" --data-binary '{"preset":"poor"}')
  [ "$c" = 401 ] && ok "POST with a wrong token refused (401)" || bad "POST with a wrong token got HTTP $c"
  [ "$(noise_db)" = "-100.0" ] && ok "refused requests changed nothing (-100 dB)" || bad "noise changed by a refused request: $(noise_db)"
  st=$(curl -s -m 8 $URL/api/state)
  echo "$st" | python3 -c 'import json,sys; n=json.load(sys.stdin)["controls"]["noise"]; sys.exit(0 if n.get("available") and n.get("preset")=="off" else 1)' 2>/dev/null \
    && ok "dashboard sees the relay (preset off)" || bad "dashboard noise state: $(echo "$st" | python3 -c 'import json,sys; print(json.load(sys.stdin)["controls"]["noise"])' 2>/dev/null)"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  trap 'api noise-off >/dev/null; api speed-stop >/dev/null' EXIT
  c=$(api speed-dl); [ "$c" = 200 ] || bad "dashboard refused speed-dl (HTTP $c)"
  sleep 8
  set -- $(phase off);  c0=$1 m0=$2 g0=$3
  c=$(api noise-poor); [ "$c" = 200 ] && ok "dashboard set preset poor (relay reports $(noise_db) dB)" || bad "dashboard refused noise-poor (HTTP $c)"
  set -- $(phase poor); c1=$1 m1=$2 g1=$3
  c=$(api noise-off);  [ "$c" = 200 ] && ok "dashboard set preset off (relay reports $(noise_db) dB)" || bad "dashboard refused noise-off (HTTP $c)"
  set -- $(phase off2); c2=$1 m2=$2 g2=$3
  api speed-stop >/dev/null; trap - EXIT
  echo "  info  CQI / DL MCS / DL goodput (Mbit/s, sim time): off $c0/$m0/$g0  poor $c1/$m1/$g1  off again $c2/$m2/$g2"
  awk -v a="$m0" -v b="$m1" 'BEGIN{exit !(a - b >= 10)}' && ok "poor lowers the DL MCS by >= 10 ($m0 -> $m1)" || bad "poor did not lower the DL MCS enough ($m0 -> $m1)"
  awk -v a="$c0" -v b="$c1" 'BEGIN{exit !(b < a)}' && ok "poor lowers the CQI ($c0 -> $c1)" || bad "poor did not lower the CQI ($c0 -> $c1)"
  awk -v a="$m2" 'BEGIN{exit !(a >= 26)}' && ok "off restores the DL MCS ($m2)" || bad "DL MCS did not recover after off ($m2)"
  [ "$(noise_db)" = "-100.0" ] && ok "noise back at -100 dB" || bad "noise not back at -100 dB: $(noise_db)"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  RAN: Secret fct-dash/noise-relay-token (random, if missing; not shown), ConfigMap noise-relay-app, apply noise-ran.yaml"
  echo "  core: Secret fct-dash-noise (copy of the token), restart fct-dash"
  echo "  check runs a DL speed test with presets off -> poor -> off (about $((3 * PH + 15)) s) and ends with noise off"
  echo "  undo: MODE=remove bash infra/dash/noise.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  if ! $KC -n fct-dash get secret noise-relay-token >/dev/null 2>&1; then
    T=$(mktemp); chmod 600 "$T"; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T"
    $KC -n fct-dash create secret generic noise-relay-token --from-file=token="$T" >/dev/null; rm -f "$T"
    echo "secret/noise-relay-token created (value not shown)"
  fi
  $KC -n fct-dash create configmap noise-relay-app --from-file="$REPO/noise-relay.py" --dry-run=client -o yaml | $KC apply -f -
  HASH=$(cat "$REPO/noise-relay.py" "$DIR/noise-ran.yaml" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$DIR/noise-ran.yaml" | $KC apply -f -
  $KC -n fct-dash rollout status deploy/noise-relay --timeout=180s
  $KC -n fct-dash get secret noise-relay-token -o jsonpath='{.data.token}' | base64 -d \
    | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-noise --from-file=token=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
    && echo "secret/fct-dash-noise applied on the core (not shown)"
  tiny 'k3s kubectl -n fct-dash rollout restart deploy/fct-dash && k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=120s'
  sleep 10; F=0; check ;;
check) check ;;
remove)
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d); api noise-off >/dev/null
  $KC delete -f "$DIR/noise-ran.yaml" --ignore-not-found
  $KC -n fct-dash delete configmap noise-relay-app --ignore-not-found; $KC -n fct-dash delete secret noise-relay-token --ignore-not-found
  tiny 'k3s kubectl -n fct-dash delete secret fct-dash-noise --ignore-not-found; k3s kubectl -n fct-dash rollout restart deploy/fct-dash' ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
