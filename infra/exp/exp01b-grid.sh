#!/usr/bin/env bash
# Experiment 1b, stage G1: can the gNB's T tracer show the resource grid (which PRBs and symbols are occupied) on the bench?
# The gNB gets --T_stdout 2 --T_nowait (log output stays as it is, the T tracer listens on port 2021), grid-trace.py
# turns a few events on for a short capture and prints the occupied PRBs per slot (DL txdataF, UL rxdataF) with labels.
# Run ON REDLAB from the repo root:   sudo MODE=preview bash infra/exp/exp01b-grid.sh
#   MODE=preview  preconditions only, changes nothing
#   MODE=on       firewall first: DROP TCP 2021 on every interface except lo (iptables and ip6tables, comment fct-exp01b),
#                 then the gNB with the T options, restart the UE, wait for its tunnel
#   MODE=check    captures: idle cell (SSB/PBCH), UDP DL (PDSCH), UDP UL (PUSCH); results in docs/experiments/data/
#   MODE=ra       random access: start a capture, restart the UE, catch PRACH (Msg1), RAR (Msg2), Msg3 PUSCH, Msg4
#   MODE=off      gNB back to its options without T, restart the UE, then remove the firewall rules
# Why the firewall: the T tracer always binds 0.0.0.0 (local_tracer.c) and the gNB uses the host network, so without it
# port 2021 is open on the campus WiFi and Tailscale; a tracer gets IQ and MAC PDUs (NAS, the test IMSI).
# The T options live in the Deployment spec and survive a reboot, iptables rules do not: MODE=on therefore also installs
# the systemd unit fct-exp01b-fw.service (adds the same rules at boot, before k3s); MODE=off removes it. Every mode
# fails at once if the T options are set while the rules are missing. (Learned 2026-11-03: REDLAB rebooted with the
# tracer on and no rules; port 2021 was open on the bench LAN, campus WiFi and Tailscale for about 6 days.)
# Costs while on: the gNB maps and fills a 2 GiB T cache (T_CACHE_SIZE 8192 x T_BUFFER_MAX 256 KiB).
# Limit: one DL slot must fit T_BUFFER_MAX, so captures are refused above 106 PRB (273 PRB would abort the gNB).
# Limit: the UL grid event always sends entry 0 of the 4-slot rxdataF ring, so UL grids are kept only for slot % 4 = 0
# (slot 8 of each frame in this TDD pattern); PUSCH/PUCCH/PRACH labels are kept for every slot.
# A profile switch from the Experiment 1 page rewrites the gNB options from ran.yaml and drops the T options.
# Run one mode at a time: the T tracer takes one client only, and MODE=ra restarts the UE.
# rfsim only. Do not use the dashboard controls meanwhile.
set -u
MODE=${MODE:-preview}
DIR=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$DIR/../.." && pwd)
KC="k3s kubectl"; URL=http://10.42.0.2:30880; PORT=2021; TAG=fct-exp01b
T_OPTS="--T_stdout 2 --T_nowait"
USER_NAME=${SUDO_USER:-root}
asuser(){ sudo -u "$USER_NAME" -H "$@"; }
tiny(){ asuser ssh -o BatchMode=yes -o ConnectTimeout=5 tiny "$@"; }
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
opts(){ $KC get deploy oai-gnb -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="USE_ADDITIONAL_OPTIONS")].value}'; }
prb(){ $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | sed -n 's/^ *dl_carrierBandwidth: *\([0-9]*\).*/\1/p' | head -1; }
listening(){ ss -Hltn "( sport = :$PORT )" | grep -q .; }
fw(){ for c in iptables ip6tables; do $c -C INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP 2>/dev/null || return 1; done; }
UNIT=/etc/systemd/system/$TAG-fw.service
unit(){ cat <<EOT
[Unit]
Description=Experiment 1b: OAI T tracer port $PORT only on lo (repo infra/exp/exp01b-grid.sh)
Before=k3s.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for c in iptables ip6tables; do \$\$c -C INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP 2>/dev/null || \$\$c -I INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP; done'
[Install]
WantedBy=multi-user.target
EOT
}
mem(){ awk '/MemAvailable/ {printf "%.1f", $2/1048576}' /proc/meminfo; }
tunnel(){ ip -4 -br addr show oaitun_ue1 2>/dev/null | awk '{print $3}'; }
wait_ue(){
  for i in $(seq 1 60); do [ -n "$(tunnel)" ] && break; sleep 3; done
  [ -n "$(tunnel)" ] && ok "UE tunnel up ($(tunnel))" || bad "UE tunnel not up after 3 min"
}
restart_ue(){ $KC rollout restart deploy/oai-nr-ue >/dev/null; $KC rollout status deploy/oai-nr-ue --timeout=120s >/dev/null; }
KEY=""
post(){ curl -s -m 20 -X POST "$URL$1" -H "Content-Type: application/json" -H "X-Admin-Key: $KEY" --data-binary "$2" -w ' %{http_code}'; }
start(){  # start ACTION: three tries 5 s apart (the dashboard may refuse right after a UE restart); prints its message
  local r; for i in 1 2 3; do r=$(post /api/control "{\"action\":\"$1\"}"); [ "${r##* }" = 200 ] && return 0; sleep 5; done
  echo "  info  $1: ${r% *} (HTTP ${r##* })"; return 1; }
ssb_prbs(){  # first and last PRB of the SSB from gnb.yaml: (SSB ARFCN - point A ARFCN) x 15 kHz / 360 kHz = centre PRB, +-10
  $KC get configmap oai-gnb-config -o jsonpath='{.data.gnb\.yaml}' | awk '/absoluteFrequencySSB:/{s=$2} /dl_absoluteFrequencyPointA:/{a=$2} END{c=int((s-a)*15/360); print c-10, c+9}'; }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] && ok "running with sudo as $USER_NAME" || { bad "run with sudo as your login user"; exit 1; }
  $KC get deploy oai-gnb >/dev/null 2>&1 && ok "gNB Deployment present" || bad "gNB Deployment missing"
  p=$(prb); [ -n "$p" ] && [ "$p" -le 106 ] && ok "carrier $p PRB (captures allowed up to 106)" || bad "carrier '$p' PRB: captures refused above 106"
  python3 -c 'import numpy' 2>/dev/null && ok "python3 numpy present" || bad "python3 numpy missing"
  [ -f "$REPO/grid-trace.py" ] && ok "grid-trace.py ($(sha256sum "$REPO/grid-trace.py" | cut -c1-16))" || bad "grid-trace.py missing"
  echo "  info  gNB options: $(opts)"
  echo "  info  memory available: $(mem) GiB (the T cache needs 2 GiB)"
  case "$(opts)" in *T_stdout*) echo "  info  T tracer options already set";; *) echo "  info  T tracer options not set";; esac
  fw && echo "  info  firewall rules $TAG present" || echo "  info  firewall rules $TAG not present"
  systemctl is-enabled --quiet $TAG-fw.service 2>/dev/null && echo "  info  boot unit $TAG-fw.service enabled" || echo "  info  boot unit $TAG-fw.service not installed"
  case "$(opts)" in *T_stdout*) fw && ok "T options set and port $PORT firewalled" \
    || bad "T OPTIONS SET BUT NO FIREWALL: port $PORT is open on every interface; run MODE=on (or MODE=off) now";; esac
}

capture(){  # capture NAME ARGS... -> $OUT/NAME.txt and .json
  python3 "$REPO/grid-trace.py" --prb "$(prb)" --json "$OUT/$1.json" "${@:2}" > "$OUT/$1.txt" 2>&1; local rc=$?
  head -1 "$OUT/$1.txt" | sed 's/^/  info  /'; return $rc
}
rows(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); exec(sys.argv[2])' "$OUT/$1.json" "$2" "${@:3}"; }  # rows NAME CODE [ARGS -> sys.argv[3:]]

case "$MODE" in
preview) pre ;;
on)
  pre; case "$(opts)" in *T_stdout*) fw || F=$((F-1));; esac   # T set without rules is what this mode repairs
  [ $F = 0 ] || { echo "RESULT: FAIL ($F)"; exit 1; }
  echo "== Firewall: TCP $PORT only on lo"
  for c in iptables ip6tables; do
    $c -C INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP 2>/dev/null \
      || $c -I INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP
  done
  fw && ok "DROP rules for TCP $PORT (not lo) in iptables and ip6tables" || { bad "firewall rules not set"; echo "RESULT: FAIL ($F)"; exit 1; }
  unit > "$UNIT" && systemctl daemon-reload && systemctl enable --quiet $TAG-fw.service \
    && ok "boot unit $TAG-fw.service enabled (rules come back before k3s after a reboot)" || { bad "boot unit not installed"; echo "RESULT: FAIL ($F)"; exit 1; }
  echo "== gNB with the T tracer"
  m0=$(mem); o=$(opts)
  case "$o" in *T_stdout*) ok "T options already set";; *) $KC set env deploy/oai-gnb USE_ADDITIONAL_OPTIONS="$o $T_OPTS" >/dev/null && ok "gNB options: $o $T_OPTS";; esac
  $KC rollout status deploy/oai-gnb --timeout=180s >/dev/null && ok "gNB rolled out" || bad "gNB rollout"
  for i in $(seq 1 30); do listening && break; sleep 2; done
  listening && ok "T tracer listens on $PORT" || bad "nothing listens on $PORT"
  restart_ue; wait_ue
  echo "  info  memory available: $m0 GiB before, $(mem) GiB now"
  r=$(tiny "timeout 3 bash -c '</dev/tcp/10.42.0.1/$PORT' && echo open || echo closed" 2>/dev/null)
  [ "$r" = closed ] && ok "port $PORT closed from the core host (10.42.0.1 over the bench LAN)" || bad "port $PORT reachable from the core host ($r)"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
check)
  pre
  fw && ok "firewall rules present" || { bad "firewall rules missing: run MODE=on first"; echo "RESULT: FAIL ($F)"; exit 1; }
  listening && ok "T tracer listening" || { bad "T tracer not listening: run MODE=on first"; echo "RESULT: FAIL ($F)"; exit 1; }
  [ -n "$(tunnel)" ] && ok "UE tunnel up ($(tunnel))" || bad "UE tunnel down"
  KEY=$(tiny "k3s kubectl -n fct-dash get secret fct-dash-admin -o jsonpath='{.data.password}'" 2>/dev/null | base64 -d)
  [ -n "$KEY" ] || { bad "cannot read the admin password Secret on the core"; echo "RESULT: FAIL ($F)"; exit 1; }
  OUT=$REPO/docs/experiments/data/bench-grid-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"; chown "$USER_NAME" "$OUT"
  echo "== G1a idle cell: 40 slots (20 ms, one SSB period)"
  capture idle --slots 40 && ok "capture idle" || bad "capture idle failed: $(tail -1 "$OUT/idle.txt")"
  read s0 s1 < <(ssb_prbs); echo "  info  SSB expected at PRB $s0-$s1 (from absoluteFrequencySSB and point A in gnb.yaml)"
  rows idle '
r = d["rows"]; dl = [x for x in r if x["dir"] == "dl" and x["nPrb"]]; mib = [x for x in r if any(l["ch"] == "SSB/PBCH" for l in x["labels"])]
print("  info  %d DL slots with energy; SSB/PBCH in %s" % (len(dl), ", ".join("%d.%d PRB %s symbols %s" % (x["frame"], x["slot"], x["prbs"], x["symbols"]) for x in mib) or "none"))
# a slot with SSB and PDSCH shows all PRBs occupied, so one SSB slot at exactly the predicted PRBs is enough
sys.exit(0 if any(x["prbs"] == "%s-%s" % tuple(sys.argv[3:5]) for x in mib) else 1)' "$s0" "$s1" && ok "idle: SSB/PBCH at the PRBs predicted from the configuration ($s0-$s1)" || bad "idle: SSB/PBCH not at PRB $s0-$s1"
  echo "== G1b UDP downlink: PDSCH"
  start speed-dl-udp && ok "UDP DL started" || bad "UDP DL not started"
  sleep 12
  capture dl --slots 20 && ok "capture dl" || bad "capture dl failed: $(tail -1 "$OUT/dl.txt")"
  post /api/control '{"action":"speed-stop"}' >/dev/null
  rows dl '
r = [x for x in d["rows"] if x["dir"] == "dl"]; pd = [x for x in r if any(l["ch"] == "PDSCH" for l in x["labels"])]
full = [x for x in pd if x["nPrb"] >= 0.9 * d["nrb"]]
print("  info  %d DL slots, %d with PDSCH, %d of those use >= 90 %% of the PRBs; e.g. %s" % (len(r), len(pd), len(full), pd[0]["prbs"] if pd else "-"))
sys.exit(0 if len(full) >= 3 else 1)' && ok "DL: PDSCH fills the carrier in at least 3 slots" || bad "DL: PDSCH does not fill the carrier"
  sleep 5
  echo "== G1c UDP uplink: PUSCH (label rb_start/rb_size vs the received grid; UL grids only in slots with slot % 4 = 0)"
  start speed-ul-udp && ok "UDP UL started" || bad "UDP UL not started"
  sleep 12
  capture ul --slots 80 && ok "capture ul" || bad "capture ul failed: $(tail -1 "$OUT/ul.txt")"
  post /api/control '{"action":"speed-stop"}' >/dev/null
  rows ul '
g = {(x["frame"], x["slot"]): x for x in d["grids"] if x["dir"] == "ul"}
match, n = 0, 0
for x in d["rows"]:
    for l in x["labels"]:
        if l["ch"] != "PUSCH" or (x["frame"], x["slot"]) not in g: continue
        n += 1; db = g[(x["frame"], x["slot"])]["db"]; a, b = l["rb"]; s0, s1 = l["sym"]
        mean = lambda p: sum(db[p][s0:s1 + 1]) / (s1 - s0 + 1)            # per PRB, over the PUSCH symbols
        inside = min(mean(p) for p in range(a, b + 1))
        outside = [mean(p) for p in range(d["nrb"]) if p < a or p > b]
        ok = inside > 20 and (not outside or max(outside) < inside - 10)
        match += ok
        if n <= 3: print("  info  %d.%d PUSCH rnti %s PRB %d-%d symbols %d-%d: energy inside %.0f dB, outside max %s dB" % (x["frame"], x["slot"], l["rnti"], a, b, s0, s1, inside, "%.0f" % max(outside) if outside else "-"))
print("  info  %d of %d PUSCH labels match the received grid" % (match, n))
sys.exit(0 if n and match == n else 1)' && ok "UL: every PUSCH label matches the energy in the received grid" || bad "UL: PUSCH labels and grid differ"
  gl=$($KC logs deploy/oai-gnb --since=10m 2>/dev/null | grep -c "T tracer: WARNING" ); echo "  info  T tracer memory warnings in the gNB log (10 min): $gl"
  echo "  info  memory available: $(mem) GiB; results in ${OUT#$REPO/}"
  chown -R "$USER_NAME" "$OUT"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
ra)
  pre
  fw && listening || { bad "run MODE=on first"; echo "RESULT: FAIL ($F)"; exit 1; }
  OUT=$REPO/docs/experiments/data/bench-grid-ra-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
  echo "== G1d random access: capture armed, UE restarted"
  python3 "$REPO/grid-trace.py" --prb "$(prb)" --ra-wait 120 --slots 80 --json "$OUT/ra.json" > "$OUT/ra.txt" 2>&1 &
  cap=$!; sleep 2
  $KC rollout restart deploy/oai-nr-ue >/dev/null
  wait $cap && ok "capture from the random access on" || bad "capture failed: $(tail -1 "$OUT/ra.txt")"
  head -1 "$OUT/ra.txt" | sed 's/^/  info  /'
  [ -f "$OUT/ra.json" ] && python3 -c '
import json, sys
d = json.load(open(sys.argv[1])); ev = []                     # rows are in arrival (time) order
for x in d["rows"]:
    for l in x["labels"]:
        ev.append((x["frame"], x["slot"], l))
def first(pred, after=-1):
    return next(((i, e) for i, e in enumerate(ev) if i > after and pred(e[2])), (None, None))
i1, m1 = first(lambda l: l["ch"] == "PRACH")
i2, m2 = first(lambda l: l["ch"] == "RAR", i1 if i1 is not None else -1)
i3, m3 = first(lambda l: l["ch"] == "PUSCH", i2 if i2 is not None else 1 << 30)
tc = m3[2]["rnti"] if m3 else None
i4, m4 = first(lambda l: l["ch"] == "DL-PDU" and l["rnti"] == tc, i3 if i3 is not None else 1 << 30)
for n, m in (("Msg1 PRACH", m1), ("Msg2 RAR", m2), ("Msg3 PUSCH", m3), ("Msg4 PDSCH", m4)):
    print("  info  %-11s %s" % (n, "%d.%d %s" % (m[0], m[1], {k: v for k, v in m[2].items() if k != "ch"}) if m else "-"))
g = [x for x in d["grids"] if x["dir"] == "ul"]
print("  info  UL grids (slot %% 4 = 0): %d; PUCCH labels: %d (rare in rfsim: sent only with a PUCCH SNR)" % (len(g), sum(e[2]["ch"] == "PUCCH" for e in ev)))
sys.exit(0 if m1 and m2 and m3 and m4 else 1)' "$OUT/ra.json" \
    && ok "random access Msg1-Msg4 in order: PRACH, RAR, Msg3 PUSCH (TC-RNTI), Msg4 to the same RNTI" || bad "random access steps missing"
  $KC rollout status deploy/oai-nr-ue --timeout=120s >/dev/null; wait_ue
  chown -R "$USER_NAME" "$OUT"; echo "  info  results in ${OUT#$REPO/}"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
off)
  pre
  o=$(opts); n=$(echo "$o" | sed 's/ *--T_stdout [0-9]//; s/ *--T_nowait//')
  if [ "$o" != "$n" ]; then
    $KC set env deploy/oai-gnb USE_ADDITIONAL_OPTIONS="$n" >/dev/null && ok "gNB options: $n"
    $KC rollout status deploy/oai-gnb --timeout=180s >/dev/null && ok "gNB rolled out" || bad "gNB rollout"
    restart_ue; wait_ue
  else
    ok "gNB has no T options"
  fi
  for i in $(seq 1 15); do listening || break; sleep 2; done
  listening && bad "something still listens on $PORT" || ok "nothing listens on $PORT"
  if listening; then
    echo "  info  keeping the firewall rules and the boot unit while something listens on $PORT"
  else
    for c in iptables ip6tables; do while $c -D INPUT -p tcp --dport $PORT ! -i lo -m comment --comment $TAG -j DROP 2>/dev/null; do :; done; done
    fw && bad "firewall rules still present" || ok "firewall rules $TAG removed"
    systemctl disable --quiet $TAG-fw.service 2>/dev/null; rm -f "$UNIT"; systemctl daemon-reload
    [ -f "$UNIT" ] && bad "boot unit still present" || ok "boot unit $TAG-fw.service removed"
  fi
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")" ;;
*) echo "MODE must be preview, on, check, ra or off"; exit 1 ;;
esac
