#!/usr/bin/env bash
# Stage A (v2) of the noise presets: give the BASELINE UE the OAI channel model (AWGN,
# noise -100 dB = no effect) and a telnet server on 127.0.0.1:9090, so the noise can later
# be changed without swapping UEs. rfsim only: aborts if --rfsim is missing.
#
# v2 changes the SOURCE file that lab0-run.sh applies (~/fct-testbed/ran/oai-nr-ue-deploy.json),
# because lab0 re-creates the UE from it (v1 changed only the live objects and lab0 undid it).
# ue.conf and the ConfigMap oai-ue-config (they hold SIM data) are NOT touched:
#   - new ConfigMap oai-ue-chanmod holds only the AWGN model (no secrets)
#   - the UE config volume becomes a projected volume: nr-ue.conf from oai-ue-config, and the
#     AWGN model at the path ue.conf already includes (channelmod_rfsimu_LEO_satellite.conf).
#     The file name is historical; its content is the AWGN model.
#
# Runs ON FCT0173:   ssh fct0173 'MODE=preview bash -s' < ue-chanmod.sh
#   MODE=preview   show what would change (names, args, volumes; never config contents)
#   MODE=apply     back up, write the files, apply them like lab0 does, then run the test
#   MODE=check     the test: lab0-run.sh (T0.4-T0.7) and then the chanmod checks; RESULT: PASS/FAIL
#   MODE=rollback  restore the newest backup of oai-nr-ue-deploy.json and apply it
# Backups stay on FCT0173 in ~/fct-testbed/backup/ (never copy them off).
set -u
MODE=${MODE:-preview}
T=~/fct-testbed; SRC=$T/ran/oai-nr-ue-deploy.json; CMF=$T/ran/oai-ue-chanmod.yaml; BK=$T/backup
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
INC=channelmod_rfsimu_LEO_satellite.conf      # the file name ue.conf includes (line 40 of oai-ue-config.yaml)

tn(){  # tn "command" -> output of one OAI telnet command on the UE (localhost only)
python3 - "$1" <<'PY'
import socket, sys, time
try:
    s = socket.create_connection(("127.0.0.1", 9090), 3)
except OSError as e:
    print("TELNET CONNECT FAILED:", e); sys.exit(0)
s.settimeout(1)
def drain():
    out = b""
    try:
        while True:
            d = s.recv(65536)
            if not d: break
            out += d
    except Exception:
        pass
    return out.decode(errors="replace")
time.sleep(0.4); drain()
s.sendall((sys.argv[1] + "\n").encode()); time.sleep(0.8)
print(drain().strip()); s.close()
PY
}

write_cm(){  # $1 = output file: ConfigMap with only the AWGN model
cat > "$1" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: oai-ue-chanmod
  namespace: default
data:
  channelmod_awgn.conf: |
    channelmod = {
      max_chan = 10;
      modellist = "modellist_rfsimu_1";
      modellist_rfsimu_1 = (
        { model_name = "rfsimu_channel_enB0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; },
        { model_name = "rfsimu_channel_ue0";  type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; }
      );
    };
EOF
}

transform(){  # $SRC -> $WORK/deploy.new.json ; summary on stdout (no config contents)
[ -f "$SRC" ] || { echo "STOP: $SRC not found"; return 1; }
python3 - "$SRC" "$WORK/deploy.new.json" "$INC" <<'PY'
import json, sys
src, out, inc = sys.argv[1:4]
d = json.load(open(src)); s = d["spec"]["template"]["spec"]; c = s["containers"][0]
args = c.get("args", [])
if "--rfsim" not in args:
    sys.exit("STOP: --rfsim missing from oai-nr-ue args; refusing to touch a non-rfsim UE")
new_args = ["--rfsimulator.options", "chanmod", "--telnetsrv",
            "--telnetsrv.listenaddr", "127.0.0.1", "--telnetsrv.listenport", "9090"]
if "--telnetsrv" in args:
    print("args: chanmod/telnet already present")
else:
    c["args"] = args + new_args
    print("args added:", " ".join(new_args))
vols = s.get("volumes", [])
if any(v["name"] == "ue-config" for v in vols):
    print("volume ue-config already present")
else:
    old = next((v for v in vols if v.get("configMap", {}).get("name") == "oai-ue-config"), None)
    if old is None:
        sys.exit("STOP: no volume from ConfigMap oai-ue-config found")
    items = old["configMap"].get("items", [])
    keep = [it for it in items if not it["key"].startswith("channelmod")]
    if not any(it["key"] == "ue.conf" for it in keep):
        sys.exit("STOP: ue.conf item not found in the oai-ue-config volume")
    new = {"name": "ue-config", "projected": {"defaultMode": old["configMap"].get("defaultMode", 420), "sources": [
        {"configMap": {"name": "oai-ue-config", "items": keep}},
        {"configMap": {"name": "oai-ue-chanmod", "items": [{"key": "channelmod_awgn.conf", "path": inc}]}}]}}
    vols[vols.index(old)] = new
    n = 0
    for m in c.get("volumeMounts", []):
        if m["name"] == old["name"]:
            m["name"] = "ue-config"; n += 1
    if n != 1:
        sys.exit(f"STOP: expected 1 volumeMount of volume {old['name']}, found {n}")
    print(f"volume '{old['name']}' (configMap oai-ue-config) -> 'ue-config' (projected):")
    print("   from oai-ue-config :", ", ".join(f"{i['key']}->{i['path']}" for i in keep))
    print(f"   from oai-ue-chanmod: channelmod_awgn.conf->{inc}")
    print("   dropped item        :", ", ".join(f"{i['key']}->{i['path']}" for i in items if i not in keep) or "-")
    print("volumeMount renamed to ue-config, mountPath unchanged:",
          [m["mountPath"] for m in c["volumeMounts"] if m["name"] == "ue-config"])
print("strategy:", d["spec"].get("strategy", {}).get("type"), "| replicas in file:", d["spec"].get("replicas"))
json.dump(d, open(out, "w"), indent=1)
PY
}

wait_tunnel(){ for _ in $(seq 1 45); do ip -4 addr show oaitun_ue1 2>/dev/null | grep -q "inet " && return 0; sleep 2; done; return 1; }

check(){
  local F=0 gp a L s st r lab
  ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
  echo "== test 1: lab0-run.sh re-creates the UE from the source file (T0.9 = X410 is ignored while it is off)"
  lab=$($T/lab0-run.sh 2>&1)
  for t in "T0.4" "T0.5" "T0.6" "T0.7"; do
    l=$(echo "$lab" | grep -E "^(PASS|FAIL) $t " | head -1)
    case "$l" in PASS*) ok "lab0 ${l#PASS }";; *) bad "lab0 $t: ${l:-missing}";; esac
  done
  echo "== test 2: chanmod on the UE that lab0 created"
  a=$(kubectl get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}')
  echo "$a" | grep -q '"--rfsim"' && ok "--rfsim present" || bad "--rfsim missing"
  echo "$a" | grep -q '"chanmod"' && echo "$a" | grep -q '"127.0.0.1"' && ok "chanmod + telnet on 127.0.0.1 in args" || bad "chanmod/telnet args missing"
  [ "$(kubectl get deploy oai-nr-ue -o jsonpath='{.status.readyReplicas}')" = 1 ] && ok "oai-nr-ue ready" || bad "oai-nr-ue not ready"
  wait_tunnel && ok "tunnel $(ip -4 -o addr show oaitun_ue1 | awk '{print $4}')" || bad "tunnel oaitun_ue1 not up"
  L=$(ss -Htln '( sport = :9090 )' | awk '{print $4}' | sort -u | tr '\n' ' ')
  [ "$L" = "127.0.0.1:9090 " ] && ok "telnet listens only on 127.0.0.1:9090" || bad "telnet listeners: '${L}' (want only 127.0.0.1:9090)"
  s=$(tn "channelmod show current")
  echo "$s" | grep -q "model 0 rfsimu_channel_enB0 type AWGN" && echo "$s" | grep -q "noise: -100" \
    && ok "channel model 0 = AWGN, noise -100 dB" || bad "channel model not as expected: $(echo "$s" | head -2 | tr '\n' ' ')"
  st=$(kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null)
  r=$(echo "$st" | grep -oE "UE RNTI [0-9a-f]{4}" | sort -u | wc -l)
  [ "$r" = 1 ] && echo "$st" | grep -q "in-sync" && ok "gNB sees 1 UE, in-sync" || bad "gNB sees $r UE contexts"
  kubectl scale deploy speedtest-ul --replicas=0 >/dev/null; kubectl scale deploy speedtest-dl --replicas=1 >/dev/null
  gp=0; for _ in $(seq 1 30); do sleep 2
    gp=$(kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null | grep -oE "goodput DL +[0-9.]+" | awk '{print int($3)}' | head -1)
    [ "${gp:-0}" -ge 70 ] 2>/dev/null && break; done
  kubectl scale deploy speedtest-dl --replicas=0 >/dev/null
  [ "${gp:-0}" -ge 70 ] 2>/dev/null && ok "DL goodput ${gp} Mbit/s (>= 70, noise off)" || bad "DL goodput only ${gp:-0} Mbit/s (want >= 70)"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo FAIL) ($F failed)"
  return $F
}

case "$MODE" in
preview)
  echo "== preview (nothing is changed)"
  transform || exit 1
  write_cm "$WORK/cm.yaml"; echo "new file $CMF: ConfigMap oai-ue-chanmod with key channelmod_awgn.conf (AWGN, -100 dB)"
  kubectl apply --dry-run=server -f "$WORK/cm.yaml" >/dev/null && echo "server dry-run ConfigMap: OK" || echo "server dry-run ConfigMap: FAILED"
  kubectl apply --dry-run=server -f "$WORK/deploy.new.json" >/dev/null && echo "server dry-run Deployment: OK" || echo "server dry-run Deployment: FAILED"
  ;;
apply)
  echo "== apply"
  transform || exit 1
  B=$BK/ue-chanmod-v2-$(date -u +%Y%m%dT%H%M%SZ); (umask 077; mkdir -p "$B"); cp "$SRC" "$B/oai-nr-ue-deploy.json"
  echo "backup of the source file: $B"
  write_cm "$CMF"; cp "$WORK/deploy.new.json" "$SRC"; echo "wrote $CMF and $SRC"
  kubectl scale deploy speedtest-dl speedtest-ul --replicas=0 >/dev/null
  kubectl apply -f "$CMF" && kubectl apply -f "$SRC" || { echo "STOP: apply failed; run MODE=rollback"; exit 1; }
  check ;;
check)
  check ;;
rollback)
  B=$(ls -d $BK/ue-chanmod-v2-* 2>/dev/null | tail -1); [ -n "$B" ] || { echo "no v2 backup found"; exit 1; }
  echo "== rollback from $B"
  kubectl scale deploy speedtest-dl speedtest-ul --replicas=0 >/dev/null
  cp "$B/oai-nr-ue-deploy.json" "$SRC" && kubectl apply -f "$SRC" && echo "source file restored and applied"
  echo "(ConfigMap oai-ue-chanmod is left in place; it is unused after rollback)"
  echo "verify with: ~/fct-testbed/lab0-run.sh" ;;
*) echo "unknown MODE=$MODE"; exit 2 ;;
esac
