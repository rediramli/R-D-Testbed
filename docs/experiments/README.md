# Experiments

Experiments on the FCT 5G SA testbed: OAI gNB and nrUE in **RF simulator mode only** (no over-the-air transmission)
and an Open5GS core, on the bench machines (core on the P3 Tiny, RAN on REDLAB).

How the work is tracked:

| Stage | Where |
|---|---|
| Planned | GitHub issue with the `experiment` label |
| In progress | Draft pull request on branch `exp/NN-name` |
| Done | Pull request merged; results in this folder |

Every result is proven by a scripted test with PASS output and by the bench regression gates
(`bash infra/ran/ran.sh check`, `sudo MODE=check bash infra/dash/dash.sh`, `MODE=check bash infra/dash/kpi.sh`,
`MODE=check bash infra/dash/prom.sh`). Anything not proven is marked as a hypothesis.
(The first run of Experiment 0 used the gates of the old lab servers: `lab0-run.sh`, `d6-test.sh`, `iperf-regress.sh`, `uu-check.sh`.)

Every experiment measures the same way: record a baseline, change one parameter, record again; UE SINR, CQI, MCS,
BLER, DL/UL goodput, CCE failures and the KPI page, compared before and after through the dashboard and Prometheus
(30 days kept). Capacity is measured with UDP at a fixed rate above the link rate (Experiment 0c); the dashboard
speed test is one TCP flow and shows what a single application gets.

Teaching material built on these experiments (theory, formulas, worked examples, exercises): [docs/training](../training/README.md).

## Status

| # | Experiment | rfsim | Status | Results |
|---|---|---|---|---|
| 0 | Controlled downlink noise and link adaptation | yes | Done; bench rerun 2026-10-14 PASS | [EXP-00](EXP-00-downlink-noise.md) |
| 0b | SINR to CQI/MCS curve (noise sweep) | yes | Done 2026-10-14: SINR falls 2 dB per dB of the noise setting; CQI 1-2 below typical under 18 dB | [EXP-00, part 0b](EXP-00-downlink-noise.md#experiment-0b-sinr-to-cqimcs-curve-noise-sweep-2026-10-14) |
| 0c | Link capacity vs single-flow TCP throughput | yes | Done 2026-10-14: the link carries 87.5 Mbit/s at MCS 28, one TCP flow 50-55 | [EXP-00, part 0c](EXP-00-downlink-noise.md#experiment-0c-link-capacity-vs-single-flow-tcp-2026-10-14) |
| 1 | Carrier bandwidth (PRB count) and capacity | yes | Done 2026-10-14: 24/51/106/273 PRB carry 18.1/43.3/87.5/226.5 Mbit/s; proportional from 51 PRB up | [EXP-01](EXP-01-bandwidth.md) |
| 2 | Carrier placement: ARFCN and centre frequency | yes (configuration only) | Planned | |
| 3 | TDD DL/UL pattern and the throughput split | yes | Planned | |
| 4 | Paired spectrum (FDD) operation | yes (FDD band configuration) | Planned | |
| 5 | Fixed vs adaptive MCS | yes | Planned | |
| 6 | Bandwidth parts and PDCCH resources (CORESET) | yes | Planned | |
| 7 | Random access and PRACH settings | yes | Planned | |
| 8 | Spatial layers (MIMO rank) | yes, CPU-heavy | Planned | |
| 9 | Uplink channel decoding (LDPC) and UL errors | yes | Planned | |
| 10 | User-plane traffic inspection (GTP-U and application flows) | yes | Planned | |
| 11 | NAS and AS security: keys, ciphering, integrity | yes | Planned | |
| 12 | Near-RT RIC: E2 monitoring (KPM), slice control and closed loop (RC) | needs a near-RT RIC (FlexRIC) | Planned | |
| 13 | Network identity: PLMN, TAC and subscriber provisioning | PLMN yes; writing physical SIM cards needs hardware | Planned | |
| 14 | Core network procedures end to end | yes | Planned | |
| 15 | N2 control-plane flood and anomaly detection (isolated bench LAN only) | yes | Planned | |

The rfsim column is a first assessment, to be confirmed in each experiment's issue before work starts.
Order (decided 2026-10-14): 0 (bench rerun), 0c, 0b, then 1 to 15 in order. Next: Experiment 2.
