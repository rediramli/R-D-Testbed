# Lab experiments

Experiments on the FCT 5G SA testbed (OAI gNB and nrUE in **RF simulator mode only**, Open5GS core),
following the structure of the OAIBOX 5G LAB Manual. There is no over-the-air transmission.

How the work is tracked:

| Stage | Where |
|---|---|
| Planned | GitHub issue with the `lab` label |
| In progress | Draft pull request on branch `lab/NN-name` |
| Done | Pull request merged; results in this folder |

Every result is proven by a scripted test with PASS output and by the four regression gates
(`lab0-run.sh`, `d6-test.sh`, `iperf-regress.sh`, `uu-check.sh`). Anything not proven is marked as a hypothesis.

## Status

| # | Experiment | rfsim | Status | Results |
|---|---|---|---|---|
| 0 | DL noise presets (Clean / Moderate / Poor) and dashboard control | yes | In progress (timeline graph) | [LAB-00-noise-presets.md](LAB-00-noise-presets.md) |
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
| 12 | Testing 5G network slicing using an xApp | needs a near-RT RIC (FlexRIC) | Planned | |
| 13 | PLMN configuration and 5G SIM card programming | PLMN yes; SIM programming needs physical cards | Planned | |
| 14 | Understanding the 5G NR core | yes | Planned | |

The rfsim column is a first assessment, to be confirmed in each lab's issue before work starts.
