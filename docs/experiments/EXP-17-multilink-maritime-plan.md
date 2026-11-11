# Experiment 17 (plan): resilient multilink connectivity for a ship

Status: **plan** (2026-11-11). Nothing on the bench has changed yet. Every bench change below needs the user's OK first.
Depends on [EXP-16](EXP-16-ocudu-second-gnb-feasibility.md) (second 5G cell on OCUDU, PR #39).

Project context: build connectivity resilience for a ship by using **all of its links together** (multilink), not
one link with a manual backup. The research angle: an AI component that predicts link degradation and steers
traffic before an outage. Literature that does this stops at simulation or recorded traces.

No over-the-air transmission: the 5G links are the bench's two virtual-radio cells (OAI rfsim, OCUDU ZMQ). Satellite
links are emulated with `tc netem` driven by recorded traces. The claims this plan can support concern **the
multilink and steering layer**. It cannot support claims about the maritime radio channel itself.

## Summary
| Question | Answer |
|---|---|
| What is tested | Steering, switching and splitting of a ship's traffic over 2 x 5G + LEO + GEO, under a scripted voyage (port, coast, open sea). AI policy vs the static 3GPP ATSSS steering modes and vs default MPTCP |
| Where | 5G links: OAI cell (REDLAB) and OCUDU cell (tiny), one Open5GS core. Satellite links: netem. **Ship router: the Jetson Orin NX** on the bench LAN. Shore end: tiny |
| Multipath layer | Stage 1: Linux **MPTCP** (kernel, over the top of the 5G PDU sessions). 3GPP ATSSS (MA-PDU session) is a later option: Open5GS has no MA-PDU support |
| AI part | Link-quality predictor (seconds ahead) + steering policy, running on the Jetson. Trained on data recorded on the bench in this experiment |
| Main metrics | Outage time per traffic class, goodput, p99 latency of critical traffic, satellite bytes (cost), number of switches, prediction lead time |
| Main gap closed | AI multilink steering with a **real 5G SA stack** in the loop (attach, RRC, PDU session, GTP-U), not only traces or ns-3 |
| Main limits | No maritime radio channel. The OCUDU cell's ZMQ radio is not paced to real time, so its delay is reshaped with netem. Satellite traces are not from Indonesian waters |
| AI-RAN Alliance fit | AI-on-RAN and the Data-for-AI task group (an open multilink dataset). Not AI-for-RAN: steering is above the RAN |

## 1. Problem and scope
A ship has several links with very different properties, and their availability changes along the voyage:

| Link | Typical availability | Properties (to confirm, see section 4) | Bench emulation |
|---|---|---|---|
| A: operator 4G/5G from the coast | Port and coastal waters, fades with distance from shore | Lowest delay, variable capacity, cheap | OAI cell (rfsim), downlink noise raised along the voyage (method of [EXP-00](EXP-00-downlink-noise.md)) |
| B: private 5G in port | Port only | Low delay, high capacity | OCUDU cell (ZMQ), switched off at departure; delay reshaped with netem |
| C: LEO satellite (Starlink class) | Almost everywhere, short outages (obstruction, satellite handover) | 25-60 ms RTT, 50-200 Mbit/s, bursty, metered | netem replaying a recorded trace |
| D: GEO VSAT | Everywhere, weather fades | ~600 ms RTT, a few Mbit/s, expensive | netem, fixed profile + fade events |

Resilience here means: **critical traffic never stops**, and the other traffic gets the best available capacity at
the lowest cost. Traffic classes (to confirm): engine/navigation telemetry (small, critical), VoIP, CCTV video
uplink, crew internet (bulk).

Out of scope: the maritime radio channel (sea-surface reflection, ship motion), ship-to-ship relaying (IAB), real
satellite terminals.

## 2. Literature and gap (abstracts read, full papers not yet)
| Work | What it does | Method | Gap for us |
|---|---|---|---|
| [Marlink Sealink Multi-LEO](https://www.satellitetoday.com/mobility/2026/03/03/marlink-launches-leo-based-service-for-maritime-customers/) (2026) | One managed service over Starlink + OneWeb, network chosen by performance and coverage | Commercial, closed | Method unknown; satellite links only |
| [VTT and partners](https://www.vttresearch.com/en/news-and-ideas/5g-maritime-environments-vtt-and-partners-push-boundaries-connectivity-sea) | Public 5G at the coast, private 5G between ships, satellite as backup | Field trial | Backup, not joint use; no AI |
| 3GPP ATSSS, [TS 24.193 Rel-19](https://www.3gpp.org/ftp/specs/PDF/2026-09/Rel-19/24_series/24193-j60.pdf); [TR 22.841](https://3gpp.org/ftp/tsg_sa/WG1_Serv/TSGS1_104_Chicago/inbox/post_meeting_draft_TRs/DraftTR%2022841v220_rm.docx) (TN + NTN dual access use cases) | MA-PDU session; steering modes Active-Standby, Smallest Delay, Load-Balancing, Priority-based; MPTCP and (Rel-19) MPQUIC | Standard | Rules are static, set by policy; no prediction |
| [FTRL-WRR](https://dspace.library.uvic.ca/items/e300fab6-9d1a-4ed4-940b-bf9ad0aa252e) (UVic thesis, 2024) | Online learning of the traffic split over two paths, QUIC over Starlink | Experiments on two paths | Two paths, no 5G stack, no voyage dynamics. **Reproducible baseline** |
| [PRISM, DRL schedulers for MPQUIC](https://www.sciencedirect.com/science/article/abs/pii/S2542660525001301) (2025) | DRL actor-critic scheduler, robust to outages | Lumos5G + Starlink traces | Trace-driven only |
| [MAMS](https://www.ece.uvic.ca/~cai/ton24-mams.pdf) (IEEE/ACM ToN) | Multipath QUIC scheduler that forecasts link variation | Cellular + Wi-Fi | No satellite |
| [5G-MANTRA](https://dl.acm.org/doi/pdf/10.1145/3609382.3610511) | ATSSS testbed: Open5GS + free5GC N3IWF + MPTCP proxy at the UPF | Testbed | Maintenance status unknown; 3GPP + Wi-Fi, no satellite |
| [Starlink Robot dataset](https://arxiv.org/abs/2506.19781) (2025) | Starlink metrics while moving, with motion and sky visibility | Dataset (land) | Land, not sea; usable as LEO trace source |
| [CNN-BiLSTM-AM](https://doi.org/10.3390/electronics14071367) (Electronics 2025) | Predicts ship-to-shore link connection probability from sea and ship-motion data | Historical data | Prediction only, no steering |

**Gap**: no published work runs predictive, AI-driven multilink steering for a ship with a real 5G SA stack in the
loop. The standard has the mechanism (ATSSS) but static rules. The learning work is trace-driven.

## 3. Target architecture on the bench
```
             SHIP                                                   SHORE
 ┌─────────────────────────────────┐
 │ Jetson Orin NX: ship router     │── wg-a ── UE1 netns (REDLAB) ── OAI cell ──┐
 │  - MPTCP endpoint, policy       │── wg-b ── UE2 pod (tiny)  ── OCUDU cell ───┤ Open5GS UPF ── shore server
 │    routing per traffic class    │                                            │ (10.45.0.1)    (tiny)
 │  - predictor + steering policy  │── sat-c ── netem (LEO trace) ── LAN ───────┤ (10.42.0.2)
 │  - traffic generators per class │── sat-d ── netem (GEO profile) ─ LAN ──────┘
 └─────────────────────────────────┘
```
- **Paths A and B** use the real 5G stack. The UE tunnels live on two machines (REDLAB, tiny), so each is reached from
  the Jetson through a WireGuard tunnel into the UE's network namespace, with policy routing so that traffic entering
  `wg-a` can only leave through `oaitun_ue1` (gate, as the route checks in `infra/ran2/ran2.sh`).
- **Paths C and D** go over the bench LAN through netem qdiscs (on the Jetson egress and the shore ingress, so both
  directions are shaped).
- **Shore end** on tiny: an MPTCP server reachable at 10.45.0.1 (through the 5G paths) and 10.42.0.2 (through the
  satellite paths). MPTCP announces both addresses, one subflow per path.
- **Voyage controller** (script): one timeline drives all four paths: noise on the OAI cell, OCUDU cell on/off,
  trace position for LEO, fade events for GEO. Same timeline, same seed, for every policy compared.

## 4. Open decisions (needed before stage M1)
| # | Question | Why it matters |
|---|---|---|
| D1 | Which links does the target ship really have (Starlink, VSAT, which coastal operator, port Wi-Fi/5G, VHF data)? | Sets the path list and the profiles |
| D2 | Which applications are critical, and their needs (rate, delay, loss)? | Sets the traffic classes and the PASS limits |
| D3 | Who is the client (operator, ship owner, research programme)? Must the result follow 3GPP ATSSS, or is over-the-top multipath enough? | ATSSS needs MA-PDU support in the core (not in Open5GS): much more work |
| D4 | Is there real voyage data (link logs, AIS track) we may use? | Realistic timelines and a training set closer to the sea |
| D5 | Jetson Orin NX: JetPack/L4T version and whether its kernel has MPTCP enabled | MPTCP needs `CONFIG_MPTCP`; otherwise MPQUIC in user space (no kernel change) |

## 5. Stages
Each stage ends with a scripted test with PASS output, as for every experiment ([README](README.md)).

| Stage | Work | Gate (PASS) | Bench change |
|---|---|---|---|
| **M0** | Answer D1-D5; pick the LEO trace source; write the voyage timeline (port 15 min, coast 30 min, open sea 30 min, arrival 15 min, compressed for runs) | Decisions recorded in this file | none |
| **M1** | Link emulator: netem replay of a trace (rate, delay, loss, outages) at 1 s steps, both directions | Replayed path reproduces the trace's median RTT, rate and outage durations within 10 % (iperf3 + ping) | netem on Jetson and shore side (removable) |
| **M2** | Ship router: WireGuard into both UE namespaces, policy routing, 4 paths up from the Jetson | Each path reachable on its own; traffic of each path leaves only through its own link (route and capture check); 5G cells and core gates unchanged (`ran.sh check`, `ran2.sh check`, `kpi.sh`) | Jetson config, a WireGuard peer in each UE namespace; keys in Secrets, never committed |
| **M3** | Baselines: MPTCP default scheduler, MPTCP backup mode, and the ATSSS modes (Active-Standby, Smallest Delay, Load-Balancing, Priority-based) as routing policies | Every baseline runs the full voyage timeline 3 times with the same result order; per-class metrics recorded | none new |
| **M4** | Data: record per path (RTT, loss, rate, outage) and per cell (SINR, CQI, MCS, BLER from the KPI pipeline and OCUDU metrics) at 1 s, aligned on the voyage clock | Dataset with schema and README; no SIM values or keys inside | none new |
| **M5** | AI: predictor of path degradation 5-30 s ahead (start simple: gradient boosting, then a small LSTM/TCN), and a steering policy (predictive switch + split weights; FTRL-WRR reproduced as the learning baseline). Runs on the Jetson | Predictor beats "last value" on held-out voyages; inference fits a 100 ms control step on the Jetson | model on the Jetson |
| **M6** | Evaluation: all policies, same timelines, 5 repetitions each; plus failure tests (cut any path suddenly) | PASS limits set in M0 from D2, e.g. critical telemetry outage = 0 s, VoIP outage below the baseline | none new |

## 6. Metrics
| Metric | Per | Note |
|---|---|---|
| Outage time (no delivery for > 1 s) | traffic class | Main resilience metric |
| Goodput | class, path | Wall clock; the OCUDU cell's simulated time does not apply to this experiment because its delay is reshaped |
| Latency p50/p99 | class | VoIP and telemetry |
| Satellite bytes | path | Cost proxy (C and D are metered) |
| Path switches per hour | policy | Stability (flapping) |
| Prediction lead time and error | predictor | Seconds of warning before a degradation |

## 7. Risks
| Risk | Effect | Mitigation |
|---|---|---|
| OCUDU ZMQ link not paced to real time (EXP-16 S3: ~5-6x) | Unrealistic delay and rate on path B | Shape path B with netem to the port-5G profile; keep the 5G stack for its procedures (attach, release, re-attach) |
| No maritime channel | Path A fading does not look like the sea | Drive the noise setting from a recorded or published coastal profile; say so in every result |
| Jetson kernel without MPTCP | M3 blocked | MPQUIC in user space, or MPTCP on an x86 ship-router VM (decide in M0) |
| WireGuard overhead on the 5G paths | Lower goodput on A and B | Measure in M2, report the overhead; same for all policies |
| Overfitting to our own timelines | Predictor works only on the bench | Hold out whole voyages; use D4 data if available |
| Trace licence | Cannot publish the dataset | Check the licence of each trace source in M0 |

## 8. Bench rules
- Emulation only: no over-the-air transmission, no real satellite terminal, bench LAN only.
- Every bench change needs the user's OK. Nothing is applied by this plan.
- Secrets (SIM values, WireGuard keys) stay in Kubernetes Secrets or `~/testbed-secrets`, never in the repo or logs.
- Netem and routing changes are scripted with `preview`, `apply`, `check` and `remove` modes, like `infra/ran2/ran2.sh`.

## 9. Contribution angle
- **AI-RAN Alliance**: AI-on-RAN (AI steering of a terminal's traffic over 3GPP and non-3GPP access) and the
  Data-for-AI task group (an open, labelled multilink voyage dataset with 5G cell metrics, if the trace licences allow).
- **3GPP angle**: evidence for predictive steering inside ATSSS (TN + NTN use cases of TR 22.841), against the static
  steering modes.
