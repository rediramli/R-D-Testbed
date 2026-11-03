#!/usr/bin/env bash
# Experiment 1b stage G2: grid relay on REDLAB, so the dashboard's resource grid page can ask for captures.
# Needs the dashboard (dash.sh, with the fct-dash-grid Secret mount in dash-core.yaml) and, for live captures, the
# T tracer: sudo MODE=on bash infra/exp/exp01b-grid.sh (firewall first, then the gNB with the T options).
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/dash/grid.sh
#   MODE=preview  preconditions; changes nothing
#   MODE=apply    token Secret (RAN) if missing, ConfigMap grid-relay-app (grid-relay.py, grid-trace.py), grid-ran.yaml,
#                 copy the token to the core Secret fct-dash-grid, restart the dashboard, then check
#   MODE=check    relay on 10.42.0.1:8094 only, token enforced, dashboard sees it; with the tracer on also one snapshot
#                 through the dashboard API (SSB at the predicted PRBs)
#   MODE=remove   delete the relay, its ConfigMap, the token Secret and the core copy
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; RAN=10.42.0.1; PORT=8094; URL=http://10.42.0.2:30880; RELAY=http://$RAN:$PORT
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
tracer(){ ss -Hltn "( sport = :2021 )" | grep -q .; }

pre(){
  echo "== Preconditions"
  for f in "$DIR/grid-ran.yaml" "$REPO/grid-relay.py" "$REPO/grid-trace.py"; do [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  $KC get ns fct-dash >/dev/null 2>&1 && ok "namespace fct-dash exists on the RAN cluster" || bad "namespace fct-dash missing"
  l=$(ss -Hltn "( sport = :$PORT )")
  if [ -z "$l" ]; then ok "port $PORT free on REDLAB"
  elif $KC -n fct-dash get deploy grid-relay >/dev/null 2>&1; then ok "port $PORT held by our grid-relay (re-apply)"
  else bad "port $PORT in use on REDLAB: $(echo "$l" | awk '{print $4}' | tr '\n' ' ')"; fi
  tiny 'k3s kubectl -n fct-dash get deploy fct-dash -o yaml' 2>/dev/null | grep -q "fct-dash-grid" \
    && ok "dashboard Deployment mounts the fct-dash-grid Secret" || bad "dashboard has no fct-dash-grid mount: sudo MODE=apply bash infra/dash/dash.sh first"
  tracer && echo "  info  T tracer on (live captures possible)" || echo "  info  T tracer off: the relay will answer 'tracer off' until sudo MODE=on bash infra/exp/exp01b-grid.sh"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
}

check(){
  echo "== Checks"
  $KC -n fct-dash rollout status deploy/grid-relay --timeout=180s >/dev/null 2>&1 && ok "grid-relay running" || bad "grid-relay not running"
  ls=$(ss -Hltn "( sport = :$PORT )" | awk '{print $4}' | tr '\n' ' ')
  [ "$ls" = "$RAN:$PORT " ] && ok "listens on $RAN:$PORT only" || bad "listeners on port $PORT: '$ls'"
  others=$(ip -4 -o addr | awk '{print $4}' | cut -d/ -f1 | grep -vE "^(127\.|$RAN$)" | tr '\n' ' ')
  open=""; for ip in $others; do curl -s -m 3 -o /dev/null "http://$ip:$PORT/healthz" && open="$open $ip"; done
  [ -z "$open" ] && ok "not answering on REDLAB's other addresses" || bad "also answers on:$open"
  r=$(tiny "curl -s -m 5 $RELAY/grid/status")
  echo "$r" | grep -q '"tracer"' && ok "core host reads the relay status (tracer $(echo "$r" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tracer"])'))" || bad "relay status from the core host: $r"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/grid/capture --data-binary '{"kind":"snapshot"}')
  [ "$c" = 401 ] && ok "POST without token refused (401)" || bad "POST without token got HTTP $c"
  c=$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST $RELAY/grid/capture -H "X-Relay-Token: wrong-$RANDOM" --data-binary '{"kind":"snapshot"}')
  [ "$c" = 401 ] && ok "POST with a wrong token refused (401)" || bad "POST with a wrong token got HTTP $c"
  st=$(curl -s -m 8 $URL/api/grid/status)
  echo "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("available") else 1)' 2>/dev/null \
    && ok "dashboard sees the relay (/api/grid/status)" || bad "dashboard grid status: $st"
  if tracer; then
    KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
    c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST $URL/api/grid -H "Content-Type: application/json" -H "X-Admin-Key: $KEY" --data-binary '{"action":"snapshot","slots":40}')
    [ "$c" = 200 ] && ok "snapshot started through the dashboard" || bad "dashboard refused the snapshot (HTTP $c)"
    for i in $(seq 1 20); do s=$(curl -s -m 5 $URL/api/grid/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["state"])' 2>/dev/null); [ "$s" = running ] || break; sleep 1; done
    curl -s -m 10 $URL/api/grid/result | python3 -c '
import json, sys
d = json.load(sys.stdin); mib = {(r["frame"], r["slot"]) for r in d["rows"] if any(l["ch"] == "SSB/PBCH" for l in r["labels"])}
hit = [s for g in d["grids"] if g["dir"] == "dl" and (g["frame"], g["slot"]) in mib
       for s in range(14) if [p for p in range(d["nrb"]) if g["db"][p][s] > 0] == list(range(43, 63))]
print("  info  %d grids, %d rows; SSB symbols at PRB 43-62: %s" % (len(d["grids"]), len(d["rows"]), hit or "none"))
sys.exit(0 if hit else 1)' && ok "snapshot through the dashboard shows the SSB at PRB 43-62" || bad "snapshot result without the SSB block"
  else
    echo "  info  T tracer off: capture checks skipped"
  fi
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  RAN: Secret fct-dash/grid-relay-token (random, if missing; not shown), ConfigMap grid-relay-app, apply grid-ran.yaml"
  echo "  core: Secret fct-dash-grid (copy of the token), restart fct-dash"
  echo "  undo: MODE=remove bash infra/dash/grid.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  if ! $KC -n fct-dash get secret grid-relay-token >/dev/null 2>&1; then
    T=$(mktemp); chmod 600 "$T"; head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T"
    $KC -n fct-dash create secret generic grid-relay-token --from-file=token="$T" >/dev/null; rm -f "$T"
    echo "secret/grid-relay-token created (value not shown)"
  fi
  $KC -n fct-dash create configmap grid-relay-app --from-file="$REPO/grid-relay.py" --from-file="$REPO/grid-trace.py" --dry-run=client -o yaml | $KC apply -f -
  HASH=$(cat "$REPO/grid-relay.py" "$REPO/grid-trace.py" "$DIR/grid-ran.yaml" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$DIR/grid-ran.yaml" | $KC apply -f -
  $KC -n fct-dash rollout status deploy/grid-relay --timeout=180s
  $KC -n fct-dash get secret grid-relay-token -o jsonpath='{.data.token}' | base64 -d \
    | tiny 'umask 077; t=$(mktemp); cat > $t; k3s kubectl -n fct-dash create secret generic fct-dash-grid --from-file=token=$t --dry-run=client -o yaml | k3s kubectl apply -f -; rm -f $t' >/dev/null \
    && echo "secret/fct-dash-grid applied on the core (not shown)"
  tiny 'k3s kubectl -n fct-dash rollout restart deploy/fct-dash && k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=120s'
  sleep 10; F=0; check ;;
check) check ;;
remove)
  $KC delete -f "$DIR/grid-ran.yaml" --ignore-not-found
  $KC -n fct-dash delete configmap grid-relay-app --ignore-not-found; $KC -n fct-dash delete secret grid-relay-token --ignore-not-found
  tiny 'k3s kubectl -n fct-dash delete secret fct-dash-grid --ignore-not-found; k3s kubectl -n fct-dash rollout restart deploy/fct-dash' ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
