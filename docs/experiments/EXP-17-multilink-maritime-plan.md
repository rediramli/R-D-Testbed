# Experiment 17 (plan): resilient multilink connectivity for a ship

Status: **plan** (2026-11-11), **decisions D1-D5 taken, stage M1 done 2026-11-11 (PASS; D6 open)**. Nothing on the bench has changed yet.
Every bench change below needs the user's OK first. Depends on [EXP-16](EXP-16-ocudu-second-gnb-feasibility.md)
(second 5G cell on OCUDU, PR #39).

Project context: build connectivity resilience for a ship by using **all of its links together** (multilink
bonding), not one link with a manual backup. The ship carries **two cellular operators (two SIMs)** today;
satellite is planned later. The research angle: an AI component that predicts link degradation from the ship's
position and recent signal, and steers traffic before an outage. Published work on this stops at simulation or
recorded traces.

No over-the-air transmission: the two operators are the bench's two virtual-radio cells (OAI rfsim, OCUDU ZMQ),
driven by coverage profiles derived from a real shipborne drive test. The claims this plan can support concern **the
multilink and steering layer**, not the maritime radio channel itself.

## Summary
| Question | Answer |
|---|---|
| What is tested | Steering, switching and splitting of a ship's traffic over **two cellular operators**, along a replayed real voyage. AI policy vs the static 3GPP ATSSS steering modes and vs plain multipath |
| Where | Operator 1: OAI cell (REDLAB). Operator 2: OCUDU cell (tiny). One Open5GS core (the two operators share it; enough for over-the-top multipath). **Ship router: the Jetson Orin NX**. Shore end: tiny |
| Multipath layer | **Over the top**, in user space: the client project's own **application-level multipath proxy** (sub-streams pinned per path, in-order reassembly at the shore) is reused first; MPQUIC is the alternative. 3GPP ATSSS (MA-PDU session) is not needed now (D3) |
| Relation to the client project | The project already runs a 2-SIM bonding gateway with a **learned split controller (contextual bandit) on the same Jetson**, evaluated so far on a calibrated simulation and on the live link. EXP-17 gives it what it lacks: **repeatable replays of measured maritime coverage with a real 5G stack in the loop**, to compare the learned controller with a reactive heuristic and a fixed split |
| Coverage input | The project's shipborne **scanner drive test** (2026-11-05): RSRP per frequency along the GPS track, both operators measured at once. Kept outside this public repo (section 4) |
| AI part | Link-quality predictor (seconds ahead, from position + recent RSRP/SINR) + steering policy, on the Jetson |
| Main metrics | Outage time of the critical class (engine/navigation telemetry), goodput, p99 latency, number of switches, prediction lead time |
| Main gap closed | AI multilink steering with a **real 5G SA stack** in the loop (attach, RRC, PDU session, GTP-U), fed by **measured maritime coverage** |
| Main limits | No maritime radio channel (coverage is replayed as SINR, not propagated). The OCUDU cell's ZMQ radio has no channel model and is not paced to real time. The drive test has no throughput or latency |
| Later | Satellite paths (LEO/GEO, emulated with netem) as stage M7 |
| AI-RAN Alliance fit | AI-on-RAN and the Data-for-AI task group. Not AI-for-RAN: steering is above the RAN |

## 1. Problem and scope
| Path | Link | Availability | Bench emulation |
|---|---|---|---|
| A | Operator 1, LTE/5G from the coast | Varies along the route with distance and band | OAI cell (rfsim); SINR along the route set through the downlink noise setting (method of [EXP-00](EXP-00-downlink-noise.md), SINR to CQI curve of part 0b) |
| B | Operator 2, LTE/5G from the coast | Different coverage holes from operator 1 | OCUDU cell (ZMQ); how to replay its SINR is open (section 7, risk 1) |
| C, D (M7) | LEO and GEO satellite | Planned on the ship later | netem replay of traces |

Resilience here means: **critical traffic (engine/navigation telemetry) never stops**; the other classes get the best
available capacity. Traffic classes: telemetry (critical, small), VoIP, CCTV video uplink, crew internet (bulk,
first to be cut). Only telemetry has a hard requirement (D2).

Out of scope: the maritime radio channel (sea-surface reflection, ship motion), ship-to-ship relaying, real modems.

## 2. Literature and gap (abstracts read, full papers not yet)
| Work | What it does | Method | Gap for us |
|---|---|---|---|
| [MP-QUIC as aggregator for multiple cellular networks](https://www.mdpi.com/2079-9292/11/9/1492) (Electronics 2022) | MPQUIC over several operators at once | Measurements | **Closest to our setup** (multi-operator, MPQUIC); no prediction, no ship |
| [MAMS](https://www.ece.uvic.ca/~cai/ton24-mams.pdf) (IEEE/ACM ToN) | MPQUIC scheduler that forecasts link variation of a moving sender | Cellular + Wi-Fi | Not maritime; no 5G stack in the loop |
| [PRISM, DRL schedulers for MPQUIC](https://www.sciencedirect.com/science/article/abs/pii/S2542660525001301) (2025) | DRL actor-critic scheduler, robust to outages | Lumos5G + Starlink traces | Trace-driven only |
| [FTRL-WRR](https://dspace.library.uvic.ca/items/e300fab6-9d1a-4ed4-940b-bf9ad0aa252e) (UVic thesis, 2024) | Online learning of the split over two paths | Two real paths (QUIC, Starlink) | **Reproducible learning baseline** |
| [Adaptive-FEC for MPQUIC](https://arxiv.org/abs/2607.14482) (2026) | FEC over commercial cellular paths for vehicles | Field test | Another baseline for loss bursts |
| 3GPP ATSSS, [TS 24.193 Rel-19](https://www.3gpp.org/ftp/specs/PDF/2026-09/Rel-19/24_series/24193-j60.pdf); [TR 22.841](https://3gpp.org/ftp/tsg_sa/WG1_Serv/TSGS1_104_Chicago/inbox/post_meeting_draft_TRs/DraftTR%2022841v220_rm.docx) (dual 3GPP access, TN + NTN) | Steering modes Active-Standby, Smallest Delay, Load-Balancing, Priority-based | Standard | Static rules; used here as **baselines** |
| [CNN-BiLSTM-AM](https://doi.org/10.3390/electronics14071367) (Electronics 2025) | Predicts ship-to-shore link connectivity from sea and ship-motion data | Historical data | Prediction only, no steering |
| [Marlink Sealink Multi-LEO](https://www.satellitetoday.com/mobility/2026/03/03/marlink-launches-leo-based-service-for-maritime-customers/), [VTT](https://www.vttresearch.com/en/news-and-ideas/5g-maritime-environments-vtt-and-partners-push-boundaries-connectivity-sea) | Commercial and trial maritime multilink | Closed / field trial | Method unknown; relevant for M7 |

**Gap**: no published work runs predictive multilink steering for a ship with a real 5G SA stack in the loop,
driven by measured maritime coverage of the operators the ship actually uses.

## 3. Target architecture on the bench
```
              SHIP                                                        SHORE
 ┌───────────────────────────────────┐
 │ Jetson Orin NX: ship router       │── tun-a (wireguard-go) ── UE1 netns (REDLAB) ── OAI cell ───┐
 │  - MPQUIC client (user space)     │                                                              ├ UPF ─ shore proxy (tiny,
 │  - predictor + steering policy    │── tun-b (wireguard-go) ── UE2 pod (tiny) ──── OCUDU cell ───┘        MPQUIC server)
 │  - traffic generators per class   │
 └───────────────────────────────────┘
            ▲
   voyage controller: replays the drive test along its clock → SINR per operator → noise setting (A) / see risk 1 (B)
```
- The UE tunnels live on two machines, so the Jetson reaches each through a **user-space WireGuard** (`wireguard-go`;
  the Jetson kernel has TUN but no WireGuard) into the UE's network namespace. Policy routing there makes traffic
  from `tun-a` leave only through `oaitun_ue1` (gate, as the route checks in `infra/ran2/ran2.sh`).
- **Shore proxy** on tiny, reachable through both UE tunnels (10.45.0.1). Applications on the ship talk to local
  sockets; the proxy pair carries them over MPQUIC.
- **netem** (where needed, e.g. to reshape path B's delay) runs on REDLAB or tiny: the Jetson kernel has no
  `sch_netem`.
- **Voyage controller**: one clock for the whole run (the drive test's own clock, sped up if wanted); both operators
  follow the same position, so their coverage holes line up as on the real route.

## 4. Decisions (2026-11-11)
| # | Question | Decision |
|---|---|---|
| D1 | Links on the target ship | **Two cellular operators (two SIMs)**, LTE/5G from the coast. Satellite **planned later** → stage M7 |
| D2 | Critical traffic | **Engine/navigation telemetry**: must never stop. Other classes are best effort, crew internet is cut first |
| D3 | 3GPP ATSSS or over the top | **Over the top first** (no core change). ATSSS can follow; Open5GS has no MA-PDU session support |
| D4 | Real voyage data | **Yes**: the project's shipborne scanner drive test of 2026-11-05 (see below) |
| D6 (open, from M1) | Coverage input for M2: the scanner profiles of M1 (strong, little stress), the ship gateway's per-SIM log from the real route, or a ROMES decode with SINR? | The scanner record has no SINR and the surveyed route is not the ship's route |
| D5 | Jetson kernel (checked 2026-11-11: L4T R35.5, kernel 5.10.192-tegra, 8 cores, 16 GB) has **no MPTCP, no WireGuard, no netem**; TUN yes | **User space on the Jetson**: MPQUIC + `wireguard-go`; netem on the REDLAB/tiny side. No kernel rebuild |

**Drive-test data (D4).** Location: outside the repo, on REDLAB (the project folder of 2026-11-05). This repo is
public, so **raw data, operator names, locations and per-operator numbers stay out of it**; only derived,
anonymised profiles enter it, and only with the data owner's OK. What it contains, as far as it matters here:
- A scanner survey (SIM-independent): about 1 h along a ferry route out to sea and back, every operator at once.
- `gps_track.csv`: timestamp (spreadsheet day number), latitude, longitude, altitude; about 1.5 fixes per second.
- `rsrp_lte.csv`: latitude, longitude, frequency, band, RSRP. **No timestamp**: time comes from joining on the GPS
  position. No throughput, no latency, no handover events. Bands: LTE 700-2600 MHz and NR n78.
- Per-operator figures exist (`operator_kpi.json`), but the folder's README says the operator attribution
  (MCC-MNC) is **not yet decoded**; the attribution method must be checked before it is used (stage M1). The scanner
  also logged RSRQ and SINR in the raw file; only RSRP is decoded so far.

## 5. Stages
Each stage ends with a scripted test with PASS output, as for every experiment ([README](README.md)).

| Stage | Work | Gate (PASS) | Bench change |
|---|---|---|---|
| **M0** | Decisions D1-D5 | Recorded in section 4 (done 2026-11-11) | none |
| **M1** (done 2026-11-11, [results](#m1-results-2026-11-11)) | Profile builder [`infra/exp/exp17-profile.py`](../../infra/exp/exp17-profile.py) (data and output outside the repo): time from the recording's own clock, position from the nearest GPS fix; per operator, best carrier per second (median per carrier, then max); operator from the MCC/MNC in each record; RSRP mapped to SINR with a stated floor (no SINR in the record) | Profile covers the full route with no gap > 5 s; the attribution method is written down; numbers stay outside the repo | none |
| **M2** | Replay on the cells: SINR series → noise setting on the OAI cell (EXP-00b curve); for the OCUDU cell, test the options of risk 1 | The cell follows a replayed step profile: CQI/MCS within one step of the EXP-00b curve, 3 repetitions | OAI noise setting (as EXP-00); OCUDU per risk 1 |
| **M3** | Ship router: `wireguard-go` into both UE namespaces, policy routing, MPQUIC client on the Jetson, proxy on tiny (pick the MPQUIC stack: candidates with multipath support in user space, e.g. XQUIC, picoquic, a multipath quic-go fork) | Each path reachable on its own; each path's traffic leaves only through its own UE tunnel; MPQUIC uses both paths; cell and core gates unchanged (`ran.sh check`, `ran2.sh check`, `kpi.sh`) | Jetson user-space services; a WireGuard peer in each UE namespace; keys in Secrets, never committed |
| **M4** | Baselines on the replayed voyage: single operator (each), Active-Standby, Smallest Delay, Load-Balancing, Priority-based, MPQUIC default scheduler | Every baseline runs the full voyage 3 times with the same result order; per-class metrics recorded | none new |
| **M5** | Dataset: per path (RTT, loss, rate, outage) and per cell (SINR, CQI, MCS, BLER) at 1 s, aligned on the voyage clock, plus position | Dataset schema and README; no SIM values, keys or raw project data inside | none new |
| **M6** | AI: predictor of path degradation 5-30 s ahead (gradient boosting first, then a small LSTM/TCN), input position + recent SINR/CQI/RTT; steering policy: predictive switch + split weights; FTRL-WRR reproduced as the learning baseline. Runs on the Jetson | Predictor beats "last value" on held-out route segments; inference fits a 100 ms control step on the Jetson; telemetry outage = 0 s on the replayed voyage, and lower outage than the best baseline for VoIP | model on the Jetson |
| **M7** (later) | Satellite paths C/D: netem replay of LEO/GEO traces, added as a third/fourth MPQUIC path | As M3/M4 with 3-4 paths | netem on REDLAB/tiny |

### M1 results (2026-11-11)
Script: `python3 -I infra/exp/exp17-profile.py <recording .sqz or .mf> <output folder outside the repo> --ops <MCC-MNC>,<MCC-MNC>`. It refuses an
output folder inside the repo. Numbers per operator are kept with the data, not here.

| Check | Result |
|---|---|
| Gate: both ship operators covered, no gap > 5 s | **PASS**: about 99.5 % of the ~63 min with a reading, longest gap 2-3 s |
| Operator attribution | Each per-carrier record (type 10951) carries MCC (uint16 at +22) and MNC (uint16 at +24) after the frequency anchor. Checked: the most frequent PLMNs are the country's four operators, plus a few foreign cells; every operator's carriers fall in that operator's bands. The `cells` value in the earlier per-operator summary is a grid-cell count, not a radio-cell count |
| SINR / RSRQ | **Not in the record**: the bytes after RSRP hold the carrier bandwidth, flags and the PLMN. The record has **one value per carrier per operator** (one cell, no neighbour list), so interference cannot be computed from it. Other message types (e.g. 10528, the most frequent) are not decoded |
| What the profiles show | Both ship operators keep a strong low-band (900 MHz) carrier along the whole route; with the default floor (-105 dBm), the mapped SINR never falls below 10 dB. **This route does not stress the links**, and the fixed-floor mapping ignores interference, so it is optimistic |

Consequences for the next stages:
1. A replay of this drive test alone will show little difference between policies. Stress comes from the volatile
   events (fades, drops) that the client project models and sees on the live link, and from the higher bands
   (2100-2600 MHz, n78), which do fall far below the low band offshore.
2. Better input than the scanner for M2: **the ship gateway's own per-SIM log** on the real route (RTT, and per-SIM
   RSRP/RSRQ/SINR from the cellular routers, as planned in the client project's drive-test plan), or a ROMES decode
   of the scanner's PCI-level messages with SINR. Decision needed (D6).

## 6. Metrics
| Metric | Per | Note |
|---|---|---|
| Outage time (no delivery for > 1 s) | traffic class | Main resilience metric; telemetry must be 0 |
| Goodput | class, path | Wall clock |
| Latency p50/p99 | class | Telemetry and VoIP |
| Path switches per hour | policy | Stability (flapping) |
| Prediction lead time and error | predictor | Seconds of warning before a degradation |
| CPU and memory on the Jetson | policy | The ship router must stay light |

## 7. Risks
| # | Risk | Effect | Mitigation |
|---|---|---|---|
| 1 | **The OCUDU cell (ZMQ) has no channel model or noise setting** | Operator 2's coverage cannot be replayed the same way as operator 1 | M2 tests, in order: (a) changing the OCUDU gNB's TX gain at run time, if its remote control allows it; (b) a noise/attenuation step in the ZMQ sample path; (c) shaping path B with netem (rate, loss) from the SINR → rate mapping of EXP-00b. Whichever is used is stated in every result |
| 2 | OCUDU ZMQ link not paced to real time (EXP-16 S3: ~5-6x) | Unrealistic delay on path B | Reshape path B's delay with netem on tiny |
| 3 | Operator attribution of the drive test not verified | Wrong operator profiles | M1 gate: method written down and checked against the bands each operator is known to hold |
| 4 | RSRP only, no throughput/latency in the drive test | Rate on the bench comes from the cell's own link adaptation, not from the sea | Accept and state it; ask whether the next campaign can log throughput/latency with SIMs (or decode SINR/RSRQ from the raw file) |
| 5 | MPQUIC stack maturity on aarch64 | M3 delay | Try two stacks in M3; fall back to an x86 router on REDLAB with the Jetson only for the AI |
| 6 | `wireguard-go` overhead on the Jetson | Lower goodput on both paths | Measure in M3; same for all policies |
| 7 | Overfitting to one voyage | Predictor works only on this route | Hold out route segments; more drive tests when available |
| 8 | Project data in a public repo | Leak of client data | Raw data and per-operator numbers stay outside the repo (section 4) |

## 8. Bench rules
- Emulation only: no over-the-air transmission, no real modems or satellite terminals, bench LAN only.
- Every bench change needs the user's OK. Nothing is applied by this plan.
- Secrets (SIM values, WireGuard keys) stay in Kubernetes Secrets or `~/testbed-secrets`, never in the repo or logs.
- Project drive-test data stays outside the repo (section 4).
- Noise, netem and routing changes are scripted with `preview`, `apply`, `check` and `remove` modes, like
  `infra/ran2/ran2.sh`.

## 9. Contribution angle
- **AI-RAN Alliance**: AI-on-RAN (AI steering of a terminal's traffic over several accesses) and the Data-for-AI
  task group (a multilink voyage dataset with 5G cell metrics, if the data owner agrees).
- **3GPP angle**: evidence for predictive steering against the static ATSSS steering modes, for dual 3GPP access
  (two operators) now and TN + NTN (M7) later, as in the use cases of TR 22.841.
