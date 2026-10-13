#!/usr/bin/env bash
# Stage 4a of the bench testbed: the dashboard (read-only) on the core host, reading both clusters.
# Run ON REDLAB from the repo root:   sudo MODE=preview bash infra/dash/dash.sh
#   MODE=preview  show what would change (default, changes nothing)
#   MODE=apply    RAN: read-only account (dash-ran.yaml). Core (ssh tiny): Secret with the RAN API token,
#                 ConfigMap with app.py + index.html, dash-core.yaml. Then check.
#   MODE=check    tests only
#   MODE=remove   delete the dashboard objects on both clusters (namespace fct-dash, the two Roles/RoleBindings)
# Open from REDLAB: http://10.42.0.2:30880   From the laptop: ssh -L 8080:10.42.0.2:30880 redi@<REDLAB tailscale IP>
# Safety: the dashboard has no write access to either cluster and cannot read Secrets; the RAN token is
# never printed (temp dir mode 700, removed); the test reads every pod log the dashboard serves and fails on any SIM key.
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"
USER_NAME=${SUDO_USER:-root}; UHOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
SECRETS=$UHOME/testbed-secrets/ue1.env
CORE=10.42.0.2; RAN=10.42.0.1; PORT=30880; URL=http://$CORE:$PORT
SA=system:serviceaccount:fct-dash:fct-dash-reader
asuser(){ sudo -u "$USER_NAME" -H "$@"; }
tiny(){ asuser ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  $KC get nodes 2>/dev/null | grep -q " Ready " && ok "k3s (RAN) node Ready" || bad "k3s (RAN) not ready"
  for f in "$DIR/dash-ran.yaml" "$DIR/dash-core.yaml" "$REPO/app.py" "$REPO/index.html"; do
    [ -f "$f" ] && ok "${f#$REPO/} ($(sha256sum "$f" | cut -c1-16))" || bad "missing $f"; done
  tiny 'k3s kubectl -n open5gs get deploy -o name' 2>/dev/null | grep -q open5gs-amf && ok "core cluster reachable (ssh tiny, k3s kubectl)" \
    || bad "cannot use k3s kubectl on the core (ssh tiny as $USER_NAME)"
  c=$(tiny "curl -sk -m 5 -o /dev/null -w '%{http_code}' https://$RAN:6443/version" 2>/dev/null)
  case "$c" in 200|401|403) ok "RAN API https://$RAN:6443 reachable from the core host (HTTP $c)";; *) bad "RAN API not reachable from the core host ('$c')";; esac
  tiny "k3s kubectl get svc -A 2>/dev/null" | grep -q ":$PORT/" && bad "a Service on the core already uses port $PORT" || ok "no Service on the core uses port $PORT"
  tiny "ss -Hltn '( sport = :$PORT )'" 2>/dev/null | grep -q . && bad "something listens on $PORT on the core host" || ok "port $PORT free on the core host"
  echo "  info  core host IPv4: $(tiny "ip -4 -br addr | awk '{print \$1\"=\"\$3}' | tr '\n' ' '" 2>/dev/null)"
}

check(){
  echo "== Checks"
  # The key and RBAC tests need root (SUDO_USER picks the user's secrets file and ssh config); without sudo they fail falsely.
  [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "STOP: run with sudo as your login user: sudo MODE=$MODE bash infra/dash/dash.sh"; exit 1; }
  tiny 'k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=120s' >/dev/null 2>&1 && ok "fct-dash running on the core" || bad "fct-dash not running"
  [ "$(curl -s -m 5 $URL/healthz)" = ok ] && ok "$URL/healthz answers from REDLAB" || bad "$URL/healthz does not answer"
  for i in $(seq 1 15); do st=$(curl -s -m 8 $URL/api/state); echo "$st" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["ran"]["ueStats"] else 1)' 2>/dev/null && break; sleep 2; done
  echo "$st" | python3 -c '
import json, sys
d = json.load(sys.stdin); fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
r(not d["errors"], "API errors per cluster: %s" % (d["errors"] or "none"))
core = {p["role"] for p in d["pods"] if p["cluster"] == "core" and p["state"] == "running"}
want = {"mongodb", "nrf", "scp", "ausf", "udm", "udr", "pcf", "bsf", "nssf", "smf", "amf", "upf"}
r(want <= core, "core NFs running (%d/12)%s" % (len(want & core), "" if want <= core else ", missing " + " ".join(sorted(want - core))))
ran = {p["role"] for p in d["pods"] if p["cluster"] == "ran" and p["state"] == "running"}
r({"gnb", "ue"} <= ran, "RAN: gNB and UE running (%s)" % " ".join(sorted(ran)))
m = d["ran"]
r((m.get("gnbs") or 0) >= 1 and (m.get("ues") or 0) >= 1, "AMF view: gNBs %s, UEs %s" % (m.get("gnbs"), m.get("ues")))
s = m["ueStats"][-1] if m["ueStats"] else {}
r(all(s.get(k) is not None for k in ("cqi", "mcsDl", "goodputDl")),
  "KPIs from the gNB log: RNTI %s CQI %s DL MCS %s DL goodput %s" % (s.get("rnti"), s.get("cqi"), s.get("mcsDl"), s.get("goodputDl")))
r(not m["errors"], "KPI parser errors: %s" % (m["errors"] or "none"))
v = m.get("cqiView") or {}; rows = v.get("rows") or []
r(len(rows) == 15 and all(abs(x["qm"] * x["rate"] / 1024 - x["eff"]) < 0.0006 for x in rows)
  and all(rows[i]["eff"] < rows[i + 1]["eff"] for i in range(14)),
  "CQI view: %s, 15 rows, efficiency = Qm x R/1024 and increasing" % v.get("name"))
r(v.get("cqi") is not None and v.get("cqi") == s.get("cqi"), "CQI view shows the gNB CQI (%s = %s)" % (v.get("cqi"), s.get("cqi")))
r(isinstance(v.get("sinr"), (int, float)), "UE SINR from the UE log: %s dB" % v.get("sinr"))
if v.get("table") == 1:
    e = v.get("expectedCqi")
    r(e is not None and e == sum(1 for x in rows if v["sinr"] >= x["sinrMin"]),
      "typical CQI at %s dB: %s (difference %s)" % (v.get("sinr"), e, v.get("delta")))
sys.exit(fail)' || F=$((F+$?))
  # The sampler keeps one row per second from dashboard start, so right after an apply wait until 10 rows exist.
  for i in $(seq 1 15); do
    rows=$(curl -s -m 5 "$URL/api/history?seconds=60" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))' 2>/dev/null)
    [ "${rows:-0}" -ge 10 ] && break; sleep 2; done
  sn=$(curl -s -m 5 "$URL/api/history?seconds=60" | python3 -c 'import json,sys; print(sum(r.get("sinrUe") is not None for r in json.load(sys.stdin)["rows"]))' 2>/dev/null)
  [ "${sn:-0}" -ge 10 ] && ok "UE SINR in the history: $sn samples in the last 60 s" || bad "UE SINR in the history: '${sn:-none}' samples (want >= 10)"
  [ "${rows:-0}" -ge 10 ] && ok "KPI history: $rows samples in the last 60 s" || bad "KPI history: '${rows:-none}' samples in the last 60 s (want >= 10)"
  # K1: core KPIs from the Open5GS counters
  for i in $(seq 1 12); do kp=$(curl -s -m 8 "$URL/api/kpi?seconds=900"); echo "$kp" | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin)["samples"] >= 2 else 1)' 2>/dev/null && break; sleep 5; done
  echo "$kp" | python3 -c '
import json, sys
d = json.load(sys.stdin); k = {x["id"]: x for x in d["kpis"]}; fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
r(not d["errors"], "core metrics scraped from AMF, SMF, UPF, PCF (errors: %s)" % (d["errors"] or "none"))
r(len(k) == 17, "%d core KPIs computed (want 17)" % len(k))
r(k["gnb"]["value"] == 1 and k["pfcp_peers"]["value"] == 1, "gauges: gNBs %s, PFCP peers %s" % (k["gnb"]["value"], k["pfcp_peers"]["value"]))
r((k["pdu_sessions"]["value"] or 0) >= 1, "active PDU sessions: %s" % k["pdu_sessions"]["value"])
bad = [x["name"] for x in d["kpis"] if x["status"] == "bad"]
r(not bad, "no KPI below target: %s" % (", ".join(bad) or "none"))
sys.exit(fail)' || F=$((F+$?))
  # K2: RAN KPIs from the gNB MAC counters
  curl -s -m 8 "$URL/api/kpi?domain=ran&seconds=300" | python3 -c '
import json, sys
d = json.load(sys.stdin); k = {x["id"]: x for x in d["kpis"]}; fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
r(len(k) == 12, "%d RAN KPIs computed (want 12)" % len(k))
r(d["samples"] >= 10, "RAN counter samples in 5 min: %d" % d["samples"])
r(k["dl_retx"]["status"] in ("ok", "bad") and k["oos"]["status"] in ("ok", "bad"),
  "HARQ and sync KPIs have data: DL retx %s %%, out of sync %s %%" % (k["dl_retx"]["value"], k["oos"]["value"]))
sys.exit(fail)' || F=$((F+$?))
  # K3/K4: KPIs per UE with a diagnosis
  curl -s -m 8 "$URL/api/kpi?domain=ue&seconds=120" | python3 -c '
import json, sys
d = json.load(sys.stdin); fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
r(len(d["ues"]) >= 1, "UE KPIs: %d UE(s) in the last 2 min" % len(d["ues"]))
if d["ues"]:
    u = d["ues"][0]; k = {x["id"]: x for x in u["kpis"]}
    r(len(k) == 10, "UE %s: %d KPIs computed (want 10)" % (u["rnti"], len(k)))
    r(k["sinr"]["status"] in ("ok", "bad") and k["cqi"]["status"] in ("ok", "bad"),
      "UE %s: SINR %s dB and CQI %s graded" % (u["rnti"], k["sinr"]["value"], k["cqi"]["value"]))
    r(u["diagnosis"]["id"] and len(u["diagnosis"]["chain"]) == 5, "UE %s: diagnosis %s" % (u["rnti"], u["diagnosis"]["id"]))
sys.exit(fail)' || F=$((F+$?))
  # P1a: /metrics for Prometheus (gNB MAC counters and UE radio values per RNTI, Uu events)
  m=$(curl -s -m 5 "$URL/metrics")
  echo "$m" | grep -q '^fct_ue_rntis [1-9]' && echo "$m" | grep -q '^fct_gnb_mac_total{rnti=' && echo "$m" | grep -q '^fct_uu_events_total{msg="msg1"}' \
    && ok "/metrics: $(echo "$m" | grep -c '^fct_') series (MAC counters, radio values, Uu events)" || bad "/metrics incomplete"
  echo "$m" | grep -qiE 'imsi|supi|[0-9a-f]{32}' && bad "/metrics contains an identity or key-like value" || ok "/metrics has no IMSI/SUPI or key-like value"
  # P1b: KPI windows and trends from Prometheus (needs prom.sh). Same KPI code on both sources.
  if tiny 'k3s kubectl -n fct-dash get deploy prometheus' >/dev/null 2>&1; then
    t7=$(curl -s -m 20 -o /dev/null -w '%{time_total}' "$URL/api/kpi?domain=ran&seconds=604800")
    { curl -s -m 20 "$URL/api/kpi?domain=core&seconds=3600&source=prom"; echo; curl -s -m 20 "$URL/api/kpi?domain=core&seconds=900&source=mem"; echo
      curl -s -m 20 "$URL/api/kpi?domain=ran&seconds=900&source=prom"; echo; } | python3 -c '
import json, sys
cp, cm, rp = [json.loads(l) for l in sys.stdin.read().strip().split("\n")]
t7 = float(sys.argv[1]); fail = 0
def r(good, msg):
    global fail; fail += not good; print(("  PASS  " if good else "  FAIL  ") + msg)
kp = {x["id"]: x for x in cp["kpis"]}; km = {x["id"]: x for x in cm["kpis"]}; kr = {x["id"]: x for x in rp["kpis"]}
r(cp["source"] == "prometheus" and len(kp) == 17 and "prometheus" not in cp["errors"],
  "core KPIs over 1 h from Prometheus: %d KPIs, %d samples" % (len(kp), cp["samples"]))
g = [p[1] for p in cp["series"].get("gnb", []) if p[1] is not None]
r(len(g) >= min(10, cp["samples"] - 1) and len(g) >= 3 and g[-1] == 1,
  "core trend: %d gNB points (of %d buckets with data), last %s" % (len(g), cp["samples"] - 1, g[-1] if g else None))
same = [i for i in ("gnb", "pfcp_peers", "pdu_sessions", "reg_subs") if kp[i]["value"] == km[i]["value"]]
r(len(same) == 4, "memory and Prometheus agree on the gauges: %s" % ", ".join("%s %s/%s" % (i, kp[i]["value"], km[i]["value"]) for i in ("gnb", "pfcp_peers", "pdu_sessions", "reg_subs")))
r(rp["source"] == "prometheus" and len(kr) == 12 and kr["dl_retx"]["status"] in ("ok", "bad"),
  "RAN KPIs over 15 min from Prometheus: 12 KPIs, DL retx %s %%" % kr["dl_retx"]["value"])
d = [p for p in rp["series"].get("dl_retx", []) if p[1] is not None]
r(len(d) >= 10, "RAN trend: %d DL retx points every %s s" % (len(d), rp["seriesStep"]))
r(t7 < 5, "7 day RAN window answers in %.2f s" % t7)
sys.exit(fail)' "${t7:-99}" || F=$((F+$?))
  else
    echo "  info  Prometheus not installed: P1b checks skipped (MODE=apply bash infra/dash/prom.sh)"
  fi
  # Every pod log the dashboard serves must be free of SIM keys.
  pods=$(echo "$st" | python3 -c 'import json,sys; [print(p["cluster"], p["pod"]) for p in json.load(sys.stdin)["pods"]]' 2>/dev/null)
  n=0; hit=0
  while read -r cl pod; do [ -n "$pod" ] || continue; n=$((n+1))
    txt=$(curl -s -m 10 "$URL/api/logs?cluster=$cl&pod=$pod&lines=500")
    for v in KI OPC; do val=$(grep -o "^$v=.*" "$SECRETS" 2>/dev/null | cut -d= -f2)
      [ -n "$val" ] && echo "$txt" | grep -qiF -- "$val" && { hit=$((hit+1)); echo "  FAIL  $v found in the log of $cl/$pod"; }; done
  done <<< "$pods"
  [ -f "$SECRETS" ] || bad "cannot read $SECRETS for the key check"
  [ $n -ge 14 ] && [ $hit = 0 ] && ok "no SIM key in the logs of $n pods served by the dashboard" || { [ $hit = 0 ] && bad "only $n pod logs checked (want >= 14)"; F=$((F+hit)); }
  # Read-only and no Secrets, on both clusters.
  for q in "create pods" "get secrets" "patch deployments"; do
    [ "$($KC auth can-i $q -n default --as=$SA 2>/dev/null)" = no ] && ok "RAN reader may not $q (default)" || bad "RAN reader MAY $q in default"
    [ "$(tiny "k3s kubectl auth can-i $q -n open5gs --as=$SA" 2>/dev/null)" = no ] && ok "core reader may not $q (open5gs)" || bad "core reader MAY $q in open5gs"; done
  # Reachable only on the bench LAN address.
  others=$(tiny "ip -4 -o addr | awk '{print \$4}' | cut -d/ -f1 | grep -vE '^(127\.|$CORE$)'" 2>/dev/null | tr '\n' ' ')
  open=""; for ip in $others; do tiny "curl -s -m 3 -o /dev/null http://$ip:$PORT/healthz" >/dev/null 2>&1 && open="$open $ip"; done
  [ -z "$open" ] && ok "port $PORT not answering on the other core addresses ($others)" || bad "port $PORT also answers on:$open"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  RAN (REDLAB): apply dash-ran.yaml (namespace fct-dash, SA fct-dash-reader + token, Role/RoleBinding read-only in default)"
  echo "  core (tiny): namespace fct-dash, Secret fct-dash-ran (https://$RAN:6443, CA, token; not shown),"
  echo "               ConfigMap fct-dash-app (app.py, index.html), dash-core.yaml (reader Role in open5gs, Deployment, hostPort $CORE:$PORT)"
  echo "  undo: sudo MODE=remove bash infra/dash/dash.sh" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  $KC apply -f "$DIR/dash-ran.yaml"
  for i in $(seq 1 20); do [ -n "$($KC -n fct-dash get secret fct-dash-reader-token -o jsonpath='{.data.token}' 2>/dev/null)" ] && break; sleep 1; done
  T=$(mktemp -d); chmod 700 "$T"; trap 'rm -rf "$T"' EXIT
  printf 'https://%s:6443' "$RAN" > "$T/server"
  $KC -n fct-dash get secret fct-dash-reader-token -o jsonpath='{.data.token}' | base64 -d > "$T/token"
  $KC -n fct-dash get secret fct-dash-reader-token -o jsonpath='{.data.ca\.crt}' | base64 -d > "$T/ca.crt"
  [ -s "$T/token" ] && [ -s "$T/ca.crt" ] || { echo "STOP: RAN reader token not issued"; exit 1; }
  tiny 'k3s kubectl create namespace fct-dash --dry-run=client -o yaml | k3s kubectl apply -f -'
  $KC create secret generic fct-dash-ran -n fct-dash --from-file="$T/server" --from-file="$T/token" --from-file="$T/ca.crt" --dry-run=client -o yaml \
    | tiny 'k3s kubectl apply -f -' >/dev/null && echo "secret/fct-dash-ran applied on the core (not shown)"
  rm -rf "$T"
  $KC create configmap fct-dash-app -n fct-dash --from-file="$REPO/app.py" --from-file="$REPO/index.html" --dry-run=client -o yaml | tiny 'k3s kubectl apply -f -'
  HASH=$(cat "$REPO/app.py" "$REPO/index.html" "$DIR/dash-core.yaml" | sha256sum | cut -c1-12)
  sed "s/CODE_HASH/$HASH/" "$DIR/dash-core.yaml" | tiny 'k3s kubectl apply -f -'
  tiny 'k3s kubectl -n fct-dash rollout status deploy/fct-dash --timeout=180s'
  sleep 5; F=0; check ;;
check) check ;;
remove)
  tiny 'k3s kubectl delete namespace fct-dash --ignore-not-found; k3s kubectl -n open5gs delete role,rolebinding fct-dash-read --ignore-not-found'
  $KC delete -f "$DIR/dash-ran.yaml" --ignore-not-found ;;
*) echo "MODE must be preview, apply, check or remove"; exit 1 ;;
esac
