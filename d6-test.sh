#!/usr/bin/env bash
# D6 acceptance test for the FCT dashboard controls. Run on REDLAB:
#   bash d6-test.sh
# It drives the same API the buttons use and checks every result against the
# dashboard state, the N2 message flow and, at the end, a Lab 0 run.
set -u
BASE=${BASE:-http://10.0.129.2:30880}
LAB0=${LAB0:-1}
FAILS=0
pass(){ printf '  PASS  %s\n' "$1"; }
fail(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
step(){ printf '\n== %s  (%s)\n' "$1" "$(date +%T)"; }

read -r -s -p "Dashboard admin password: " KEY; echo

ctl(){  # ctl ACTION [KEY] -> prints "HTTPCODE|message"
  curl -s -o /tmp/d6.out -w '%{http_code}' -X POST "$BASE/api/control" \
    -H "Content-Type: application/json" -H "X-Admin-Key: ${2-$KEY}" -d "{\"action\":\"$1\"}"
  printf '|%s' "$(python3 -c 'import json;print(json.load(open("/tmp/d6.out")).get("msg",""))' 2>/dev/null)"
}
state(){ curl -s "$BASE/api/state"; }
q(){  # q PYTHON_EXPR -> evaluates against the state JSON as d
  state | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null
}
ran_running(){ q "any(p['cluster']=='ran' and p['role']=='$1' and p['state']=='running' for p in d['pods'])"; }
ran_present(){ q "any(p['cluster']=='ran' and p['role']=='$1' for p in d['pods'])"; }
flow_mark(){ curl -s "$BASE/api/flow?after=0" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("last",0))'; }
flow_has(){  # flow_has MARK TEXT
  curl -s "$BASE/api/flow?after=$1" | python3 -c "import json,sys; print(any('$2' in m['msg'] for m in json.load(sys.stdin)['messages']))"
}
wait_for(){  # wait_for SECONDS 'shell test' -> 0 when the test turns true
  local end=$((SECONDS+$1)); while [ $SECONDS -lt $end ]; do eval "$2" && return 0; sleep 2; done; return 1
}

step "1. Access control"
r=$(ctl check "wrong-password"); [ "${r%%|*}" = 401 ] && pass "wrong password refused (401)" || fail "wrong password not refused: $r"
r=$(ctl check);                  [ "${r%%|*}" = 200 ] && pass "correct password accepted" || { fail "password refused: $r"; exit 1; }
q "d['controls']['enabled']" | grep -q True && pass "controls enabled, radio mode $(q "d['radioMode']")" || fail "controls disabled: $(q "d['controls']['reason']")"

step "2. Stop everything"
r=$(ctl gnb-stop); [ "${r%%|*}" = 200 ] && pass "gnb-stop accepted" || fail "gnb-stop: $r"
wait_for 90 '[ "$(ran_present gnb)" = False ] && [ "$(ran_present ue)" = False ]' && pass "gNB and UE pods gone" || fail "pods still present after 90 s"

step "3. Interlock: UE cannot start without a cell"
r=$(ctl ue-start); [ "${r%%|*}" = 409 ] && pass "ue-start refused: ${r#*|}" || fail "ue-start was not refused: $r"

step "4. Start the gNB"
M=$(flow_mark); T0=$SECONDS
r=$(ctl gnb-start); [ "${r%%|*}" = 200 ] && pass "gnb-start accepted" || fail "gnb-start: $r"
wait_for 90 '[ "$(flow_has $M NGSetupResponse)" = True ]' && pass "NGSetupResponse in message flow after $((SECONDS-T0)) s" || fail "no NGSetupResponse within 90 s"
wait_for 30 '[ "$(q "d[\"ran\"][\"gnbs\"]")" = 1 ]' && pass "gNBs tile = 1" || fail "gNBs tile = $(q "d['ran']['gnbs']")"

step "5. Start the UE"
M=$(flow_mark); T0=$SECONDS
r=$(ctl ue-start); [ "${r%%|*}" = 200 ] && pass "ue-start accepted" || fail "ue-start: $r"
wait_for 120 '[ "$(flow_has $M PDUSessionResourceSetupResponse)" = True ]' && pass "registration and PDU session in flow after $((SECONDS-T0)) s" || fail "no PDU session within 120 s"
for x in "Registration request" "Authentication request" "Security mode command" "InitialContextSetupRequest"; do
  [ "$(flow_has $M "$x")" = True ] && pass "flow shows: $x" || fail "flow lacks: $x"
done
wait_for 30 '[ "$(q "d[\"ran\"][\"ues\"]")" = 1 ]' && pass "UEs tile = 1, RNTI $(q "d['ran']['ueStats'][-1]['rnti'] if d['ran']['ueStats'] else '-'")" || fail "UEs tile = $(q "d['ran']['ues']")"

step "6. Speed test downlink"
r=$(ctl speed-dl); [ "${r%%|*}" = 200 ] && pass "speed-dl accepted" || fail "speed-dl: $r"
dl(){ q "round(sum(u.get('goodputDl',0) for u in d['ran']['ueStats']),1)"; }
wait_for 90 'awk "BEGIN{exit !($(dl) > 50)}"' && pass "DL goodput $(dl) Mbit/s" || fail "DL goodput only $(dl) Mbit/s"

step "7. Speed test uplink"
r=$(ctl speed-ul); [ "${r%%|*}" = 200 ] && pass "speed-ul accepted" || fail "speed-ul: $r"
ul(){ q "round(sum(u.get('goodputUl',0) for u in d['ran']['ueStats']),1)"; }
wait_for 90 'awk "BEGIN{exit !($(ul) > 25)}"' && pass "UL goodput $(ul) Mbit/s" || fail "UL goodput only $(ul) Mbit/s"

step "8. Stop the speed test"
r=$(ctl speed-stop); [ "${r%%|*}" = 200 ] && pass "speed-stop accepted" || fail "speed-stop: $r"
wait_for 60 'awk "BEGIN{exit !($(dl) < 5 && $(ul) < 5)}"' && pass "goodput back near zero (DL $(dl), UL $(ul))" || fail "traffic still flowing (DL $(dl), UL $(ul))"

step "9. Stop UE, then gNB"
r=$(ctl ue-stop);  [ "${r%%|*}" = 200 ] && pass "ue-stop accepted" || fail "ue-stop: $r"
wait_for 60 '[ "$(ran_present ue)" = False ]' && pass "UE pod gone" || fail "UE pod still present"
r=$(ctl gnb-stop); [ "${r%%|*}" = 200 ] && pass "gnb-stop accepted" || fail "gnb-stop: $r"
wait_for 60 '[ "$(ran_present gnb)" = False ]' && pass "gNB pod gone" || fail "gNB pod still present"

step "10. Controller cannot reach the radio"
for check in "create pods" "patch deployments/ocudu-gnb --subresource=scale" "delete pods"; do
  a=$(ssh fct0173 "kubectl auth can-i $check -n default --as=system:serviceaccount:fct-dash:fct-dash-controller" 2>/dev/null)
  [ "$a" = no ] && pass "controller may not: $check" || fail "controller MAY: $check ($a)"
done

if [ "$LAB0" = 1 ]; then
  step "11. Baseline still passes"
  ssh fct0173 '~/fct-testbed/lab0-run.sh' | grep -E "FAIL|HASIL" | sed 's/^/  /'
fi

printf '\n== RESULT: %s (%d failed checks)\n' "$([ $FAILS = 0 ] && echo PASS || echo FAIL)" "$FAILS"
exit $FAILS
