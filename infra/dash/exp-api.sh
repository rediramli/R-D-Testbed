#!/usr/bin/env bash
# Stage E2 of the dashboard Experiments menu: the backend API (no page yet). Needs stages 4a-4d and E1 (profile.sh).
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=check bash infra/dash/exp-api.sh
#   MODE=check   relay visible through the dashboard, 6 control targets, results on the volume, admin key enforced,
#                UDP DL and UDP UL started through the dashboard, one Record each, CSV, results survive a dashboard
#                restart, test rows deleted again
#   FULL=1       also switch to bw-51 through the dashboard, record UDP DL there, and switch back to bw-106
# Install first:  sudo MODE=apply bash infra/dash/control.sh   (UDP clients + RBAC)
#                 sudo MODE=apply bash infra/dash/dash.sh      (app.py, PVC, profile Secret mount)
# The admin password is read from the core Secret into a variable only and never printed. rfsim only.
set -u
MODE=${MODE:-check}; FULL=${FULL:-0}
KC="k3s kubectl"
URL=${URL:-http://10.42.0.2:30880}
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
jget(){ python3 -c 'import json,sys
try: d=json.load(sys.stdin); print(eval(sys.argv[1]))
except Exception as e: print("ERR", e)' "$1"; }
KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
post(){ curl -s -m 20 -X POST "$URL$1" -H "Content-Type: application/json" -H "X-Admin-Key: $KEY" --data-binary "$2" -w ' %{http_code}'; }
code(){ echo "${1##* }"; }
body(){ echo "${1% *}"; }
state(){ curl -s -m 8 $URL/api/state; }
ready(){ $KC get deploy "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null; }
want(){ $KC get deploy "$1" -o jsonpath='{.spec.replicas}' 2>/dev/null; }
IDS=""

wait_profile(){  # wait_profile NAME -> waits until the dashboard reports NAME with state ok/idle (max 240 s)
  for i in $(seq 1 120); do
    s=$(state | jget 'd["controls"]["profile"]["current"], d["controls"]["profile"]["state"]')
    case "$s" in "('$1', 'ok')"|"('$1', 'idle')") echo ok; return;; esac
    case "$s" in *failed*|*rolled-back*) echo "$s"; return;; esac
    sleep 2
  done; echo "timeout: $s"; }

# udp_record DIR(dl|ul) LABEL MINMBPS -> starts the UDP test, records after 28 s, checks, stops
udp_record(){
  local d=$1 dep=speedtest-$1-udp r row g
  r=$(post /api/control "{\"action\":\"speed-$d-udp\"}")
  [ "$(code "$r")" = 200 ] && ok "UDP $d started through the dashboard" || { bad "speed-$d-udp: $r"; return; }
  for i in $(seq 1 40); do [ "$(ready $dep)" = 1 ] && break; sleep 1; done
  [ "$(ready $dep)" = 1 ] || { bad "$dep not ready"; post /api/control '{"action":"speed-stop"}' >/dev/null; return; }
  sleep 28
  $KC logs deploy/$dep --tail=200 2>/dev/null | grep -m1 "offered UDP" | sed 's/^/  info  /'
  r=$(post /api/exp "{\"action\":\"record\",\"exp\":\"1\",\"note\":\"exp-api check $2\"}")
  [ "$(code "$r")" = 200 ] || { bad "record $d: $r"; post /api/control '{"action":"speed-stop"}' >/dev/null; return; }
  row=$(body "$r")
  IDS="$IDS $(echo "$row" | jget 'd["row"]["id"]')"
  echo "  info  $(echo "$row" | jget '"row %s: %s PRB, test %s, goodput DL %s UL %s Mbit/s, MCS DL %s UL %s, BLER DL %s UL %s, %s samples" % tuple(d["row"][k] for k in ("id","prb","test","goodputDl","goodputUl","mcsDl","mcsUl","blerDl","blerUl","samples"))')"
  [ "$(echo "$row" | jget 'd["row"]["test"]')" = "$dep" ] && ok "row notes the running test ($dep)" || bad "row test field: $(echo "$row" | jget 'd["row"]["test"]')"
  [ "$(echo "$row" | jget 'd["row"]["prb"]')" = "$4" ] && ok "row notes the carrier ($4 PRB)" || bad "row PRB: $(echo "$row" | jget 'd["row"]["prb"]') (want $4)"
  [ "$d" = dl ] && g=$(echo "$row" | jget 'd["row"]["goodputDl"]') || g=$(echo "$row" | jget 'd["row"]["goodputUl"]')
  awk -v v="$g" -v m="$3" 'BEGIN{exit !(v+0 > m+0)}' && ok "$d MAC goodput $g Mbit/s (> $3)" || bad "$d MAC goodput $g Mbit/s (want > $3)"
  r=$(post /api/control '{"action":"speed-stop"}')
  for i in $(seq 1 20); do [ "$(want $dep)" = 0 ] && break; sleep 1; done
  [ "$(want $dep)" = 0 ] && ok "UDP $d stopped" || bad "$dep still scaled up"
  sleep 5
}

check(){
  echo "== Checks"
  [ -n "$KEY" ] || { bad "cannot read the admin password Secret on the core"; echo "RESULT: FAIL ($F)"; exit 1; }
  st=$(state)
  [ "$(echo "$st" | jget 'len(d["controls"]["targets"])')" = 6 ] && ok "6 control targets (TCP and UDP speed tests)" \
    || bad "control targets: $(echo "$st" | jget 'sorted(d["controls"]["targets"])')"
  [ "$(echo "$st" | jget 'd["controls"]["profile"]["available"]')" = True ] && ok "dashboard reads the profile relay: $(echo "$st" | jget 'd["controls"]["profile"]["current"]')" \
    || { bad "profile relay not visible: $(echo "$st" | jget 'd["controls"]["profile"].get("reason")')"; echo "RESULT: FAIL ($F)"; exit 1; }
  [ "$(echo "$st" | jget 'd["controls"]["profile"]["current"]')" = bw-106 ] && ok "bench at the baseline (bw-106)" \
    || { bad "bench not at bw-106; switch back first"; echo "RESULT: FAIL ($F)"; exit 1; }
  [ "$(curl -s -m 5 $URL/api/exp/results | jget 'd["persistent"]')" = True ] && ok "results stored on the volume (/data)" || bad "results not persistent"
  c=$(curl -s -m 8 -o /dev/null -w '%{http_code}' -X POST $URL/api/exp --data-binary '{"action":"record","exp":"1"}')
  [ "$c" = 401 ] && ok "record without admin key refused (401)" || bad "record without key got HTTP $c"
  r=$(post /api/exp '{"action":"record","exp":"../1"}'); [ "$(code "$r")" = 400 ] && ok "invalid experiment id refused (400)" || bad "invalid exp id got $r"
  r=$(post /api/control '{"action":"profile-bw-999"}'); [ "$(code "$r")" = 400 ] && ok "unknown profile refused (400)" || bad "unknown profile got $r"
  ueip=$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')
  udp_record dl "bw-106" 40 106
  udp_record ul "bw-106" 1 106
  [ "$(ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}')" = "$ueip" ] && ok "UE kept its address ($ueip)" || bad "UE address changed"
  csv=$(curl -s -m 5 "$URL/api/exp/results.csv?exp=1")
  echo "$csv" | head -1 | grep -q "^id,exp,time_utc,profile,prb" && ok "CSV header" || bad "CSV header: $(echo "$csv" | head -1)"
  for id in $IDS; do echo "$csv" | grep -q "^$id,1," || bad "row $id missing in the CSV"; done; ok "CSV holds rows$IDS"
  echo "== Dashboard restart (results must survive)"
  tiny 'k3s kubectl -n fct-dash rollout restart deploy/fct-dash && k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=120s' >/dev/null
  for i in $(seq 1 30); do [ "$(curl -s -m 3 $URL/healthz)" = ok ] && break; sleep 2; done
  have=$(curl -s -m 5 "$URL/api/exp/results?exp=1" | jget '" ".join(str(r["id"]) for r in d["rows"])')
  miss=""; for id in $IDS; do echo " $have " | grep -q " $id " || miss="$miss $id"; done
  [ -z "$miss" ] && ok "rows$IDS still there after the restart" || bad "rows lost after restart:$miss"
  if [ "$FULL" = 1 ]; then
    echo "== Full: bw-51 through the dashboard, UDP DL record, back to bw-106"
    sleep 15   # the dashboard sampler needs a few seconds of history after its restart
    r=$(post /api/control '{"action":"profile-bw-51"}'); [ "$(code "$r")" = 200 ] && ok "switch to bw-51 accepted: $(body "$r" | jget 'd["msg"]')" || bad "profile-bw-51: $r"
    s=$(wait_profile bw-51); [ "$s" = ok ] && ok "dashboard reports bw-51" || bad "switch to bw-51: $s"
    sleep 25   # UE attach and 20 s of history at the new carrier
    udp_record dl "bw-51" 20 51
    r=$(post /api/control '{"action":"profile-bw-106"}'); [ "$(code "$r")" = 200 ] && ok "switch back accepted" || bad "profile-bw-106: $r"
    s=$(wait_profile bw-106); [ "$s" = ok ] && ok "back at bw-106" || bad "switch back to bw-106: $s"
  fi
  echo "== Clean up the test rows"
  for id in $IDS; do
    r=$(post /api/exp "{\"action\":\"delete\",\"id\":$id}"); [ "$(code "$r")" = 200 ] || bad "delete row $id: $r"; done
  r=$(post /api/exp "{\"action\":\"delete\",\"id\":${IDS##* }}"); [ "$(code "$r")" = 404 ] && ok "test rows deleted (second delete answers 404)" || bad "second delete got $r"
  for t in speedtest-dl speedtest-ul speedtest-dl-udp speedtest-ul-udp; do [ "$(want $t)" = 0 ] || bad "$t still scaled up"; done
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
check) check ;;
*) echo "MODE must be check"; exit 1 ;;
esac
