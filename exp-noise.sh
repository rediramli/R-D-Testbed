#!/usr/bin/env bash
# Experiment N1 v5: downlink AWGN sweep through the OAI telnet server, with evidence kept.
# Runs ON FCT0173:   ssh fct0173 'bash -s' < exp-noise.sh      (or ssh ubuntu@10.0.129.7 ...)
# Two passes over the same noise points: first WITHOUT traffic, then WITH the DL speed test.
# Each point records gNB-side (RNTI, sync state, CQI, MCS, BLER, goodput) and UE-side (SINR) values.
# A pass stops at the first sign of link loss: RNTI changed, UE out-of-sync, or (traffic pass) goodput < 1.
# Everything is saved under ~/fct-testbed/exp-noise/run-<time>/ BEFORE anything is restored.
# Options (env): SWEEP="-12 -11.5 ..." SETTLE=10 PASSES="idle traffic"
set -u
RUN=~/fct-testbed/exp-noise/run-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$RUN"; cd ~/fct-testbed/exp-noise
T_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
say(){ printf '\n== %s  (%s UTC)\n' "$1" "$(date -u +%T)" | tee -a "$RUN/summary.txt"; }
log(){ echo "$*" | tee -a "$RUN/summary.txt"; }

tn(){  # tn "command" -> output of one OAI telnet command on the AWGN UE (localhost only)
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

gnb_stats(){ kubectl exec deploy/oai-gnb -- cat /opt/oai-gnb/nrMAC_stats.log 2>/dev/null; }
point(){  # point NOISE PASS -> one CSV row; raw stats appended to raw.log
  local raw ue
  raw=$(gnb_stats); ue=$(kubectl logs deploy/oai-nr-ue-awgn --since=${SETTLE:-10}s 2>/dev/null)
  { echo "### pass=$2 noise=$1 t=$(date -u +%T)"; echo "$raw"; } >> "$RUN/raw.log"
  python3 -c '
import re, sys
raw, ue, noise, pss = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
g = lambda p, t=raw: (re.search(p, t) or [None, ""])[1]
rntis = re.findall(r"UE RNTI ([0-9a-f]{4})", raw)
sync = g(r"UE RNTI [0-9a-f]{4}.*?\b(in-sync|out-of-sync)\b")
sinr = re.findall(r"SINR ([-\d.]+) dB", ue)
print(",".join([pss, noise, " ".join(rntis), sync,
  g(r"CQI (\d+)"), g(r"dlsch_rounds.*?MCS \(\d+\) (\d+)"), g(r"dlsch_rounds.*?BLER ([\d.]+)"),
  g(r"goodput DL\s+([\d.]+)"), sinr[-1] if sinr else ""]))' "$raw" "$ue" "$1" "$2"
}

restore(){
  say "Restore the baseline (logs saved first)"
  kubectl logs deploy/oai-nr-ue-awgn --timestamps > "$RUN/ue-awgn.log" 2>&1
  kubectl logs deploy/oai-gnb --timestamps --since-time="$T_START" > "$RUN/gnb.log" 2>&1
  log "saved: $(wc -l < "$RUN/gnb.log") gNB lines, $(wc -l < "$RUN/ue-awgn.log") UE lines in $RUN"
  tn "channelmod modify 0 noise_power_dB -100" >/dev/null 2>&1
  kubectl scale deploy speedtest-dl oai-nr-ue-awgn --replicas=0 >/dev/null
  kubectl wait --for=delete pod -l app=oai-nr-ue-awgn --timeout=60s >/dev/null 2>&1 || true
  for i in $(seq 1 20); do ip link show oaitun_ue1 >/dev/null 2>&1 || break; sleep 1; done
  kubectl scale deploy oai-nr-ue --replicas=1 >/dev/null
  for i in $(seq 1 45); do ip -4 addr show oaitun_ue1 2>/dev/null | grep -q "inet " && break; sleep 2; done
  IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}')
  [ -n "$IP" ] && log "Baseline UE back: $IP" || log "Baseline UE NOT back (gNB replicas: $(kubectl get deploy oai-gnb -o jsonpath='{.status.readyReplicas}'))"
}
trap 'echo; echo "Interrupted"; restore; exit 130' INT TERM

say "1. AWGN UE config and Deployment (baseline untouched)"
kubectl get cm oai-ue-config -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)["data"]
ue = cm["ue.conf"].replace("channelmod_rfsimu_LEO_satellite.conf", "channelmod_awgn.conf")
awgn = """channelmod = {
  max_chan = 10;
  modellist = "modellist_rfsimu_1";
  modellist_rfsimu_1 = (
    { model_name = "rfsimu_channel_enB0"; type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; },
    { model_name = "rfsimu_channel_ue0";  type = "AWGN"; ploss_dB = 0; noise_power_dB = -100; }
  );
};
"""
print(json.dumps({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "oai-ue-config-awgn", "namespace": "default"},
                  "data": {"ue.conf": ue, "channelmod_awgn.conf": awgn}}))' | kubectl apply -f -
python3 - <<'PY' > ue-awgn-deploy.json
import json
d = json.load(open("../ran/oai-nr-ue-deploy.json"))
d["metadata"]["name"] = "oai-nr-ue-awgn"
d["metadata"]["labels"] = {"app": "oai-nr-ue-awgn"}
d["spec"]["selector"]["matchLabels"] = {"app": "oai-nr-ue-awgn"}
d["spec"]["template"]["metadata"]["labels"] = {"app": "oai-nr-ue-awgn"}
d["spec"]["replicas"] = 0
c = d["spec"]["template"]["spec"]["containers"][0]
c["args"] += ["--rfsimulator.options", "chanmod",
              "--telnetsrv", "--telnetsrv.listenaddr", "127.0.0.1", "--telnetsrv.listenport", "9090"]
for v in d["spec"]["template"]["spec"]["volumes"]:
    if v.get("configMap", {}).get("name") == "oai-ue-config":
        v["configMap"]["name"] = "oai-ue-config-awgn"
        for it in v["configMap"].get("items", []):
            if it["key"].startswith("channelmod"):
                it["key"] = it["path"] = "channelmod_awgn.conf"
print(json.dumps(d, indent=1))
PY
grep -q '"--rfsim"' ue-awgn-deploy.json && log "rfsim flag present" || { log "STOP: no --rfsim"; exit 1; }
kubectl apply -f ue-awgn-deploy.json

say "2. Swap the baseline UE for the AWGN UE"
if [ "$(kubectl get deploy oai-gnb -o jsonpath='{.status.readyReplicas}')" != 1 ]; then
  log "gNB was off, starting it"; kubectl scale deploy oai-gnb --replicas=1 >/dev/null; sleep 15
fi
kubectl scale deploy speedtest-dl speedtest-ul oai-nr-ue --replicas=0 >/dev/null
kubectl wait --for=delete pod -l app=oai-nr-ue --timeout=60s >/dev/null 2>&1 || true
for i in $(seq 1 20); do ip link show oaitun_ue1 >/dev/null 2>&1 || break; sleep 1; done
kubectl scale deploy oai-nr-ue-awgn --replicas=1 >/dev/null
for i in $(seq 1 45); do ip -4 addr show oaitun_ue1 2>/dev/null | grep -q "inet " && break; sleep 2; done
IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}')
[ -n "$IP" ] && log "UE tunnel up: $IP" || { log "STOP: UE tunnel NOT up"; restore; exit 1; }
tn "channelmod show current" | grep -E "^model 0|noise" | head -2 | tee -a "$RUN/summary.txt"

echo "pass,noise_dB,rntis,sync,cqi,mcs_dl,bler_dl,goodput_dl,ue_sinr_dB" > "$RUN/points.csv"
for PASS in ${PASSES:-idle traffic}; do
  say "3. Pass '$PASS'"
  tn "channelmod modify 0 noise_power_dB -100" >/dev/null; sleep 5
  if [ "$PASS" = traffic ]; then
    kubectl scale deploy speedtest-dl --replicas=1 >/dev/null
    gp(){ gnb_stats | grep -oE "goodput DL +[0-9.]+" | awk '{print int($3)}' | head -1; }
    ok=0; for i in $(seq 1 30); do [ "$(gp)" -gt 50 ] 2>/dev/null && { ok=1; break; }; sleep 2; done
    [ $ok = 1 ] || { log "STOP: no DL traffic at clean channel (goodput $(gp))"; break; }
  fi
  base=$(point -100 "$PASS"); echo "$base" >> "$RUN/points.csv"; log "clean    | $base"
  R0=$(echo "$base" | cut -d, -f3)
  for n in ${SWEEP:--12 -11.5 -11 -10.5 -10 -9.5 -9 -8.5 -8}; do
    tn "channelmod modify 0 noise_power_dB $n" >/dev/null
    sleep ${SETTLE:-10}
    row=$(point "$n" "$PASS"); echo "$row" >> "$RUN/points.csv"
    printf 'noise %5s | %s\n' "$n" "$row" | tee -a "$RUN/summary.txt"
    IFS=, read -r _ _ rn sy _ _ _ gpd _ <<< "$row"
    why=""
    [ "$rn" != "$R0" ] && why="RNTI changed ($R0 -> $rn): UE re-attached or a second context appeared"
    [ "$sy" = out-of-sync ] && why="gNB reports the UE out-of-sync"
    [ "$PASS" = traffic ] && awk "BEGIN{exit !(${gpd:-0} < 1)}" && why="${why:+$why; }goodput below 1 Mbit/s"
    [ -n "$why" ] && { log "LINK LOSS at $n dB: $why"; break; }
  done
  kubectl scale deploy speedtest-dl --replicas=0 >/dev/null
  tn "channelmod modify 0 noise_power_dB -100" >/dev/null
  # give a dropped UE up to 60 s to come back before the next pass
  for i in $(seq 1 30); do sleep 2; r=$(point -100 recover | cut -d, -f3); [ -n "$r" ] && [ "$(echo $r | wc -w)" = 1 ] && break; done
  log "after pass '$PASS', at -100 dB: RNTI ${r:-none}"
done

trap - INT TERM
restore
say "Done. Copy the folder for analysis:  $RUN  (points.csv, summary.txt, raw.log, gnb.log, ue-awgn.log)"
