#!/usr/bin/env bash
# Experiment N1 v6: downlink AWGN sweep through the OAI telnet server, with evidence kept.
# v6 uses the BASELINE UE (oai-nr-ue), which carries the channel model since stage A (ue-chanmod.sh);
# no second UE is deployed any more. It stops if the baseline UE has no chanmod/telnet.
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
  raw=$(gnb_stats); ue=$(kubectl logs deploy/oai-nr-ue --since=${SETTLE:-10}s 2>/dev/null)
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
  kubectl logs deploy/oai-nr-ue --timestamps --since-time="$T_START" > "$RUN/ue.log" 2>&1
  kubectl logs deploy/oai-gnb --timestamps --since-time="$T_START" > "$RUN/gnb.log" 2>&1
  log "saved: $(wc -l < "$RUN/gnb.log") gNB lines, $(wc -l < "$RUN/ue.log") UE lines in $RUN"
  kubectl scale deploy speedtest-dl --replicas=0 >/dev/null
  tn "channelmod modify 0 noise_power_dB -100" >/dev/null 2>&1
  if tn "channelmod show current" | grep -q "noise: -100"; then log "Noise back at -100 dB (baseline)"
  else log "WARNING: could not confirm noise -100 dB; check: telnet 127.0.0.1 9090, channelmod show current"; fi
  IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}')
  [ -n "$IP" ] && log "Baseline UE tunnel: $IP" || log "Baseline UE tunnel NOT up"
}
trap 'echo; echo "Interrupted"; restore; exit 130' INT TERM

say "1. Preconditions: gNB and baseline UE running, UE has the channel model and telnet"
[ "$(kubectl get deploy oai-gnb -o jsonpath='{.status.readyReplicas}')" = 1 ] || { log "STOP: gNB not running"; exit 1; }
[ "$(kubectl get deploy oai-nr-ue -o jsonpath='{.status.readyReplicas}')" = 1 ] || { log "STOP: baseline UE not running"; exit 1; }
A=$(kubectl get deploy oai-nr-ue -o jsonpath='{.spec.template.spec.containers[0].args}')
echo "$A" | grep -q '"--rfsim"' && log "rfsim flag present" || { log "STOP: no --rfsim"; exit 1; }
echo "$A" | grep -q '"chanmod"' || { log "STOP: baseline UE has no chanmod; run ue-chanmod.sh first"; exit 1; }
CUR=$(tn "channelmod show current")
echo "$CUR" | grep -q "model 0 rfsimu_channel_enB0 type AWGN" || { log "STOP: telnet/channel model not available: $(echo "$CUR" | head -1)"; exit 1; }
echo "$CUR" | grep -E "^model 0|noise" | head -2 | tee -a "$RUN/summary.txt"
kubectl scale deploy speedtest-dl speedtest-ul --replicas=0 >/dev/null
IP=$(ip -4 -o addr show oaitun_ue1 2>/dev/null | awk '{print $4}')
[ -n "$IP" ] && log "UE tunnel up: $IP" || { log "STOP: UE tunnel NOT up"; exit 1; }

echo "pass,noise_dB,rntis,sync,cqi,mcs_dl,bler_dl,goodput_dl,ue_sinr_dB" > "$RUN/points.csv"
for PASS in ${PASSES:-idle traffic}; do
  say "2. Pass '$PASS'"
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
say "Done. Copy the folder for analysis:  $RUN  (points.csv, summary.txt, raw.log, gnb.log, ue.log)"
