#!/usr/bin/env bash
# Stage K4 of the bench testbed: prove that the UE KPIs detect a degradation and name its root cause.
# Breaks the DL on purpose with the noise preset poor (AWGN on the UE receiver, rfsim only) during a DL speed test:
#   off  -> every graded UE KPI ok, diagnosis "none"
#   poor -> SINR, CQI, DL MCS and DL user throughput bad, diagnosis "radio_sinr" (SINR -> CQI -> MCS -> throughput)
#   off  -> ok again
# The RAN (cell) DL user throughput must follow the same ok / bad / ok.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=check bash infra/dash/kpi.sh
#   MODE=preview  dashboard, relay and UE KPIs answer, noise off; changes nothing
#   MODE=check    the test above (about 3 x PH + 10 s); always ends with noise off and the speed test stopped
set -u
MODE=${MODE:-preview}; PH=${PH:-40}; WIN=${WIN:-30}
URL=http://10.42.0.2:30880; RELAY=http://10.42.0.1:8092
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
KEY=""; api(){ curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$URL/api/control" -H "Content-Type: application/json" \
                 -H "X-Admin-Key: $KEY" --data-binary "{\"action\":\"$1\"}"; }
noise_db(){ curl -s -m 5 "$RELAY/noise" | python3 -c 'import json,sys; print(json.load(sys.stdin)["noiseDb"])' 2>/dev/null; }

grade(){  # grade PHASE EXPECT(ok|bad) -> checks the UE and RAN KPIs of the last WIN seconds
  { curl -s -m 8 "$URL/api/kpi?domain=ue&seconds=$WIN"; echo; curl -s -m 8 "$URL/api/kpi?domain=ran&seconds=$WIN"; } | python3 -c '
import json, sys
phase, want = sys.argv[1], sys.argv[2]
ue, ran = [json.loads(l) for l in sys.stdin.read().strip().split("\n")]
fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + phase + ": " + msg)
if not ue["ues"]:
    r(False, "no UE in the UE KPIs"); sys.exit(1)
u = ue["ues"][0]; k = {x["id"]: x for x in u["kpis"]}; g = u["diagnosis"]
v = lambda i: "-" if k[i]["value"] is None else "%.1f" % k[i]["value"]
print("  info  %s: RNTI %s, %d samples, %d s with DL data | SINR %s dB  CQI %s  DL MCS %s  DL retx %s %%  DL %s Mbit/s | diagnosis %s"
      % (phase, u["rnti"], u["samples"], u["activeDl"], v("sinr"), v("cqi"), v("mcs_dl"), v("dl_retx"), v("dl_tput"), g["id"]))
r(u["activeDl"] >= 10, "DL speed test ran (%d s with DL data, want >= 10)" % u["activeDl"])
for i in ("sinr", "cqi", "mcs_dl", "dl_tput"):
    r(k[i]["status"] == want, "%s %s (want %s)" % (k[i]["name"], k[i]["status"], want))
r(k["dl_retx"]["status"] == "ok", "DL HARQ retransmissions within target (%s %%): noise lowers the MCS, not the BLER" % v("dl_retx"))
r(k["oos"]["status"] == "ok", "UE stayed in sync")
r(g["id"] == ("none" if want == "ok" else "radio_sinr"), "diagnosis %s (want %s)" % (g["id"], "none" if want == "ok" else "radio_sinr"))
if want == "bad":
    print("  info  %s: %s" % (phase, g["summary"]))
c = {x["id"]: x for x in ran["kpis"]}["dl_tput"]
r(c["status"] == want, "RAN DL user throughput %s (%s Mbit/s, want %s)" % (c["status"], c["value"] and round(c["value"], 1), want))
sys.exit(fail)' "$1" "$2" || F=$((F+$?))
}

pre(){
  echo "== Preconditions"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "dashboard answers" || bad "dashboard not answering"
  n=$(curl -s -m 8 "$URL/api/kpi?domain=ue&seconds=60" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["ues"]))' 2>/dev/null)
  [ "${n:-0}" -ge 1 ] && ok "UE KPIs answer ($n UE)" || bad "no UE KPIs (dashboard without K3, or UE down)"
  [ "$(noise_db)" = "-100.0" ] && ok "noise off (-100 dB)" || bad "noise not off: '$(noise_db)'"
  ip -4 -br addr show oaitun_ue1 2>/dev/null | grep -q "10\.45\." && ok "UE tunnel up" || bad "UE tunnel down"
}

check(){
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  echo "== Degradation test (DL speed test; off -> poor -> off; $PH s per phase, KPIs of the last $WIN s)"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  trap 'api noise-off >/dev/null; api speed-stop >/dev/null' EXIT
  c=$(api speed-dl); [ "$c" = 200 ] && ok "DL speed test started" || { bad "dashboard refused speed-dl (HTTP $c)"; exit 1; }
  sleep 10; sleep "$PH"; grade off ok
  c=$(api noise-poor); [ "$c" = 200 ] && ok "preset poor set ($(noise_db) dB)" || bad "dashboard refused noise-poor (HTTP $c)"
  sleep "$PH"; grade poor bad
  c=$(api noise-off); [ "$c" = 200 ] && ok "preset off set ($(noise_db) dB)" || bad "dashboard refused noise-off (HTTP $c)"
  sleep "$PH"; grade off-again ok
  api speed-stop >/dev/null; trap - EXIT
  [ "$(noise_db)" = "-100.0" ] && ok "noise back at -100 dB" || bad "noise not back at -100 dB: $(noise_db)"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview) pre; echo "== Would do"; echo "  DL speed test with presets off -> poor -> off (about $((3 * PH + 10)) s), grade the UE and RAN KPIs, end with noise off" ;;
check) check ;;
*) echo "MODE must be preview or check"; exit 1 ;;
esac
