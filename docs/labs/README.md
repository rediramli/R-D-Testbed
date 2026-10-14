# Lab experiments

Experiments on the FCT 5G SA testbed (OAI gNB and nrUE in **RF simulator mode only**, Open5GS core),
following the structure of the OAIBOX 5G LAB Manual. There is no over-the-air transmission.

How the work is tracked:

| Stage | Where |
|---|---|
| Planned | GitHub issue with the `lab` label |
| In progress | Draft pull request on branch `lab/NN-name` |
| Done | Pull request merged; results in this folder |

Every result is proven by a scripted test with PASS output and by the bench regression gates
(`bash infra/ran/ran.sh check`, `sudo MODE=check bash infra/dash/dash.sh`, `MODE=check bash infra/dash/kpi.sh`,
`MODE=check bash infra/dash/prom.sh`). Anything not proven is marked as a hypothesis.
(The first LAB-0 run used the old lab's gates `lab0-run.sh`, `d6-test.sh`, `iperf-regress.sh`, `uu-check.sh`.)

Every lab measures the same way (the "PHY measurements" method of the advanced labs): record a baseline, change one
parameter, record again; UE SINR, CQI, MCS, BLER, DL/UL goodput, CCE failures and the KPI page, compared before and
after through the dashboard and Prometheus (30 days kept).

## Status

| # | Experiment | rfsim | Status | Results |
|---|---|---|---|---|
| 0 | DL noise presets (Clean / Moderate / Poor) and dashboard control | yes | Done; bench rerun 2026-10-14 PASS | [LAB-00-noise-presets.md](LAB-00-noise-presets.md) |
| 0b | Noise sweep -20 to -2 dB (SINR, CQI, MCS, goodput curve) | yes | Planned | |
| 0c | Why the DL speed test stays near 50 Mbit/s on the bench while the link carries ~88 (TCP vs UDP) | yes | Done 2026-10-14: one TCP flow is the limit, the link carries 87.5 Mbit/s | [LAB-00-noise-presets.md](LAB-00-noise-presets.md#lab-0c-one-tcp-flow-vs-udp-2026-10-14) |
| 1 | Changing the 5G NR bandwidth | yes | Planned | |
| 2 | Changing the 5G NR central frequency carrier | yes (configuration only) | Planned | |
| 3 | Changing the 5G NR TDD slot configuration | yes | Planned | |
| 4 | Testing the FDD mode | yes (FDD band config) | Planned | |
| 5 | Changing the 5G NR Modulation and Coding Scheme | yes | Planned | |
| 6 | Changing the 5G BWP configuration | yes | Planned | |
| 7 | Testing the 5G NR RACH | yes | Planned | |
| 8 | Testing 5G NR MIMO configurations | yes, CPU-heavy | Planned | |
| 9 | Testing the 5G NR LDPC in uplink | yes | Planned | |
| 10 | Understanding 5G NR with Deep Packet Inspection | yes | Planned | |
| 11 | Understanding 5G NR Security | yes | Planned | |
| 12 | Testing 5G network slicing using an xApp, with xApp monitoring over E2 (KPM) and closed-loop control (RC) | needs a near-RT RIC (FlexRIC) | Planned | |
| 13 | PLMN configuration and 5G SIM card programming | PLMN yes; SIM programming needs physical cards | Planned | |
| 14 | Understanding the 5G NR core | yes | Planned | |
| 15 | NGAP flood and an intrusion detection system (isolated bench LAN only) | yes | Planned | |

The rfsim column is a first assessment, to be confirmed in each lab's issue before work starts.
Order (decided 2026-10-14): 0 (bench rerun), 0c, 0b, then 1 to 14 in order; the four advanced labs are folded in: PHY
measurements as the method of every lab, FlexRIC monitoring and KPM-RC closed loop in LAB-12, NGAP flood + IDS as LAB-15.
