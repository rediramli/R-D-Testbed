# Experiment 16 (feasibility): a second gNB built on OCUDU

Status: **feasibility study** (2026-11-03). Desk study only; nothing was installed or changed on the bench.
Question: can the bench get a second gNB, built on OCUDU (the Linux Foundation successor of the srsRAN Project), next to
the OAI cell, on the same Open5GS core? Answer: **yes**, as a separate cell with its own UE and its own virtual radio
(ZMQ), not as a handover neighbour of the OAI cell. Recommended host: the Jetson Orin NX (10.42.0.3, arm64), not REDLAB.

## Summary
| Question | Answer |
|---|---|
| Current OCUDU release | **26.10** (tag `release_26_10`, commit `e0db566a`, 2026-09-30). Previous: 26.04 (2026-03-31, first OCUDU release). Incremental, not LTS |
| License | **BSD-3-Clause-Open-MPI** (permissive; srsRAN Project was AGPLv3). Code on `gitlab.com/ocudu/ocudu`, docs on `docs.ocudu.org` |
| Virtual radio | ZMQ (`ru_sdr.device_driver: zmq`), sample streams over ZeroMQ REQ/REP. Not compatible with OAI rfsim, so the OAI cell's UE cannot see it |
| Which UE | **Two options.** (a) **OAI nrUE with its ZMQ radio** (`oai_zmqdevif`, in OAI since 2026.w17; OCUDU documents it for OAI ≥ 2026.w25). Our pinned `oai-nr-ue:2026.w40` image already ships `liboai_zmqdevif.so`, for amd64 and arm64. (b) **srsUE** (srsRAN 4G `release_25_10`): 15 kHz SCS only, so FDD bands only (e.g. n3), 5/10/15/20 MHz, no handover, maintenance mode |
| Correction to the starting assumption | "OAI nrUE cannot attach to OCUDU" is no longer true: it cannot attach **through rfsim**, but it can through ZMQ. This allows a like-for-like comparison with the same UE software on both cells |
| Core | Same Open5GS 2.8.0 on tiny: N2 SCTP to 10.42.0.2:38412, N3 GTP-U 2152. Distinct gNB ID and PCI, same PLMN 001/70, TAC 1, SST 1, DNN `fctoai`. Needs a second subscriber (`ue2`) |
| Where to run | Jetson Orin NX 10.42.0.3: OCUDU publishes arm64 images (`neon` variant, built for `neoverse-n1+crc+crypto+ssbs`), and the OAI UE image is multi-arch. REDLAB (about 23 of 30 GB used, UE simulation already CPU-heavy) is not recommended |
| Metrics for the dashboard | JSON metrics over the **remote-control WebSocket** (`metrics_subscribe`, default port 8001), per layer (MAC, scheduler, RLC, PDCP, NGAP, RRC, PHY/RU, CPU usage). OCUDU ships a Telegraf + InfluxDB + Grafana stack; for us a small relay to Prometheus fits better. Our KPI pipeline and the T-tracer resource grid are OAI-only |
| E2 | Built-in E2 agent: **E2SM-KPM** (report styles 1-5 and 255, 27 metrics) and **E2SM-RC** (control style 2 only). Documented with FlexRIC and the O-RAN SC near-RT RIC. Fits Experiment 12 as a second, different E2 node |
| O1 | OCUDU has its own O1 adapter (Python sidecar: NETCONF CM and FM, PM from the JSON metrics, TS 32.435 files + VES `notifyFileReady`) and a Helm chart `onap-smo-lite`. More complete than the OAI o1-adapter studied in [EXP-12a](EXP-12a-smo-o1-feasibility.md) |
| Verdict | **Feasible.** Main open points: the Jetson's RAM variant and current use, whether the published `neon` image runs on Orin's Cortex-A78AE, whether the published images contain the ZMQ driver, and ZMQ interop between OAI w40 and OCUDU 26.10 |

## 1. OCUDU in short
- **What it is**: a 5G CU/DU (gNB) in C++ from Software Radio Systems, continued from the srsRAN Project under the
  Linux Foundation (OCUDU Ecosystem Foundation; founding members include AMD, AT&T, Ericsson, Nokia, NVIDIA, SoftBank,
  SRS, Verizon). Applications: `gnb` (monolithic), `ocu`/`ocucp`/`ocuup` and `odu` (split), `ru_emulator`.
- **Releases** (GitLab tags): `release_26_04` (2026-03-30), `release_26_10` (2026-09-30). The 26.10 changelog adds
  Release 17 NTN, 8T8R, Type-II CSI, 2-step RA, UL configured grant type 1, DTLS, beam management. 26.04 brought
  Xn and conditional handover, UL MIMO, RRC_INACTIVE, FR2 120 kHz, RoHC, and O1 through helper elements. Since 25.10
  metrics and remote commands go over a WebSocket.
- **Radios**: UHD (USRP, split 8), DPDK Open Fronthaul (split 7.2), ZMQ (virtual) and a realtime loopback.
  For this bench only ZMQ is relevant (no over-the-air transmission, same rule as the OAI cell).
- **License consequence**: BSD-style, so our own configs, scripts and any relay code can stay under the repo's terms.
  The OAI parts stay under their own license (`LicenseRef-CSSL-1.0` in `infra/ran/gnb.yaml`).

## 2. Virtual radio and UE

### 2.1 Why not rfsim
OAI rfsim and OCUDU ZMQ are different simulated radios (different socket protocols and sample formats). The OAI cell
(gNB + nrUE over rfsim on REDLAB) is untouched. The OCUDU cell needs its own UE on ZMQ. The two cells share no radio, so
there is no interference, no measurement of each other and no handover between them (handover would need both gNBs on
one radio simulation and Xn; out of scope).

### 2.2 Option A (recommended first): OAI nrUE over ZMQ
| Item | Value |
|---|---|
| UE software | `oai-nr-ue` with `--device.name oai_zmqdevif --zmq.[0].tx_channels tcp://127.0.0.1:4557 --zmq.[0].rx_channels tcp://127.0.0.1:4556` |
| Image | Our pinned `docker.io/oaisoftwarealliance/oai-nr-ue:2026.w40`: its Dockerfile copies `liboai_zmqdevif.so`; the tag is published for amd64 and arm64. To verify on the Jetson (`ls /usr/local/lib/liboai_zmqdevif.so`) |
| Cell (from the OCUDU OAI-UE tutorial) | n78 TDD, 30 kHz SCS, 20 MHz (51 PRB), 23.04 MHz sampling, `ru_sdr.tx_gain: -12` (OCUDU sends full-scale samples with a 12 dB crest factor; the OAI fixed-point FFT saturates otherwise), CSI-RS on with `pucch.nof_cell_csi_res: 1` |
| UE options | `-r 51 --numerology 1 --band 78 -C <centre>`, `--ue-scan-carrier` (finds the SSB offset), optionally `-E` (3/4 sampling), and `--uecap_file uecap_ports1.xml` (OAI UE capabilities, required with third-party gNBs) |
| Interop history | Before OAI 2026.w25 the OAI UE lacked UCI on PUSCH, so UL failed with CSI-RS on. w40 is newer. The OCUDU tutorial shows 66 Mbit/s DL and 16 Mbit/s UL (MAC rates, MCS 27) at 20 MHz |
| Caveat | OAI fixed two ZMQ issues after w40 (negative-sample rounding in RX, 2026-10-16; TX latency, merged for w43). If w40 is unstable over ZMQ, use a newer UE tag **for the OCUDU cell only** |
| ZMQ limitation | Devices cannot reconnect after the start: a UE restart means restarting the gNB too (same as rfsim in practice) |

Advantage: the same UE software on both cells, so attach, CQI/MCS and throughput differences point at the gNB, not the UE.

### 2.3 Option B: srsUE over ZMQ
| Item | Value |
|---|---|
| UE software | srsRAN 4G `release_25_10` (2026-01-26), `srsue`; 5G SA is a prototype, maintenance only |
| Limits | 15 kHz SCS only, hence **FDD only** (n3 in the OCUDU example); 5, 10, 15, 20 MHz; no handover |
| ZMQ | gNB `device_args: tx_port=tcp://127.0.0.1:2000,rx_port=tcp://127.0.0.1:2001,base_srate=11.52e6` (10 MHz) or 23.04 for 20 MHz; srsUE mirrored ports |
| Network | srsUE puts its tunnel into a network namespace (`ip netns add ue1`, `[gw] netns = ue1`), so iperf runs with `ip netns exec` |
| Image | No official image; we would build srsRAN 4G from source (arm64 builds are common, untested by us) |
| Multi-UE | Several srsUEs through a GNU Radio broker flow graph (also gives path-loss control); a possible later step |

Use B as a fallback, or later to show an FDD cell (links to Experiment 4, paired spectrum) next to the TDD OAI cell.

## 3. Proposed architecture

```
 bench LAN 10.42.0.0/24 (isolated)
 ┌───────── tiny 10.42.0.2 (unchanged software) ─────────────────────────┐
 │ Open5GS 2.8.0: AMF NGAP :38412  UPF GTP-U :2152   + subscriber ue2    │
 │ dashboard (app.py), Prometheus (+1 scrape target), iperf server       │
 └───────▲ N2/N3 ─────────────────────────────────────▲ N2/N3 ───────────┘
         │                                            │
 ┌───────┴──── REDLAB 10.42.0.1 (unchanged) ───┐ ┌────┴── Jetson Orin NX 10.42.0.3 (new, arm64) ───────┐
 │ oai-gnb  gNB_ID 0xe00  PCI 0  n78 106 PRB   │ │ ocudu-gnb  gNB ID 0xe01  PCI 1  n78 51 PRB          │
 │   │ rfsim (127.0.0.1)                       │ │   │ ZMQ 127.0.0.1:4556/4557                         │
 │ oai-nr-ue (ue1, Secret ue1-sim)             │ │ oai-nr-ue over ZMQ (ue2, Secret ue2-sim)            │
 │ telnet 127.0.0.1:9090, noise/profile relays │ │ remote control WS 127.0.0.1:8001 -> metrics relay   │
 └─────────────────────────────────────────────┘ │   -> /metrics on 10.42.0.3:<port> (Prometheus)      │
                                                 └─────────────────────────────────────────────────────┘
```

### 3.1 Core side (N2/N3)
- Open5GS accepts several gNBs on one AMF. The OCUDU gNB connects from 10.42.0.3 to `cu_cp.amf.addrs: 10.42.0.2`
  with `bind_addrs: 10.42.0.3`; GTP-U from 10.42.0.3 to the UPF on 10.42.0.2:2152. The AMF and UPF already bind to
  10.42.0.2 (host network), so **no core config change** is expected.
- Identity: gNB ID `0xe01` (OAI: `0xe00`), PCI 1 (OAI: 0), its own NR cell ID; PLMN 001/70, TAC 1 (the only TAI the
  AMF serves), S-NSSAI SST 1 (OAI's `sd: 0xffffff` means "no SD", so it matches), DNN `fctoai`. A second TAC would
  need an AMF change and belongs to Experiment 13.
- QoS: Open5GS gives 5QI 9; OCUDU generates a matching default QoS block when none is configured.
- Second subscriber: `ue2` (IMSI e.g. `001700000000002`, K and OPc random), in `~/testbed-secrets/ue2.env` (mode 600,
  never committed), written by `open5gs.sh` the same way as `ue1` (dbctl job reading a Secret). On the Jetson the
  UE gets a Secret `ue2-sim` and renders its config in memory, with the same log masking as `ran.yaml`.
- UE address from the same pool (10.45.0.0/16); the iperf server on tiny reaches both UEs.

### 3.2 Deployment
- **k3s on the Jetson**: a single-node k3s like tiny (the bench keeps one cluster per host). Two Deployments with
  `hostNetwork: true`, same pattern as `infra/ran/ran.yaml`: `ocudu-gnb` and `oai-nr-ue-zmq`. Scripts in a new
  `infra/ran2/` (`ran2.sh apply|check|remove`) with a `check` gate as for the OAI cell.
- **Image**: `registry.gitlab.com/ocudu/ocudu/images/gnb-uhd:ubuntu-24.04-neon-<date>_<commit>-stable`, pinned to
  the promoted build of `release_26_10`, signature checked with cosign (signature, SBOM and vulnerability report are
  attached). Never `latest`. Fallback: build from `docker/Dockerfile` at the tag with `MARCH=cortex-a78ae`.
- **ZMQ in the image**: the build installs `libzmq3-dev` and `ENABLE_ZEROMQ` is on by default, so the driver is
  probably built in, but the image table only names UHD/DPDK. To verify: the gNB log line `Available radio types: uhd, zmq ...`.
- Container rights: OCUDU needs `SYS_NICE` (its compose file also adds `SYS_PTRACE`, which we do not need); not
  privileged. The OAI UE needs `privileged` (tun), as today.
- Helm charts exist (`ocudu_helm`: `ocudu-gnb`, `ocudu-du`, `ocudu-cu*`, `grafana-ocudu`, `open5gs`, `onap-smo-lite`,
  ...), but they target real radios, DPDK and PTP. Plain manifests in the repo style are simpler here.

### 3.3 Metrics and dashboard
- Enable in the gNB config:
  ```yaml
  metrics:
    enable_json: true
    layers: {enable_sched: true, enable_mac: true, enable_rlc: true, enable_pdcp: true, enable_ngap: true, enable_app_usage: true}
  remote_control:
    enabled: true
    bind_addr: 127.0.0.1   # docs and compose use 0.0.0.0: not on this bench
    port: 8001
  ```
- Per-UE fields (scheduler UE metrics): `cqi`, `dl_mcs`, `dl_brate`, `dl_nof_ok`/`nok`, `dl_bs`, `pusch_snr_db`,
  `ul_mcs`, `ul_brate`, `ul_nof_ok`/`nok`, `bsr`, `ta_ns`, `phr`; cell fields: scheduler latency, PRACH/Msg3 counts,
  UE list; `cpu_usage_percent` per component; app resource usage.
- **Collector**: a small relay pod on the Jetson (Python, `websockets`), connects to `127.0.0.1:8001`, sends
  `{"cmd":"metrics_subscribe"}`, keeps the last report and exposes Prometheus text on the bench LAN address; Prometheus
  on tiny adds one scrape job with a `cell="ocudu"` label. The dashboard gets a second cell column with the same KPI
  names where they map (CQI, MCS, BLER from ok/nok, DL/UL rate). Alternative: OCUDU's Telegraf
  (`inputs.websocket`) with `outputs.prometheus_client`, no own code but one more image.
- Not portable: `kpi.sh` and the T-tracer resource grid (Experiment 1b) read OAI internals. OCUDU's analogue for a
  resource grid would be its PHY-tap plugin example or MAC PCAPs; a later study, not part of this one.
- SINR: OAI reports UE-side SINR; OCUDU reports `pusch_snr_db` (UL, gNB side) and CQI. The OAI UE over ZMQ still logs
  its own measurements, so UE-side values stay comparable when Option A is used.

### 3.4 E2 and Experiment 12
- OCUDU's E2 agent: `e2: {enable_du_e2: true, e2sm_kpm_enabled: true, e2sm_rc_enabled: true, addr: <RIC>, port: 36421}`.
  KPM metrics include `DRB.UEThpDl/Ul`, `RRU.PrbTotDl/Ul`, `RRU.PrbUsedDl/Ul`, `DRB.RlcSduDelayDl`, `RRC.ConnMean`,
  `RRC.ConnEstabAtt/Succ`, `RACH.PreambleDedCell` (27 in total). RC: control style 2 only (radio resource allocation,
  e.g. slice PRB quotas).
- Fit: Experiment 12 plans FlexRIC with the OAI gNB. With OCUDU, the same RIC sees two E2 nodes from two vendors, and
  one KPM xApp can compare them. Version risk: the OCUDU tutorial builds FlexRIC with `KPM_V3_00` (and gcc-10); the
  OAI E2 agent at w40 must use a FlexRIC branch/version that works with both. To check in Experiment 12's issue.
- The RIC needs SCTP 36421 reachable from 10.42.0.3; bind it to the bench LAN only.

### 3.5 O1 and EXP-12a
- OCUDU O1 adapter (`ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter`, active 2026-11): a sidecar that reads the
  running config from a NETCONF datastore (netopeer2, repo `ocudu_netconf`), renders the gNB config file and signals a
  restart through a REST health check (`/config-healthy`); FM via VES; PM from the WebSocket metrics, either streamed
  or as gzipped TS 32.435 files announced with VES `notifyFileReady`. An O1 test suite (`ocudu_o1_tests`) exists.
- Compared with the OAI path in [EXP-12a](EXP-12a-smo-o1-feasibility.md): CM is a full config rewrite + restart
  (any parameter, not only 20/40/60/100 MHz), and PM uses real per-UE metrics. Same SMO (O-RAN SC OAM) could manage
  both gNBs; compatibility with the M release is unverified for both adapters.
- Host conflict: EXP-12a proposes "e.g. 10.42.0.3" for the SMO host (16 GB minimum). The Jetson cannot host both the
  SMO and the OCUDU cell. One of the two needs another address/host.

## 4. Hardware and placement
| Host | Fit | Notes |
|---|---|---|
| **Jetson Orin NX 10.42.0.3** (arm64, Cortex-A78AE, 8 or 6 cores, 16 or 8 GB shared with the GPU) | **Recommended** | Arm64 images exist for both OCUDU and the OAI UE. Separate CPU budget from the OAI cell, so Experiment 1 numbers on REDLAB are not disturbed. Need to know: RAM variant, JetPack/Ubuntu version (22.04 with JetPack 6 is fine for containers), current use, power mode (`nvpmodel` MAXN) and fan |
| REDLAB 10.42.0.1 (x86) | Not recommended | 23 of 30 GB used; the OAI UE alone needs 0.7-2.6 cores per simulated second (Experiment 1). A second cell would skew the OAI measurements |
| tiny 10.42.0.2 | No | Core, dashboard and Prometheus must stay unaffected |
| Another x86 mini PC | Alternative | AVX2 image (`avx2` variant); also removes the ARM-vs-x86 confound in the comparison |

Expected load (**hypothesis**, to be measured in step 1 of the experiment): OCUDU gNB at 20 MHz over ZMQ 1-2 cores and
about 1-2 GB RAM; OAI UE at 51 PRB about 0.7 cores on REDLAB's x86 (Experiment 1), probably 1-1.5 cores on the A78AE;
relay and k3s about 0.5 GB. Total about 3-4 cores and 3-4 GB, which fits an Orin NX 16 GB and is tight on 8 GB.
ZMQ runs as fast as the slowest side, not in real time: if the Jetson is too slow, the cell runs slower than real
time (like 273 PRB in Experiment 1) and goodput in wall-clock Mbit/s drops. The experiment therefore records the
simulation speed.

## 5. First experiment: OAI cell vs OCUDU cell on the same core
Same method as the other experiments: baseline, one change, record again, scripted PASS checks. All rfsim/ZMQ only.

**Setup.** Both cells at 20 MHz, n78, 30 kHz SCS, 51 PRB, same TDD pattern as the OAI cell (5 ms: 7 DL slots +
6 DL symbols, 2 UL slots + 4 UL symbols; in OCUDU `tdd_ul_dl_cfg: {dl_ul_tx_period: 10, nof_dl_slots: 7,
nof_dl_symbols: 6, nof_ul_slots: 2, nof_ul_symbols: 4}`), CSI-RS on, noise off. OAI cell on its existing `bw-51`
profile (Experiment 1: 43.3 Mbit/s UDP DL at MCS 28). UE software OAI nrUE in both cells (Option A).

| Step | What | PASS |
|---|---|---|
| 1 | Attach: start the OCUDU cell; time from gNB start to NG Setup, UE RRC connected, registration, PDU session | NG Setup Response in the AMF log with gNB ID 0xe01; UE tunnel up with a 10.45.x address; ping to 10.45.0.1; OAI cell's `ran.sh check` still PASS; AMF shows **2 gNBs, 2 UEs** |
| 2 | Isolation: both cells carry traffic at once | No change in OAI cell CQI/MCS/goodput beyond run-to-run spread (Experiment 1: within 1 %) |
| 3 | Capacity: UDP DL at a fixed rate above the link rate (as Experiment 0c), then UL | Report DL/UL goodput, MCS, BLER for both cells. Hypothesis: OCUDU close to OAI at 51 PRB (about 40-45 Mbit/s DL), limited by TDD pattern and overhead, not by the gNB. Difference > 10 % is investigated (MCS table, CSI-RS/SSB overhead, ZMQ speed) |
| 4 | One TCP flow (dashboard speed test) per cell | Reported, not gated (single-flow TCP is application-limited, Experiment 0c) |
| 5 | Compute cost: CPU cores of gNB and UE pods from cAdvisor/`kubectl top` at idle and at saturation; simulation speed (simulated seconds per wall second, from slot/frame counters); **cores per simulated second** and **CPU-seconds per Mbit** (cores per simulated second / goodput) | Numbers for both cells in one table, with the host (x86 vs arm64) stated |
| 6 | Stop/start: delete the OCUDU gNB pod | AMF removes the gNB (NG reset/SCTP down); the OAI cell is unaffected; re-attach works after `ran2.sh apply` |

Fairness: the two cells run on different CPUs (REDLAB x86 vs Jetson arm64), so step 5 compares stacks **and**
hardware. To separate them, one of: (a) run the OAI rfsim cell on the Jetson too (its images are arm64) for one
measurement window, or (b) run the OCUDU cell on REDLAB for one window with the OAI cell scaled to 0. Both need the
user's OK; (a) leaves REDLAB untouched.

Possible follow-ups (separate issues): srsUE on an FDD n3 cell (Experiment 4), OCUDU noise/link adaptation as
Experiment 0 (ZMQ has no channel model; would need the GNU Radio broker with a gain block), OCUDU CU/DU split (F1
on the bench LAN), E2 KPM from both cells into one xApp (Experiment 12).

## 6. Security
- **ZMQ** sample ports (4556/4557, or 2000/2001 for srsUE) bind to `tcp://127.0.0.1` only. ZMQ has no
  authentication; anyone who connects can inject or read the radio stream. `ran2.sh check` gate: "no ZMQ port listens
  outside 127.0.0.1".
- **Remote control WebSocket** (8001): the OCUDU docs and compose file bind it to 0.0.0.0. It takes commands as well as
  metrics subscriptions and has no authentication, so it must bind 127.0.0.1, with a check gate as for the gNB telnet.
  Only the read-only relay is reachable on the bench LAN, and it exposes metrics only.
- **N2/N3** only on the bench LAN (10.42.0.3 to 10.42.0.2). The Jetson must not route between campus/Wi-Fi and the
  bench LAN; check its other interfaces before installing.
- **SIM values** (`ue2`: IMSI, K, OPc) only in `~/testbed-secrets/ue2.env` and a k3s Secret on the Jetson and on tiny;
  rendered into an in-memory volume; masked in UE logs (OAI prints them at start). Never in git, ConfigMaps or the doc.
- **Images**: pin the `-stable` digest of 26.10 and verify the cosign signature; OCUDU's example InfluxDB token
  (`fake-token-...`) and anonymous Grafana are not used.
- **Over-the-air**: none. The `gnb-uhd` image can drive USRPs; no SDR is connected to the Jetson and the config uses
  `device_driver: zmq` only.

## 7. Risks
| Risk | Effect | Mitigation |
|---|---|---|
| OAI w40 UE over ZMQ with OCUDU 26.10 untested by us; ZMQ fixes landed after w40 | No attach or unstable UL | Try w40 first; then a newer OAI UE tag for this cell only; fallback srsUE (FDD) |
| `neon` image built for Neoverse-N1 may use instructions the Orin lacks | `Illegal instruction` at start | Run `gnb --version` once before anything else; else build with `MARCH=cortex-a78ae` on the Jetson (long build) |
| Published component image without the ZMQ driver | gNB cannot use ZMQ | Check the "Available radio types" line; else build from `docker/Dockerfile` at `release_26_10` |
| Jetson too slow or only 8 GB | Simulation slower than real time; skewed throughput; OOM | Measure in step 5; reduce to 10 MHz (24 PRB) if needed; OCUDU's `ocudu_performance` script tunes the host (CPU governor) |
| ZMQ needs both ends fresh after any restart | A UE crash takes the cell down | `ran2.sh` restarts gNB then UE together, as `profile.sh` does for the OAI cell |
| Jetson already planned for other work (SMO in EXP-12a, GPU work) | Resource clash | Decide the host before stage S1 (open question 1) |
| Comparison confounded by hardware | Wrong conclusion "OCUDU is cheaper/faster" | Fairness options (a)/(b) in section 5; always state the host |
| Second gNB changes AMF state | OAI cell affected | Steps 1 and 2 gate on the OAI cell staying PASS; the core config is not changed |

## 8. Open questions
1. The Jetson Orin NX at 10.42.0.3: 8 or 16 GB? What runs on it today, which JetPack/Ubuntu, and is it free for this
   (EXP-12a also suggests 10.42.0.3 for the SMO)?
2. OK to add a second subscriber (`ue2`) to the core and extend `open5gs.sh` for it?
3. UE choice: OAI nrUE over ZMQ first (same UE in both cells), srsUE later for FDD; agreed?
4. Second cell on the dashboard: one extra column per KPI, or a separate "Cell 2" page?
5. For the compute comparison: run the OAI cell on the Jetson for one window (a), or OCUDU on REDLAB (b)?
6. Should Experiment 12 (near-RT RIC) plan for two E2 nodes from the start?

## Proposed stages (each only with the user's OK)
| Stage | Where | Changes the bench? |
|---|---|---|
| S0 | Jetson: read-only inventory (`free -g`, `nproc`, `/etc/nv_tegra_release`, interfaces, running services) | No |
| S1 | Jetson: pull and verify the pinned OCUDU image; `gnb --version`; check ZMQ support; pull `oai-nr-ue:2026.w40` arm64 and check `liboai_zmqdevif.so` | No bench service touched (new images on the Jetson only) |
| S2 | Jetson: k3s single node; OCUDU gNB + OAI UE over ZMQ against OCUDU's own dockerised Open5GS, isolated (no tiny) | Jetson only |
| S3 | tiny: subscriber `ue2`; Jetson: point the gNB at 10.42.0.2; experiment steps 1-2 | Yes (core subscriber DB, new gNB on the AMF) |
| S4 | Metrics relay + Prometheus scrape job + dashboard column; experiment steps 3-6 | Yes (Prometheus config, dashboard) |

## Sources
- OCUDU code and releases: [gitlab.com/ocudu/ocudu](https://gitlab.com/ocudu/ocudu) (tags `release_26_04`, `release_26_10`; `CHANGELOG`, `LICENSE`, `docker/Dockerfile`, `docker/docker-compose.yml`, `docker/.env`, `docker/scripts/install_dependencies.sh`, `CMakeLists.txt` `ENABLE_ZEROMQ`)
- OCUDU docs ([docs.ocudu.org](https://docs.ocudu.org), source [ocudu_docs](https://gitlab.com/ocudu/ocudu_docs)): [Using srsUE](https://docs.ocudu.org/tutorials/srsue/), [OAI UE](https://docs.ocudu.org/tutorials/oaiue/), [Container images](https://docs.ocudu.org/tutorials/container_images/), [Kubernetes](https://docs.ocudu.org/tutorials/k8s/), [Near-RT RIC](https://docs.ocudu.org/tutorials/near-rt-ric/), [Supported E2 metrics](https://docs.ocudu.org/knowledge_base/e2sm_kpm_metrics/), [Outputs / JSON metrics](https://docs.ocudu.org/user_manual/outputs/), [Migrating from srsRAN](https://docs.ocudu.org/migration/)
- OCUDU O-RAN apps and Helm: [ocudu_o1_adapter](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter), [ocudu_netconf](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_netconf), [ocudu_helm](https://gitlab.com/ocudu/ocudu_elements/ocudu_helm)
- Announcements: [OCUDU 26.04 initial release (ocudu.org)](https://ocudu.org/news/blog-introducing-the-initial-ocudu-technical-project-release-26-04/), [OCUDU 26.10 (SRS)](https://srs.io/ocudu-ecosystem-foundation-announces-ocudu-26-10-bringing-satellite-connectivity-8t8r-mimo-and-multi-beam-operation-to-open-source-ran/), [Linux Foundation: OCUDU Ecosystem Foundation](https://www.linuxfoundation.org/press/linux-foundation-announces-ocudu-ecosystem-foundation-to-accelerate-open-source-ai-ran-innovation)
- OAI ZMQ radio at 2026.w40: [radio/zmq/README.md](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/radio/zmq/README.md), [Dockerfile.nrUE.ubuntu](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/docker/Dockerfile.nrUE.ubuntu) (copies `liboai_zmqdevif.so`), later fixes in the [radio/zmq history](https://github.com/OPENAIRINTERFACE/openairinterface5g/commits/develop/radio/zmq); image tags on [Docker Hub oai-nr-ue](https://hub.docker.com/r/oaisoftwarealliance/oai-nr-ue/tags) (2026.w40: amd64, arm64)
- srsRAN 4G (srsUE): [github.com/srsran/srsRAN_4G releases](https://github.com/srsran/srsRAN_4G/releases) (`release_25_10`)
- Bench: `infra/ran/ran.yaml`, `infra/ran/gnb.yaml`, `infra/core/gen-open5gs.py`, `infra/core/open5gs.sh`, [EXP-01](EXP-01-bandwidth.md), [EXP-12a (PR #38)](https://github.com/rediramli/R-D-Testbed/pull/38)
