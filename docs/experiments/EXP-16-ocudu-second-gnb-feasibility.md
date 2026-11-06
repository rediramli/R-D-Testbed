# Experiment 16 (feasibility): a second gNB built on OCUDU

Status: **feasibility study** (2026-11-03), **stages S1 (2026-11-04), S1b, S2 and S3 (2026-11-06) done: the OCUDU cell is live on tiny; experiment steps 1-6 PASS** (images pulled and tested in throwaway pods
on tiny, see [S1](#s1-results-2026-11-04), [S2](#s2-results-2026-11-06-second-cell-live-experiment-steps-0-1) and [S3](#s3-results-2026-11-06-experiment-steps-2-6) results).
Bench changes so far: subscriber `ue2` in the core, namespace `ran2` (OCUDU cell) on tiny's k3s; the OAI cell is unchanged.
S1 found that no published OCUDU image contains the ZMQ driver; **stage S1b (2026-11-06) built our own image with ZMQ** (see [S1b](#s1b-our-own-gnb-image-with-zmq-built-2026-11-06)).
Question: can the bench get a second gNB, built on OCUDU (the Linux Foundation successor of the srsRAN Project), next to
the OAI cell, on the same Open5GS core? Answer: **yes**, as a separate cell with its own UE and its own virtual radio
(ZMQ), not as a handover neighbour of the OAI cell. **Decided host (2026-11-03): tiny, in its existing k3s**, in one
pod with its own network namespace. The Jetson Orin NX stays an alternative.

## Summary
| Question | Answer |
|---|---|
| Current OCUDU release | **26.10** (tag `release_26_10`, commit `e0db566a`, 2026-09-30). Previous: 26.04 (2026-03-31, first OCUDU release). Incremental, not LTS |
| License | **BSD-3-Clause-Open-MPI** (permissive; srsRAN Project was AGPLv3). Code on `gitlab.com/ocudu/ocudu`, docs on `docs.ocudu.org` |
| Virtual radio | ZMQ (`ru_sdr.device_driver: zmq`), sample streams over ZeroMQ REQ/REP. Not compatible with OAI rfsim, so the OAI cell's UE cannot see it |
| Which UE | **Two options.** (a) **OAI nrUE with its ZMQ radio** (`oai_zmqdevif`, in OAI since 2026.w17; OCUDU documents it for OAI ≥ 2026.w25). Our pinned `oai-nr-ue:2026.w40` image already ships `liboai_zmqdevif.so` (amd64 and arm64). (b) **srsUE** (srsRAN 4G `release_25_10`): 15 kHz SCS only, so FDD bands only (e.g. n3), 5/10/15/20 MHz, no handover, maintenance mode |
| Correction to the starting assumption | "OAI nrUE cannot attach to OCUDU" is no longer true: it cannot attach **through rfsim**, but it can through ZMQ. This allows a like-for-like comparison with the same UE software on both cells |
| Where it runs | **tiny (10.42.0.2), k3s, namespace `ran2`**: i9-14900 (8 P-cores with HT + 16 E-cores, 32 threads, AVX2, no AVX-512), 30 GB RAM of which about 4 GB used, about 0.34 cores used by the whole core + dashboard + Prometheus (checked 2026-11-03). Image variant `avx2` |
| Core | Same Open5GS 2.8.0, same host: N2 SCTP to 10.42.0.2:38412, N3 GTP-U 2152, from the pod IP (10.244.0.x) over `cni0`. Distinct gNB ID and PCI, same PLMN 001/70, TAC 1, SST 1, DNN `fctoai`. Needs a second subscriber (`ue2`). No core config change |
| Main pitfall | The UE must **not** share the host network namespace with the UPF: `ogstun` holds 10.45.0.1/16 on tiny, so a host-network UE tunnel would overlap it and test traffic would be delivered locally without crossing the radio. Hence gNB + UE in **one pod without `hostNetwork`** |
| Metrics for the dashboard | JSON metrics over the **remote-control WebSocket** (`metrics_subscribe`, port 8001, bound to 127.0.0.1 inside the pod), turned into Prometheus text by a relay sidecar, scraped in-cluster by the Prometheus already on tiny. Our KPI pipeline and the T-tracer resource grid are OAI-only |
| E2 | Built-in E2 agent: **E2SM-KPM** (report styles 1-5 and 255, 27 metrics) and **E2SM-RC** (control style 2 only). Documented with FlexRIC and the O-RAN SC near-RT RIC. Fits Experiment 12 as a second, different E2 node |
| O1 | OCUDU has its own O1 adapter (Python sidecar: NETCONF CM and FM, PM from the JSON metrics, TS 32.435 files + VES `notifyFileReady`). More complete than the OAI o1-adapter studied in [EXP-12a](EXP-12a-smo-o1-feasibility.md) |
| Published images (S1, 2026-11-04) | Signed (cosign keyless, OCUDU `main` pipeline) and runnable on tiny, but **built with `-DENABLE_ZEROMQ=OFF`**: `Available radio types: uhd and realtime_loopback`. Same for the all-in-one image. Our own image is needed |
| Verdict | **Feasible on tiny, with our own OCUDU image** (built 2026-11-06: 26.10, ZMQ, 2.7 GB RSS at start). Open points: ZMQ interop between OAI w40 and OCUDU 26.10, and proof that the core is not disturbed (gate in step 2 of the experiment) |

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
- **License consequence**: BSD-style, so our own configs, scripts and relay code can stay under the repo's terms.
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
| Image | Our pinned `docker.io/oaisoftwarealliance/oai-nr-ue:2026.w40`: its Dockerfile copies `liboai_zmqdevif.so`. To verify on tiny with `ls /usr/local/lib/liboai_zmqdevif.so` in the image |
| Cell (from the OCUDU OAI-UE tutorial) | n78 TDD, 30 kHz SCS, 20 MHz (51 PRB), 23.04 MHz sampling, `ru_sdr.tx_gain: -12` (OCUDU sends full-scale samples with a 12 dB crest factor; the OAI fixed-point FFT saturates otherwise), CSI-RS on with `pucch.nof_cell_csi_res: 1` |
| UE options | `-r 51 --numerology 1 --band 78 -C <centre>`, `--ue-scan-carrier` (finds the SSB offset), optionally `-E` (3/4 sampling), and `--uecap_file uecap_ports1.xml` (OAI UE capabilities, required with third-party gNBs) |
| Interop history | Before OAI 2026.w25 the OAI UE lacked UCI on PUSCH, so UL failed with CSI-RS on. w40 is newer. The OCUDU tutorial shows 66 Mbit/s DL and 16 Mbit/s UL (MAC rates, MCS 27) at 20 MHz |
| Caveat | OAI fixed two ZMQ issues after w40 (negative-sample rounding in RX, 2026-10-16; TX latency, merged for w43). If w40 is unstable over ZMQ, use a newer UE tag **for the OCUDU cell only** |
| ZMQ limitation | Devices cannot reconnect after the start: a UE restart means restarting the gNB too. In one pod, both containers restart together |

Advantage: the same UE software on both cells, so attach, CQI/MCS and throughput differences point at the gNB, not the UE.

### 2.3 Option B: srsUE over ZMQ
| Item | Value |
|---|---|
| UE software | srsRAN 4G `release_25_10` (2026-01-26), `srsue`; 5G SA is a prototype, maintenance only |
| Limits | 15 kHz SCS only, hence **FDD only** (n3 in the OCUDU example); 5, 10, 15, 20 MHz; no handover |
| ZMQ | gNB `device_args: tx_port=tcp://127.0.0.1:2000,rx_port=tcp://127.0.0.1:2001,base_srate=11.52e6` (10 MHz) or 23.04 for 20 MHz; srsUE mirrored ports |
| Network | srsUE normally puts its tunnel into a network namespace (`[gw] netns`); inside our pod the pod's own namespace already does that job |
| Image | No official image; we would build srsRAN 4G from source |

Use B as a fallback, or later to show an FDD cell (links to Experiment 4, paired spectrum) next to the TDD OAI cell.

## 3. Architecture on tiny (k3s)

```
 bench LAN 10.42.0.0/24 (isolated)
 ┌──────────────────────── tiny 10.42.0.2  (k3s, pod CIDR 10.244.0.0/16) ─────────────────────────┐
 │ host network: Open5GS AMF :38412, UPF :2152, ogstun 10.45.0.1/16, iperf3 :5201/:5202          │
 │ pods: other Open5GS NFs, dashboard, Prometheus                                                 │
 │       ▲ N2 SCTP / N3 GTP-U from the pod IP, over cni0 (never on the LAN wire)                  │
 │ ┌─────┴──────── pod ocudu-cell (namespace ran2, NO hostNetwork, pinned to P-cores) ─────────┐ │
 │ │ gnb (OCUDU 26.10, avx2)  gNB ID 0xe01, PCI 1, n78 51 PRB                                   │ │
 │ │   │ ZMQ 127.0.0.1:4556/4557 (pod loopback)                                                 │ │
 │ │ ue  (oai-nr-ue 2026.w40, ZMQ)  oaitun_ue1 10.45.x.y, route 10.45.0.1/32 via oaitun_ue1     │ │
 │ │ metrics-relay  ws://127.0.0.1:8001 -> :9105/metrics on the pod IP (Prometheus only)        │ │
 │ └────────────────────────────────────────────────────────────────────────────────────────────┘ │
 └────────────────────────────────────────────────────────────────────────────────────────────────┘
 REDLAB 10.42.0.1: OAI gNB + nrUE over rfsim (unchanged), N2/N3 to 10.42.0.2 over the LAN
```

### 3.1 Why one pod without host networking
- On tiny, `ogstun` (10.45.0.1/16) and the iperf3 servers (bound to 10.45.0.1) live in the host namespace. A UE with
  `hostNetwork: true`, as on REDLAB, would put `oaitun_ue1` (10.45.x.y) next to `ogstun` in the same namespace:
  overlapping /16 routes, and packets to 10.45.0.1 delivered by the kernel locally, never through the radio, GTP-U
  and the UPF. Throughput numbers would be meaningless.
- In one pod, gNB and UE share the pod's own network namespace: ZMQ stays on the pod loopback (127.0.0.1), the UE
  tunnel exists only inside the pod, and a route `10.45.0.1/32 dev oaitun_ue1` sends test traffic over the air
  interface. The only way out of the pod towards 10.45.0.1 is then UE → ZMQ → gNB → GTP-U → UPF → `ogstun`.
- Gate in `ran2.sh check`: inside the pod, `ip route get 10.45.0.1` must name `oaitun_ue1`; and on the host,
  `ip route` must show no 10.45 route other than `ogstun`.

### 3.2 Core side (N2/N3)
- The AMF (NGAP) and UPF (GTP-U) already listen on 10.42.0.2 in the host namespace. From the pod, packets to
  10.42.0.2 go over `cni0` to the host. The gNB binds N2 and N3 to its pod IP; the pod IP changes on restart, so it is
  rendered into the config at start from the Downward API (`status.podIP`), the same way the UE SIM is rendered from
  a Secret today. The UPF sends DL GTP-U to that pod IP, which the host routes over `cni0`. **No core config change.**
- Identity: gNB ID `0xe01` (OAI: `0xe00`), PCI 1 (OAI: 0), its own NR cell ID; PLMN 001/70, TAC 1 (the only TAI the
  AMF serves), S-NSSAI SST 1 (OAI's `sd: 0xffffff` means "no SD", so it matches), DNN `fctoai`. A second TAC would
  need an AMF change and belongs to Experiment 13.
- QoS: Open5GS gives 5QI 9; OCUDU generates a matching default QoS block when none is configured.
- Second subscriber: `ue2` (IMSI e.g. `001700000000002`, K and OPc random), in `~/testbed-secrets/ue2.env` on tiny
  (mode 600, never committed), written by `open5gs.sh` the same way as `ue1` (dbctl job reading a Secret). The pod gets
  Secret `ue2-sim` in namespace `ran2`, rendered into an in-memory volume, with the same log masking as `ran.yaml`.
- Throughput server: the iperf3 server on tiny serves one client at a time per port (5201 single-flow TCP, 5202 UDP).
  Step 2 of the experiment (both cells loaded at once) needs a third port (e.g. 5203) in `infra/dash/iperf-core.yaml`.
- Note for Experiment 10 (GTP-U inspection): this cell's N2/N3 never reach the LAN; capture on `cni0` or the pod's
  veth on tiny, not on `eno2`. That contrast (core and RAN on one host vs on two) is itself a teaching point.

### 3.3 Kubernetes objects (proposal, in a new `infra/ran2/`)
| Object | Content |
|---|---|
| Namespace `ran2` | Keeps the second cell apart from `open5gs` and `fct-dash`; `kubectl delete ns ran2` removes all of it |
| Secret `ue2-sim` | IMSI, K, OPc (from `~/testbed-secrets/ue2.env`) |
| ConfigMaps | `ocudu-gnb-config` (gNB YAML with `__POD_IP__` placeholders), `ue2-config` (UE template), `metrics-relay` (Python) |
| Deployment `ocudu-cell` (1 replica, `Recreate`) | Init container renders gNB config (pod IP) and UE config (SIM). Containers: `gnb` (**our own image** `fct/ocudu-gnb:26.10-zmq`, see S1b; the published ones have no ZMQ), with caps `SYS_NICE`, `IPC_LOCK`, `PERFMON` (the binary carries these as file capabilities, `=ep`: without all three the kernel refuses to start it, "Operation not permitted"), `ue` (`oai-nr-ue:2026.w40`, privileged for the tun device, as today; adds the 10.45.0.1/32 route once the tunnel is up), `metrics-relay` (small Python image) |
| Resources | Limits per container (proposal: gNB 4 CPU / **6 GiB**, UE 3 CPU / 2 GiB, relay 0.2 CPU / 128 MiB). The gNB was OOM-killed at start under a 2 GiB limit (S1); it started under 6 GiB. Requests equal to limits so the pod is not evicted first. To be adjusted after step 5 |
| CPU placement | P-cores are CPUs 0-15 on tiny (5.5-5.8 GHz), E-cores 16-31 (4.3 GHz). First choice: start both softmodems under `taskset -c 0-15`; no kubelet change, the core keeps running anywhere. Later, if needed: kubelet static CPU manager with `--reserved-cpus=16-31` for exclusive P-cores (needs a k3s restart on tiny, i.e. a core restart, so only with the user's OK) |
| Service + NetworkPolicy | ClusterIP Service for `:9105` (relay); NetworkPolicy: ingress to the pod only from the Prometheus pod on 9105. k3s enforces NetworkPolicy by default (not disabled in `infra/k3s-node.sh`) |
| Script `infra/ran2/ran2.sh` | `MODE=apply|check|remove`, run on tiny like `open5gs.sh`. `check`: pod Ready, NG Setup accepted (AMF log, gNB ID 0xe01), UE tunnel up, route gate (3.1), ZMQ 4556/4557 and remote control 8001 bound to 127.0.0.1 only, all `open5gs` pods still Ready, OAI cell `ran.sh check` still PASS |

The OCUDU Helm charts (`ocudu_helm`: `ocudu-gnb`, `grafana-ocudu`, ...) target real radios, DPDK and PTP and do not
cover the UE. Plain manifests in the repo style are simpler and match `infra/ran/ran.yaml`.

### 3.4 Metrics and dashboard
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
- **Relay sidecar**: connects to `ws://127.0.0.1:8001`, sends `{"cmd":"metrics_subscribe"}`, keeps the last report,
  serves Prometheus text on `:9105`. Prometheus on tiny gets one scrape job (`ocudu-cell.ran2.svc:9105`,
  label `cell="ocudu"`); nothing is exposed on the LAN. The dashboard gets a second cell column with the same KPI
  names where they map (CQI, MCS, BLER from ok/nok, DL/UL rate). Alternative: OCUDU's Telegraf (`inputs.websocket`
  + `outputs.prometheus_client`), no own code but one more image.
- Not portable: `kpi.sh` and the T-tracer resource grid (Experiment 1b) read OAI internals. OCUDU's analogue for a
  resource grid would be its PHY-tap plugin example or MAC PCAPs; a later study.
- SINR: OAI reports UE-side SINR; OCUDU reports `pusch_snr_db` (UL, gNB side) and CQI. The OAI UE over ZMQ still logs
  its own measurements, so UE-side values stay comparable with Option A.

### 3.5 E2 and Experiment 12
- OCUDU's E2 agent: `e2: {enable_du_e2: true, e2sm_kpm_enabled: true, e2sm_rc_enabled: true, addr: <RIC>, port: 36421}`.
  KPM metrics include `DRB.UEThpDl/Ul`, `RRU.PrbTotDl/Ul`, `RRU.PrbUsedDl/Ul`, `DRB.RlcSduDelayDl`, `RRC.ConnMean`,
  `RRC.ConnEstabAtt/Succ`, `RACH.PreambleDedCell` (27 in total). RC: control style 2 only (radio resource allocation,
  e.g. slice PRB quotas).
- Fit: Experiment 12 plans FlexRIC with the OAI gNB. With OCUDU, the same RIC sees two E2 nodes from two vendors, and
  one KPM xApp can compare them. Version risk: the OCUDU tutorial builds FlexRIC with `KPM_V3_00` (and gcc-10); the
  OAI E2 agent at w40 must use a FlexRIC version that works with both. To check in Experiment 12's issue.
- From the pod, the RIC is reached over the pod network (if the RIC runs in tiny's k3s) or via the host route to the
  LAN; the E2 port 36421 binds to the bench LAN or cluster only.

### 3.6 O1 and EXP-12a
- OCUDU O1 adapter (`ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter`, active 2026-11): a sidecar that reads the
  running config from a NETCONF datastore (netopeer2, repo `ocudu_netconf`), renders the gNB config file and signals a
  restart through a REST health check (`/config-healthy`); FM via VES; PM from the WebSocket metrics, either streamed
  or as gzipped TS 32.435 files announced with VES `notifyFileReady`. An O1 test suite (`ocudu_o1_tests`) exists. It
  is designed as a sidecar in the gNB pod, which fits section 3.3.
- Compared with the OAI path in [EXP-12a](EXP-12a-smo-o1-feasibility.md): CM is a full config rewrite + restart
  (any parameter, not only 20/40/60/100 MHz), and PM uses real per-UE metrics. The same SMO (O-RAN SC OAM) could
  manage both gNBs; compatibility with the M release is unverified for both adapters.
- With OCUDU on tiny, 10.42.0.3 (Jetson) stays free for EXP-12a's SMO host proposal, as far as RAM allows (the SMO
  needs 16 GB).

## 4. Hardware and placement
| Host | Fit | Notes |
|---|---|---|
| **tiny 10.42.0.2** (ThinkStation P3 Tiny, i9-14900, 32 threads, 30 GB) | **Chosen** | About 26 GB RAM available and the core uses about 0.34 cores (2026-11-03). x86 AVX2 like REDLAB (Core Ultra 9 285), so the compute comparison is not confounded by x86 vs ARM. k3s already runs there. Disk `/` 48 GB with 16 GB free: OCUDU + UE images are a few GB; check before pulling |
| Jetson Orin NX 10.42.0.3 (arm64) | Alternative | Physically separate RAN; arm64 images exist for both. Risks: Neoverse-N1 build target vs Cortex-A78AE, 8/16 GB shared with the GPU, slower cores. Better kept for the EXP-12a SMO or ARM tests |
| REDLAB 10.42.0.1 (x86) | No | About 23 of 30 GB used; the OAI UE alone needs 0.7-2.6 cores per simulated second (Experiment 1) |

Expected load (**hypothesis**, measured in step 5): OCUDU gNB at 20 MHz over ZMQ 1-2 cores and about 1-2 GB RAM;
OAI UE at 51 PRB about 0.7 cores (as on REDLAB in Experiment 1); relay negligible. Total about 3 cores and 3-4 GB,
well inside tiny's spare capacity. ZMQ runs as fast as the slowest side, not in real time: if the pod is starved, the
cell runs slower than real time and goodput in wall-clock Mbit/s drops. The experiment records the simulation speed.

Blast radius: tiny carries the core for **both** cells. If the OCUDU pod misbehaves (CPU, memory), the OAI cell can
lose its core. The limits in 3.3 and the gates in step 2 of the experiment are there for that; `ran2.sh remove`
(namespace delete) is the way back.

## 5. First experiment: OAI cell vs OCUDU cell on the same core
Same method as the other experiments: baseline, one change, record again, scripted PASS checks. All rfsim/ZMQ only.

**Setup.** Both cells at 20 MHz, n78, 30 kHz SCS, 51 PRB, same TDD pattern as the OAI cell (5 ms: 7 DL slots +
6 DL symbols, 2 UL slots + 4 UL symbols; in OCUDU `tdd_ul_dl_cfg: {dl_ul_tx_period: 10, nof_dl_slots: 7,
nof_dl_symbols: 6, nof_ul_slots: 2, nof_ul_symbols: 4}`), CSI-RS on, noise off. OAI cell on its existing `bw-51`
profile (Experiment 1: 43.3 Mbit/s UDP DL at MCS 28). UE software OAI nrUE in both cells (Option A).

| Step | What | PASS |
|---|---|---|
| 0 | Core baseline on tiny without the OCUDU pod: CPU and memory of `open5gs` pods, UPF and AMF metrics, OAI cell UDP DL at 51 PRB | Recorded as reference |
| 1 | Attach: apply `ran2`; time from pod start to NG Setup, UE RRC connected, registration, PDU session | NG Setup Response in the AMF log with gNB ID 0xe01; UE tunnel up with a 10.45.x address; route gate (3.1); ping to 10.45.0.1 over `oaitun_ue1`; AMF shows **2 gNBs, 2 UEs**; OAI cell `ran.sh check` still PASS |
| 2 | Isolation: both cells carry UDP at saturation at once (OAI on 5202, OCUDU on 5203) | OAI cell CQI/MCS/goodput unchanged beyond run-to-run spread (Experiment 1: within 1 %); `open5gs` pods Ready, no restarts; UPF CPU and tiny's load recorded |
| 3 | Capacity: UDP DL at a fixed rate above the link rate (as Experiment 0c), then UL, one cell at a time | DL/UL goodput, MCS, BLER for both cells. Hypothesis: OCUDU close to OAI at 51 PRB (about 40-45 Mbit/s DL), limited by TDD pattern and overhead, not by the gNB. Difference > 10 % is investigated (MCS table, CSI-RS/SSB overhead, ZMQ speed) |
| 4 | One TCP flow (dashboard speed test) per cell | Reported, not gated (single-flow TCP is application-limited, Experiment 0c) |
| 5 | Compute cost: CPU cores of gNB and UE containers (cAdvisor / `kubectl top`) at idle and at saturation; simulation speed (simulated seconds per wall second, from slot/frame counters); **cores per simulated second** and **CPU-seconds per Mbit** (cores per simulated second / goodput) | Numbers for both cells in one table, with host and core type stated (REDLAB Core Ultra 9 285 vs tiny i9-14900 P-cores) |
| 6 | Stop/start: delete the OCUDU pod | AMF removes the gNB (SCTP down); the OAI cell is unaffected; re-attach works after `ran2.sh apply` |

Fairness: both hosts are x86, but different CPUs and simulators (rfsim vs ZMQ). If the step-5 numbers differ by more
than the CPU difference can explain, one cross-check window: the OAI rfsim cell in a second pod on tiny's P-cores
(same `hostNetwork`-free pattern), with the user's OK.

Possible follow-ups (separate issues): srsUE on an FDD n3 cell (Experiment 4), OCUDU noise/link adaptation as
Experiment 0 (ZMQ has no channel model; would need the GNU Radio broker with a gain block), OCUDU CU/DU split (F1
between two pods), E2 KPM from both cells into one xApp (Experiment 12), OCUDU O1 adapter as a sidecar (EXP-12a).

## 6. Security
- **ZMQ** sample ports (4556/4557, or 2000/2001 for srsUE) bind to `tcp://127.0.0.1` in the pod namespace only. ZMQ
  has no authentication; anyone who connects can inject or read the radio stream. Gate in `ran2.sh check`.
- **Remote control WebSocket** (8001): the OCUDU docs and compose file bind it to 0.0.0.0. It takes commands as well as
  metrics subscriptions and has no authentication, so it binds 127.0.0.1 in the pod. Only the read-only relay
  (:9105) is reachable, only from Prometheus (NetworkPolicy), and it serves metrics only.
- **N2/N3** stay inside tiny (pod IP to 10.42.0.2 over `cni0`); nothing new on the LAN, no new host ports.
- **SIM values** (`ue2`: IMSI, K, OPc) only in `~/testbed-secrets/ue2.env` on tiny and Secrets (`open5gs` for the
  dbctl job, `ran2` for the UE); rendered into an in-memory volume; masked in UE logs (OAI prints them at start).
  Never in git, ConfigMaps or this doc.
- **Images**: our own gNB image is built from the signed upstream tag `release_26_10` and a digest-pinned Ubuntu base;
  its Dockerfile lives in the repo and the image digest is recorded. The OCUDU upstream vulnerability attestation was
  empty (S1), so scan our image ourselves (e.g. grype) before use. OCUDU's example InfluxDB token (`fake-token-...`)
  and anonymous Grafana are not used.
- **Privileges**: the UE container is privileged (tun), as on REDLAB; the gNB container gets only `SYS_NICE`,
  `IPC_LOCK` and `PERFMON` (needed by the binary's file capabilities), not the `privileged` + USB mounts of OCUDU's
  compose file.
- **Over-the-air**: none. The `gnb-uhd` image can drive USRPs; tiny has no SDR and the config uses
  `device_driver: zmq` only.

## 7. Risks
| Risk | Effect | Mitigation |
|---|---|---|
| UE traffic bypasses the radio (shared namespace with `ogstun`) | Meaningless throughput | One pod without `hostNetwork`; route gate in `ran2.sh check` (3.1) |
| OCUDU pod starves or crashes the core on tiny | Both cells lose service | CPU/memory limits; `taskset` to P-cores; step 2 gate; `ran2.sh remove` |
| OAI w40 UE over ZMQ with OCUDU 26.10 untested by us; ZMQ fixes landed after w40 | No attach or unstable UL | Try w40 first; then a newer OAI UE tag for this cell only; fallback srsUE (FDD) |
| **Confirmed (S1):** published images have no ZMQ driver | gNB cannot use ZMQ | Own image (S1b); `ran2.sh check` greps the gNB log for `Available radio types: ... zmq` |
| Own image drifts from upstream / is rebuilt differently | Results not reproducible | Pin the source tag and base image digest, keep the Dockerfile in the repo, record the image digest in each result |
| gNB memory at start above 2 GiB | OOM kill, pod restarts; with `IPC_LOCK` memory may be locked (not swappable) | 6 GiB limit; measure RSS and locked memory (`VmRSS`, `VmLck`) in step 1 and tighten |
| SCTP and GTP-U from a pod IP through `cni0` (flannel/iptables) | NG Setup fails or N3 drops | Check in step 1; fallback: gNB container with `hostNetwork` and only the UE in a separate namespace (more complex ZMQ wiring) |
| Pod IP changes on restart | AMF/UPF see a new gNB address | Rendered at start from `status.podIP`; the AMF accepts the new NG Setup |
| Disk on tiny (16 GB free) | Image pull fails, node disk pressure evicts core pods | Check free space first; prune unused images; keep under 80 % |
| Comparison confounded by CPU type (P-core vs REDLAB) | Wrong conclusion | State the CPUs; cross-check window in section 5 |
| Static CPU manager later | k3s restart = core restart | Only if `taskset` is not enough, and only with the user's OK |

## 8. Open questions
1. OK to add a second subscriber (`ue2`) to the core and extend `open5gs.sh` for it?
2. OK to add a third iperf3 port (5203) on tiny for concurrent tests (step 2)?
3. UE choice: OAI nrUE over ZMQ first (same UE in both cells), srsUE later for FDD; agreed?
4. Second cell on the dashboard: one extra column per KPI, or a separate "Cell 2" page?
5. Resource limits for the OCUDU pod: start with 7 CPU / 5 GiB in total, or tighter?
6. Should Experiment 12 (near-RT RIC) plan for two E2 nodes from the start?
7. Decided 2026-11-06: the image is built on REDLAB and imported into tiny by the user (sudo). Later rebuilds follow the
   same path, or a private registry if rebuilds become frequent.
8. tiny's disk: `/` went from 65 % to 74 % used after S1 (13 GB free). The test images `ocudu_nightly_avx2` (0.5 GB)
   and `images/gnb-uhd` (0.3 GB) are no longer needed; removing them needs `sudo k3s crictl rmi` on tiny.
9. Why does the UL ratio iperf (wall) / MAC (sim) come out at 3.4 while the measured speed is 2.8-2.9 (S3)?
   Possibly `ul_brate` counts only part of the UL (e.g. without retransmissions or padding), or the UL report window
   differs; check against OCUDU's MAC PCAP.

## S1 results (2026-11-04)
Throwaway pods in namespace `default` on tiny (label `fct/stage=s1`, all deleted afterwards; no `hostNetwork`,
no access to the core). Open5GS pods stayed Running (12/12).

| Check | Result |
|---|---|
| Pinned image | No promoted image exists for the release commit `e0db566a` itself. Chosen: `images/gnb-uhd:ubuntu-24.04-avx2-20261001_920f88c7-stable`, digest `sha256:f4ef4323edbb4e6e983387c3aa6ed89d7014d280885e67c37fde6d75599d3049`, 315 MB compressed. `920f88c7` = `release_26_10` plus 29 later commits on `main` (the other candidate, `cb9ca3f2` = rc1, misses one F1-U fix) |
| Signature | `cosign verify` (cosign v2.4.1, keyless, identity `https://gitlab.com/ocudu/ocudu//.gitlab-ci.yml@refs/heads/main`, issuer `https://gitlab.com`): **valid**, transparency log entry verified |
| Vulnerability attestation | Present and signed, but **empty** (no scanner, no result). It gives no CVE information for this image |
| Start | Binary `/usr/local/bin/gnb`, runs as uid 1001, file capabilities `cap_ipc_lock,cap_sys_nice,cap_perfmon=ep`. With only `SYS_NICE`: "Operation not permitted". With all three: `OCUDU 5G gNB version 26.10.0 (920f88c)` |
| ZMQ | Test config with `device_driver: zmq` and `amf.no_core: true`: `Available radio types: uhd and realtime_loopback.` / `Failed to load RF plugin libocudu_radio_zmq.so`. **No ZMQ.** Cause: OCUDU CI builds with `-DENABLE_ZEROMQ=OFF` (`.gitlab-ci.yml`), and the Dockerfile's `build` dependency set has no `libzmq3-dev` |
| All-in-one image | `ocudu_nightly_avx2:20260930_920f88c7-stable` (`sha256:d3fc65c7a777e78c96b47c06bd05e890eb587aa3fd24daa750e45f317a9ae2ec`, 508 MB, signature valid, runs as root): **also no ZMQ** |
| Memory | gNB **OOM-killed under a 2 GiB limit** at start; started under 6 GiB (exited early because the radio type was missing, so steady-state RSS is not yet measured) |
| Host warnings | CPU scaling governor not `performance` on tiny; OCUDU suggests its `ocudu_performance` script (a host change; not applied) |
| UE image | `oai-nr-ue:2026.w40` (amd64 `sha256:d5d3b9b9...`): `/usr/local/lib/liboai_zmqdevif.so` present, linked to `libzmq.so.5`; `--uecap_file` and `--ue-scan-carrier` available. **OK** |
| Disk on tiny | 65 % → 74 % used (13 GB free) |

### S1b: our own gNB image with ZMQ (built 2026-11-06)
[`infra/ran2/Dockerfile.ocudu`](../../infra/ran2/Dockerfile.ocudu), two stages, not OCUDU's full Dockerfile (which
builds UHD and DPDK too):
1. Builder `ubuntu:24.04` (pinned by digest): `git clone --branch release_26_10`, build fails unless HEAD is
   `e0db566a`; build packages plus `libzmq3-dev`; `cmake -DENABLE_ZEROMQ=ON -DENABLE_UHD=OFF -DENABLE_DPDK=OFF
   -DENABLE_SIDEKIQ=OFF -DENABLE_DIFI=OFF -DENABLE_PLUGINS=OFF -DBUILD_TESTING=OFF -DMARCH=x86-64-v3`; only the
   `gnb` target; fails unless the binary links `libzmq`. No RoHC (optional; not needed for the experiment).
2. Runtime `ubuntu:24.04`: runtime libraries plus `libzmq5`; same file capabilities as upstream
   (`cap_ipc_lock,cap_sys_nice,cap_perfmon=ep`); user 1001.

| Check (REDLAB, Docker 29.1.3 legacy builder, `-j2`, `nice 19`) | Result |
|---|---|
| Build | 20 min, OAI cell kept running (REDLAB about 5 GB RAM available during the build) |
| Image | `fct/ocudu-gnb:26.10-zmq`, 246 MB, image ID `sha256:6ecd6e075ff4513b454ae6cda64add68e51b7ebac0c37ad2b48a8a69aa232a51`; `docker save` archive 64 MB, sha256 `ca9f5d256eb414928890f0065f7134350d460338353d30b6087714d2b3f475a6` |
| Version | `OCUDU gNB (commit e0db566)`: exactly the 26.10 release |
| ZMQ | `Available radio types: zmq and realtime_loopback.`; `ldd` shows `libzmq.so.5` |
| Start test (`--network none`, caps SYS_NICE/IPC_LOCK/PERFMON, `amf.no_core: true`, ZMQ config of section 2.2) | ZMQ TX binds `tcp://127.0.0.1:4556`, RX connects to `127.0.0.1:4557`; `Cell pci=1, bw=20 MHz, 1T1R, dl_arfcn=632628 (n78), dl_freq=3489.42 MHz, dl_ssb_arfcn=632256`; `gNB started`; waits for the UE's samples |
| Memory | **RSS 2.73 GB right after start**, `VmLck` 0 (explains the OOM kill at 2 GiB in S1). The 6 GiB limit stays |
| Without the three caps | "Operation not permitted" (as upstream) |
| Note | `Couldn't register stdin handler` (no TTY in a container): harmless; the console is not used |

Import into tiny (2026-11-06): the archive was copied to tiny (checksum verified) and imported by the user with
`sudo k3s ctr -n k8s.io images import /tmp/ocudu-gnb-26.10-zmq.tar` → `docker.io/fct/ocudu-gnb:26.10-zmq`, same image
digest as on REDLAB. The archive was deleted afterwards. Pods use `imagePullPolicy: Never`. Still to do before
real use: scan the image (e.g. grype), because the upstream vulnerability attestation was empty.

| Check on tiny (throwaway pod `s1b-gnb`, namespace `default`, no `hostNetwork`, deleted afterwards) | Result |
|---|---|
| Pod spec | caps `SYS_NICE`, `IPC_LOCK`, `PERFMON`; limits = requests = 4 CPU / 6 GiB; `taskset -c 0-15` (P-cores) |
| Start | `commit e0db566`, `Available radio types: zmq and realtime_loopback.`, ZMQ on `127.0.0.1:4556/4557`, cell PCI 1 n78 20 MHz, `gNB started` |
| Memory / threads | RSS 2.73 GB at 8 s and 16 s (stable, no growth while waiting for the UE), 12 threads, `Cpus_allowed_list: 0-15` |
| Stop | SIGINT gives a clean `Stopping...` (usable as the pod's stop signal) |
| Core | `open5gs` pods 12/12 Running before and after; disk `/` 74 % |

## S2 results (2026-11-06): second cell live, experiment steps 0-1
Files: [`infra/ran2/`](../../infra/ran2/) (`gnb.yml`, `nr-ue2.yaml.tpl`, `uecap_ports1.xml` from OAI 2026.w40,
`ocudu-cell.yaml`, `ran2.sh`); [`infra/core/open5gs.sh`](../../infra/core/open5gs.sh) takes `UE=ue2` (default `ue1`
unchanged). Run: `ssh -t tiny 'sudo MODE=subscriber UE=ue2 bash /tmp/open5gs.sh'` (after `scp`), then
`MODE=apply bash infra/ran2/ran2.sh` on REDLAB as the normal user.

**Step 0, core baseline on tiny** (2026-11-06 17:41 +08, before ran2): load 0.31; 27.4 GB RAM available; node
0.69 cores; all `open5gs` pods together 16m CPU / 1.93 GiB; AMF metrics `gnb 1`, `ran_ue 0`, `amf_session 0` (OAI
gNB up on REDLAB, its UE stopped at that time). Two core pods already had 2 restarts each (from before this work).

**Subscriber `ue2`**: `open5gs.sh MODE=subscriber UE=ue2` created `tiny:~/testbed-secrets/ue2.env` (random K/OPc,
mode 600) and wrote IMSI 001700000000002; its full core check: RESULT PASS.

**Step 1, attach** (`ran2.sh MODE=apply`, first try): **RESULT PASS, 16/16 gates**: pod on pod IP 10.244.0.98, no
`hostNetwork`, no restarts; ZMQ radio; NGAP association from the pod IP; AMF `gnb = 2`; UE `oaitun_ue1 10.45.0.22/24`;
`ip route get 10.45.0.1` → `dev oaitun_ue1` inside the pod; ping 10.45.0.1 through the UE tunnel; tiny host has no
10.45 route outside `ogstun`; ZMQ 4556 and remote control 8001 on 127.0.0.1 only; UE log holds none of the SIM values
and shows the masked [SIM] line; all core pods Running; the OAI gNB's NGAP association on REDLAB still up.

| Time (UTC, 2026-11-06) | Event | Source |
|---|---|---|
| 09:48:39 / :40 / :41 | pod / gNB / UE container start | pod status |
| 09:48:43.6 | ZMQ TX bound 127.0.0.1:4556, RX connected 127.0.0.1:4557; `Cell pci=1, bw=20 MHz, dl_arfcn=632628 (n78), dl_ssb_arfcn=632256` | gNB log |
| 09:48:45.05 | `N2: Connection to AMF on 10.42.0.2:38412 completed`; AMF: `gNB-N2 accepted[10.244.0.98]`, `Number of gNBs is now 2` | gNB, AMF |
| 09:48:47.08 | UE carrier scan: cell detected at GSCN 7835, SSB 3483.84 MHz (= SSB ARFCN 632256), PSS peak 107 dB | UE log |
| 09:48:47.72 / :47.84 | RAR received (RAPID 8), RRCSetup, `NR_RRC_CONNECTED`, Registration Request | UE log |
| 09:48:48.12 | AMF: InitialUEMessage (SUCI) | AMF log |
| 09:48:48.81 | AMF: Registration complete; SM context for DNN `fctoai`, S-NSSAI SST 1 | AMF log |
| about 09:48:49 | PDU session up (AMF `amf_session 1`, `ran_ue 1`) | AMF metrics |

Pod start to user plane: **about 10 s**, of which about 3 s are the gNB's start-up (memory allocation before ZMQ).

First observations (idle cell, no traffic; to be measured properly in steps 3-5):
| Item | Value |
|---|---|
| CPU (`kubectl top`, idle) | gNB 1.18 cores, UE 0.11 cores. Hypothesis: the OCUDU lower PHY polls ZMQ continuously, while the OAI UE waits on it |
| Memory | gNB 2.69 GiB, UE 0.50 GiB |
| tiny after start | load 1.58, node 1.73 cores (5 %), 24.1 GB RAM available; core pods unchanged |
| Ping UE → 10.45.0.1 (10 × 0.2 s) | 0 % loss, RTT min/avg/max 49 / 119 / 168 ms: much higher than expected for a 5 ms TDD period. To investigate in step 3 (ZMQ pacing slower than real time? UL scheduling request / grant delay?) |

The cell keeps running on tiny after S2. Stop it with `MODE=remove CONFIRM=yes bash infra/ran2/ran2.sh`
(the `ue2` subscriber and SIM file stay).

## S3 results (2026-11-06): experiment steps 2-6
Script: [`infra/exp/exp16-ocudu.sh`](../../infra/exp/exp16-ocudu.sh) (`MODE=run`, from REDLAB, no sudo). The pod got a
third container `tools` (alpine 3.20: iperf3, Python WebSocket reader [`wsdump.py`](../../infra/ran2/wsdump.py)) so the
measurements run in the pod's namespace through `oaitun_ue1`. CPU per container comes from the host cgroup
(`cpu.stat` of each container scope on tiny), because the privileged UE container sees the host's root cgroup.

### The OAI w40 UE made the ZMQ cell run at 0.2x real time
OCUDU reports metrics every 1000 ms of **simulated** time (slot-counted); with the w40 UE these reports arrived every
**4.9 s of wall time**: the cell ran at **0.20x real time**, and ping UE → 10.45.0.1 took 49 / 119 / 168 ms
(min / avg / max). OAI's ZMQ driver at w40 polled its TX queue every 10 ms; OAI fixed this on 2026-10-14 (`439dc0eb`,
"wake tx_poll_thread on queue push instead of 10ms poll") and the RX rounding of negative samples on 2026-10-16
(`02a4a2df`); both are first in tag **2026.w43**. With `oai-nr-ue:2026.w43` (OCUDU cell only; the OAI cell stays on
w40) the same cell runs at **5.9-6.6x real time when idle** (report interval 0.167-0.179 s) and ping takes
3.9 / 5.4 / 6.6 ms wall (about 30 ms simulated). Like rfsim (Experiment 0c), ZMQ is not paced: the simulation runs as
fast as the slower side allows, so throughput is reported both in wall time (iperf) and in simulated time (MAC).

### Steps 3-5: capacity, TCP, compute (51 PRB, TDD as the OAI cell, CQI 15, BLER 0 in every phase)
| Run | Phase | Speed (sim s / wall s) | MAC goodput (sim) | iperf (wall) | MCS | CPU cores gNB / UE (wall) | Cores per simulated s gNB / UE |
|---|---|---|---|---|---|---|---|
| A: default 256QAM table ([data](data/bench-ocudu-20261106T100325Z)) | UDP DL 600M | 2.82 | **65.0 Mbit/s** | 183.4 (69 % loss = saturated) | 27 | 2.32 / 1.95 | 0.82 / 0.69 |
| | UDP UL 300M | 2.92 | 18.4 | 63.0 | 27 | 2.16 / 1.10 | 0.74 / 0.38 |
| | TCP DL, 1 flow | 2.79 | 65.0 | 172.3 | 27 | 2.25 / 1.98 | 0.81 / 0.71 |
| | TCP UL, 1 flow | 2.54 | 17.4 | 42.2 | 27 | 2.13 / 1.16 | 0.84 / 0.46 |
| | idle | 6.62 | - | - | - | 2.33 / 1.01 | 0.35 / 0.15 |
| B: `pdsch mcs_table: qam64`, as OAI ([data](data/bench-ocudu-20261106T100810Z)) | UDP DL 600M | 2.90 | **49.5 Mbit/s** | 146.1 (76 % loss) | 28 | 2.33 / 1.83 | 0.80 / 0.63 |
| | UDP UL 300M | 2.81 | 18.0 | 60.4 | 27 | 2.11 / 1.11 | 0.75 / 0.39 |
| | idle | 5.88 | - | - | - | 2.27 / 1.32 | 0.39 / 0.22 |

Check of the method: for UDP DL, iperf (wall) / MAC (sim) = 183.4 / 65.0 = 2.82 and 146.1 / 49.5 = 2.95, equal to the
measured speed (2.82, 2.90). For UL the ratio is 3.4 against a speed of 2.8-2.9: not explained yet (open question 9).

**Comparison with the OAI cell at 51 PRB (Experiment 1, same TDD pattern, 64QAM, BLER 0):**
| | OAI gNB (rfsim, REDLAB) | OCUDU gNB (ZMQ, tiny), run B |
|---|---|---|
| MAC DL goodput (simulated time) | 43.3 Mbit/s, MCS 28 | **49.5 Mbit/s (+14 %)**, MCS 28 |
| Share of the 3GPP TDD peak (60.8 Mbit/s at 64QAM) | 71 % | 81 % |
| With OCUDU's default 256QAM table | (not configured) | 65.0 Mbit/s (+50 %), above the 64QAM peak |
| Simulation speed under DL load | 3.40x | 2.90x |
| CPU per simulated second, gNB / UE | 0.33 / 0.71 | 0.80 / 0.63 (UE = OAI nrUE w43 over ZMQ) |
| CPU-seconds per Mbit (simulated), gNB / UE / total | 0.0076 / 0.0164 / 0.024 | 0.0162 / 0.0127 / 0.029 |

Reading (hypotheses, not yet proven):
- **More goodput at the same MCS and PRBs**: OCUDU spends less of the slot on overhead or schedules more DL symbols
  (PDCCH, DMRS, CSI-RS and SSB placement differ). To check by comparing PDSCH symbols and PRBs per slot
  (`pdsch_prbs_used_per_tdd_slot_idx` in OCUDU's metrics, the T-tracer grid of Experiment 1b for OAI).
- **256QAM is the default in OCUDU** (`du_high_config.h`: `mcs_table = qam256`): at CQI 15 it gives +31 % over 64QAM.
  A teaching point: same cell, same SINR, different MCS table.
- **The OCUDU gNB costs about 2.2 cores regardless of load** (idle 2.27-2.33, saturated 2.1-2.3): its threads poll
  rather than sleep. Per simulated second it is therefore cheapest when the simulation runs fast. Per Mbit it costs
  about twice the OAI gNB; the OAI UE costs a little less behind OCUDU than behind OAI's gNB. Different CPUs (tiny
  i9-14900 P-cores vs REDLAB Core Ultra 9 285) and different simulators (ZMQ vs rfsim), so read the CPU numbers as
  orders of magnitude, not as a ranking of the two stacks.
- **One TCP flow** reaches 94 % (DL) and 67 % (UL) of the UDP wall goodput.

Core during the runs: UPF 39m CPU, AMF/SMF 1m; tiny node 3.3 cores (10 %); `open5gs` pods unchanged (no new restarts).

### Step 6: stop/start (pod recreated by a config change, 2026-11-06 17:56 +08, AMF metrics polled every second)
| Time | AMF `gnb` / `ran_ue` / `amf_session` |
|---|---|
| 17:56:12 | 2 / 1 / 1 (both cells, OCUDU UE attached) |
| 17:56:23 | 1 / 0 / 1 (old OCUDU pod gone; session context still held) |
| 17:56:36.5 | 2 / 0 / 1 (new gNB: NG Setup) |
| 17:56:39.6 | 2 / 1 / 1 (UE registered again, new PDU session) |

The OCUDU cell was down for **about 16 s**; the OAI gNB's NGAP association on REDLAB stayed up the whole time.
`ran2.sh MODE=check` afterwards: PASS.

### Step 2: both cells loaded at once (isolation), 2026-11-06
Script: [`infra/exp/exp16-step2.sh`](../../infra/exp/exp16-step2.sh). Setup by hand before, undone after:
OAI UE started on REDLAB (`oai-nr-ue` 0 → 1 replica; it had been stopped), OAI cell switched to `bw-51` through the
profile relay (25 s), and a temporary iperf3 server on tiny `10.45.0.1:5203` (pod `exp16-iperf5203`, namespace `ran2`)
for the OCUDU cell; the OAI cell keeps `10.45.0.1:5202`. Both cells at 51 PRB, 64QAM, TDD 7/2. UDP DL above the link
rate: OAI 250M (as Experiment 1), OCUDU 600M; 30 s per phase: OAI alone, OCUDU alone, both.

| Run | Phase | OAI cell iperf (wall), loss | OCUDU cell iperf (wall), loss | OCUDU speed / MAC DL (sim) | CPU OAI gNB / UE (REDLAB) | CPU OCUDU gNB / UE (tiny) | UPF cores | tiny load (1 min) |
|---|---|---|---|---|---|---|---|---|
| [1](data/bench-ocudu-step2-20261106T101508Z) | OAI alone | 140.7 Mbit/s, 43.7 % | - | - | 1.21 / 2.48 | 2.38 / 1.05 (idle) | 0.09 | 4.1 |
| | OCUDU alone | - | 145.6, 75.7 % | 2.90 / 49.5 | 0.93 / 1.28 (idle) | 2.36 / 1.84 | 0.31 | 4.1 |
| | **both** | **143.4, 42.6 %** | **144.0, 76.0 %** | 2.86 / 49.5 | 1.22 / 2.48 | 2.37 / 1.86 | 0.41 | 5.6 |
| [2](data/bench-ocudu-step2-20261106T101728Z) | OAI alone | 140.4, 43.8 % | - | - | 1.24 / 2.49 | 2.40 / 1.05 | 0.09 | 4.4 |
| | OCUDU alone | - | 145.2, 75.8 % | 2.89 / 49.5 | 0.92 / 1.28 | 2.36 / 1.84 | 0.31 | 5.2 |
| | **both** | **143.6, 42.6 %** | **143.5, 76.1 %** | 2.84 / 49.5 | 1.22 / 2.47 | 2.37 / 1.85 | 0.41 | 5.2 |

**RESULT: PASS in both runs.** With the other cell loaded, the OAI cell's goodput changed by +1.9 % / +2.3 % and the
OCUDU cell's by −1.1 % / −1.2 % (limit −5 %); the OCUDU MAC goodput in simulated time stayed at 49.5 Mbit/s; no core
pod restarted. The shared core is not a bottleneck at these rates: the UPF needed 0.09 cores for the OAI cell's
140 Mbit/s and 0.41 cores for both cells together. It costs more for the OCUDU cell because its 600M offered load is
forwarded by the UPF and dropped later, in the radio queue (76 % loss). The OAI cell runs slightly faster with the
OCUDU cell loaded (+2 %, both runs); not explained, within run-to-run spread of other experiments.

Afterwards: OAI cell back on `bw-106` (relay, 25 s), `oai-nr-ue` back to 0 replicas, temporary iperf3 server removed
(port 5203 closed); `ran2.sh MODE=check`: PASS.

## Proposed stages (each only with the user's OK)
| Stage | Where | Changes the bench? |
|---|---|---|
| S0 | tiny: read-only inventory (done 2026-11-03: CPU, RAM, load) | No |
| S1 | tiny: pull and verify the OCUDU image, test start and ZMQ in throwaway pods, check the UE image. **Done 2026-11-04**: no ZMQ in published images | Images only (disk on tiny) |
| S1b | REDLAB: own OCUDU image with ZMQ; import into tiny; throwaway-pod check on tiny. **Done 2026-11-06** | REDLAB CPU for 20 min; image on tiny |
| S2 | tiny: subscriber `ue2`; namespace `ran2` with Secret, ConfigMaps, Deployment, `ran2.sh check`; experiment steps 0-1. **Done 2026-11-06, PASS** | Yes (core subscriber DB, new gNB on the AMF) |
| S3 | Experiment steps 2-6 (`exp16-ocudu.sh`, `exp16-step2.sh`). **Done 2026-11-06, all PASS** | OCUDU pod; for step 2 temporarily the OAI cell (UE on, `bw-51`) and a temporary iperf3 server, both undone |
| S4 | Relay sidecar + Service + NetworkPolicy + Prometheus scrape job + dashboard column; experiment step 5 | Yes (Prometheus config, dashboard) |

## Sources
- OCUDU code and releases: [gitlab.com/ocudu/ocudu](https://gitlab.com/ocudu/ocudu) (tags `release_26_04`, `release_26_10`; `CHANGELOG`, `LICENSE`, `docker/Dockerfile`, `docker/docker-compose.yml`, `docker/.env`, `docker/scripts/install_dependencies.sh`, `CMakeLists.txt` `ENABLE_ZEROMQ`)
- OCUDU docs ([docs.ocudu.org](https://docs.ocudu.org), source [ocudu_docs](https://gitlab.com/ocudu/ocudu_docs)): [Using srsUE](https://docs.ocudu.org/tutorials/srsue/), [OAI UE](https://docs.ocudu.org/tutorials/oaiue/), [Container images](https://docs.ocudu.org/tutorials/container_images/), [Kubernetes](https://docs.ocudu.org/tutorials/k8s/), [Near-RT RIC](https://docs.ocudu.org/tutorials/near-rt-ric/), [Supported E2 metrics](https://docs.ocudu.org/knowledge_base/e2sm_kpm_metrics/), [Outputs / JSON metrics](https://docs.ocudu.org/user_manual/outputs/), [Migrating from srsRAN](https://docs.ocudu.org/migration/)
- OCUDU O-RAN apps and Helm: [ocudu_o1_adapter](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_o1_adapter), [ocudu_netconf](https://gitlab.com/ocudu/ocudu_elements/ocudu_oran_apps/ocudu_netconf), [ocudu_helm](https://gitlab.com/ocudu/ocudu_elements/ocudu_helm)
- Announcements: [OCUDU 26.04 initial release (ocudu.org)](https://ocudu.org/news/blog-introducing-the-initial-ocudu-technical-project-release-26-04/), [OCUDU 26.10 (SRS)](https://srs.io/ocudu-ecosystem-foundation-announces-ocudu-26-10-bringing-satellite-connectivity-8t8r-mimo-and-multi-beam-operation-to-open-source-ran/), [Linux Foundation: OCUDU Ecosystem Foundation](https://www.linuxfoundation.org/press/linux-foundation-announces-ocudu-ecosystem-foundation-to-accelerate-open-source-ai-ran-innovation)
- OAI ZMQ radio at 2026.w40: [radio/zmq/README.md](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/radio/zmq/README.md), [Dockerfile.nrUE.ubuntu](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/docker/Dockerfile.nrUE.ubuntu) (copies `liboai_zmqdevif.so`), later fixes in the [radio/zmq history](https://github.com/OPENAIRINTERFACE/openairinterface5g/commits/develop/radio/zmq); image tags on [Docker Hub oai-nr-ue](https://hub.docker.com/r/oaisoftwarealliance/oai-nr-ue/tags) (2026.w40: amd64, arm64)
- srsRAN 4G (srsUE): [github.com/srsran/srsRAN_4G releases](https://github.com/srsran/srsRAN_4G/releases) (`release_25_10`)
- Bench: `infra/k3s-node.sh` (tiny pod CIDR 10.244.0.0/16), `infra/core/gen-open5gs.py`, `infra/core/open5gs.sh`, `infra/dash/iperf-core.yaml`, `infra/dash/prom-core.yaml`, `infra/ran/ran.yaml`, `infra/ran/gnb.yaml`, [EXP-01](EXP-01-bandwidth.md), [EXP-12a (PR #38)](https://github.com/rediramli/R-D-Testbed/pull/38)
