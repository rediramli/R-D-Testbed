#!/usr/bin/env bash
# Stage P1a of the bench testbed: Prometheus on the core host keeps the KPI counters for 30 days.
# Needs K1 (Open5GS metrics) and a dashboard with /metrics (sudo MODE=apply bash infra/dash/dash.sh first).
# Changes only the core cluster, namespace fct-dash (prom-core.yaml). No Open5GS NF and no RAN pod is touched.
# Run ON REDLAB from the repo root as the login user (no sudo):   MODE=preview bash infra/dash/prom.sh
#   MODE=preview  image tag exists, dashboard /metrics answers, storage class present, kubectl diff; changes nothing
#   MODE=apply    apply prom-core.yaml, wait for Prometheus, collect 60 s, then check
#   MODE=check    5 targets up, retention 30d / 5GB, ClusterIP only and not reachable from REDLAB, RAN and core series
#                 present, and the data survives a Prometheus restart
#   MODE=remove   delete Prometheus and its Services/ConfigMap; KEEPS the data volume
#   MODE=purge    remove + delete the data volume (all history; asks for confirmation)
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd)
URL=http://10.42.0.2:30880; IMG_TAG=v3.5.0
tiny(){ ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
tk(){ tiny "k3s kubectl -n fct-dash $*"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
manifest(){ sed "s/CONFIG_HASH/$(sha256sum "$DIR/prom-core.yaml" | cut -c1-12)/" "$DIR/prom-core.yaml"; }
pq(){  # pq PATH_WITH_QUERY -> Prometheus API answer through the Kubernetes API server proxy (no port opened anywhere)
  tiny "k3s kubectl get --raw '/api/v1/namespaces/fct-dash/services/prometheus:9090/proxy$1'" 2>/dev/null; }
q(){   # q PROMQL -> first value of an instant query, or "none"
  enc=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1")
  pq "/api/v1/query?query=$enc" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")
except Exception:
    print("none")'; }

pre(){
  echo "== Preconditions"
  [ -f "$DIR/prom-core.yaml" ] && ok "prom-core.yaml ($(sha256sum "$DIR/prom-core.yaml" | cut -c1-16))" || bad "missing prom-core.yaml"
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "https://hub.docker.com/v2/repositories/prom/prometheus/tags/$IMG_TAG")
  [ "$c" = 200 ] && ok "image prom/prometheus:$IMG_TAG exists" || bad "image tag $IMG_TAG not found on Docker Hub (HTTP $c)"
  curl -s -m 5 "$URL/metrics" | grep -q '^fct_ue_rntis ' && ok "dashboard /metrics answers (dash.sh with P1a applied)" \
    || bad "dashboard has no /metrics: run sudo MODE=apply bash infra/dash/dash.sh first"
  tiny 'k3s kubectl get storageclass local-path' >/dev/null 2>&1 && ok "storage class local-path on the core" || bad "no local-path storage class on the core"
  tk get deploy fct-dash >/dev/null 2>&1 && ok "namespace fct-dash with the dashboard" || bad "dashboard not deployed on the core"
  d=$(manifest | tiny 'k3s kubectl diff -f -' 2>/dev/null)
  objs=$(echo "$d" | grep -E '^--- ' | awk '{print $2}' | sed 's#.*/##' | sed -E 's/^(apps\.)?v1\.//; s/\.fct-dash\./ /' | sort | tr '\n' ';')
  echo "  info  objects created or changed: ${objs:-none (already applied)}"
  echo "$objs" | tr ';' '\n' | grep -v '^$' | grep -vE '^(ConfigMap prometheus-config|Service fct-dash-metrics|Service prometheus|PersistentVolumeClaim prometheus-data|Deployment prometheus)$' \
    && bad "the manifest would touch other objects" || ok "only the 5 Prometheus objects in fct-dash are touched"
  echo "  info  core disk: $(tiny "df -h /var/lib/rancher 2>/dev/null | tail -1 | awk '{print \$4\" free of \"\$2}'")"
}

check(){
  echo "== Checks"
  tk rollout status deploy/prometheus --timeout=300s >/dev/null 2>&1 && ok "prometheus running" || { bad "prometheus not running"; echo "RESULT: FAIL ($F)"; return; }
  [ "$(tk get pvc prometheus-data -o jsonpath='{.status.phase}')" = Bound ] && ok "data volume bound" || bad "data volume not bound"
  t=$(pq /api/v1/targets | python3 -c '
import json, sys
a = json.load(sys.stdin)["data"]["activeTargets"]
for x in a: print(x["labels"].get("nf"), x["health"], (x.get("lastError") or "-")[:80])' 2>/dev/null)
  echo "$t" | sed 's/^/  info  target /'
  [ "$(echo "$t" | grep -c ' up ')" = 5 ] && ok "5 targets up (amf, smf, upf, pcf, gnb via dashboard)" || bad "targets up: $(echo "$t" | grep -c ' up ') of 5"
  # Flags as Prometheus reports them, and the retention it actually applies (runtime status).
  ret=$( { pq /api/v1/status/flags; echo; pq /api/v1/status/runtimeinfo; } | python3 -c '
import json, sys
f, r = [json.loads(l)["data"] for l in sys.stdin.read().strip().split("\n")]
print(f.get("storage.tsdb.retention.time"), f.get("storage.tsdb.retention.size"), "|", r.get("storageRetention"))' 2>&1)
  echo "  info  retention flags time/size | runtime: $ret"
  # Prometheus size units are powers of 2 and it reports --storage.tsdb.retention.size=5GB back as 5GiB.
  case "$ret" in "30d 5GiB | "*30d*5GiB*) ok "retention 30d, max 5 GiB (applied at runtime)";; *) bad "retention not as expected";; esac
  types=$(tk get svc prometheus fct-dash-metrics -o jsonpath='{.items[*].spec.type}')
  [ "$types" = "ClusterIP ClusterIP" ] && ok "Services are ClusterIP only" || bad "Service types: $types"
  tk get deploy prometheus -o jsonpath='{.spec.template.spec.containers[*].ports[*].hostPort}' | grep -q . && bad "prometheus has a hostPort" || ok "no hostPort"
  curl -s -m 3 http://10.42.0.2:9090/api/v1/status/buildinfo | grep -q '"version"' && bad "a Prometheus API answers on 10.42.0.2:9090" \
    || ok "no Prometheus API reachable from REDLAB (10.42.0.2:9090 is the AMF metrics only)"
  v=$(q 'count(up{job="open5gs"} == 1)'); [ "$v" = 4 ] && ok "Open5GS series stored: 4 NFs" || bad "Open5GS NFs up in storage: $v"
  v=$(q 'count(fct_gnb_mac_total)'); [ "$v" != none ] && ok "gNB MAC counter series stored: $v" || bad "no fct_gnb_mac_total series (UE down?)"
  v=$(q 'max(fct_ue_radio{field="cqi"})'); [ "$v" != none ] && ok "UE radio series stored (CQI $v)" || bad "no fct_ue_radio series"
  echo "  info  series per job: open5gs $(q 'count({job="open5gs"})'), fct-dash $(q 'count({job="fct-dash"})')"
  # Persistence: samples of the last hour before and after a restart of Prometheus.
  n1=$(q 'count_over_time(up{nf="amf"}[1h])')
  tk rollout restart deploy/prometheus >/dev/null && tk rollout status deploy/prometheus --timeout=180s >/dev/null; sleep 20
  n2=$(q 'count_over_time(up{nf="amf"}[1h])')
  awk -v a="$n1" -v b="$n2" 'BEGIN{exit !(a >= 3 && b >= a)}' && ok "data survives a Prometheus restart (AMF samples in the last hour: $n1 -> $n2)" \
    || bad "history lost or too short across a restart ($n1 -> $n2, want >= 3 and not lower)"
  echo "  info  stored: $(pq /api/v1/status/tsdb | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["headStats"]["numSeries"])' 2>/dev/null) series in the head block"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  core, namespace fct-dash: ConfigMap prometheus-config, PVC prometheus-data (local-path), Deployment prometheus"
  echo "  (prom/prometheus:$IMG_TAG, 30d / 5GB), Services prometheus and fct-dash-metrics (ClusterIP)"
  echo "  no change to Open5GS, the RAN or the dashboard Deployment; undo: MODE=remove (keeps data) or MODE=purge" ;;
apply)
  pre
  [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  manifest | tiny 'k3s kubectl apply -f -'
  tk rollout status deploy/prometheus --timeout=300s
  echo "collecting 60 s before the checks"; sleep 60
  F=0; check ;;
check) check ;;
remove)
  tk delete deploy/prometheus svc/prometheus svc/fct-dash-metrics configmap/prometheus-config --ignore-not-found
  echo "data volume prometheus-data kept (MODE=purge deletes it)" ;;
purge)
  read -r -p "Delete ALL stored KPI history (PVC prometheus-data)? Type yes: " a </dev/tty
  [ "$a" = yes ] || { echo "not deleted"; exit 1; }
  tk delete deploy/prometheus svc/prometheus svc/fct-dash-metrics configmap/prometheus-config --ignore-not-found
  tk delete pvc/prometheus-data --ignore-not-found ;;
*) echo "MODE must be preview, apply, check, remove or purge"; exit 1 ;;
esac
