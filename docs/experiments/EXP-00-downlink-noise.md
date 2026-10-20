# Experiment 0: Controlled downlink noise and link adaptation

Status: **done**. Bench runs 2026-10-14 (Experiments 0, 0b, 0c, PR #24); first runs on the old lab servers
2026-10-08 to 2026-10-11 (commits `6a37bdc` to `dba4729`, PR `lab/00-noise-presets`).
Everything here runs in **RF simulator mode only**: the noise is added in software on the UE receive path; nothing is transmitted.

## Summary (2026-10-14, bench)
| Question | Answer | Where |
|---|---|---|
| Do the four DL noise presets still give the same channel on the bench? | Yes: UE SINR, CQI and MCS match the old lab servers in every phase (Off 45 dB/15/28, Clean 22/14/26, Moderate 14/9/15, Poor 6/5/6) | [Experiment 0](#experiment-0-on-the-bench-presets-during-a-dl-speed-test-2026-10-14) |
| What does the link carry at MCS 28? | 87.5 Mbit/s of MAC goodput (UDP above the link rate), BLER 0 | [Experiment 0c](#experiment-0c-link-capacity-vs-single-flow-tcp-2026-10-14) |
| Why does the DL speed test show about 50 Mbit/s? | It is one TCP flow: it reaches 87.5 for 6-9 s, then loses packets and settles at 50-55 (radio still MCS 28, BLER 0) | [Experiment 0c](#experiment-0c-link-capacity-vs-single-flow-tcp-2026-10-14) |
| How does SINR follow the noise setting? | 2.00 dB of SINR per dB of `noise_power_dB` (AWGN power would give 1): report results against the measured SINR | [Experiment 0b](#experiment-0b-sinr-to-cqimcs-curve-noise-sweep-2026-10-14) |
| Does OAI report the CQI a typical receiver would? | Yes above ~18 dB SINR; 1-2 steps lower below it | [Experiment 0b](#experiment-0b-sinr-to-cqimcs-curve-noise-sweep-2026-10-14) |
| Where does the link reach its peak? | MCS 28 / 87.5 Mbit/s from about 24 dB SINR; still up at 4.3 dB (MCS 4, 9.6 Mbit/s) | [Experiment 0b](#experiment-0b-sinr-to-cqimcs-curve-noise-sweep-2026-10-14) |

![Experiment 0b noise sweep](img/EXP-00b-noise-sweep.png)

## Goal
Offer three repeatable downlink channel conditions (Clean, Moderate, Poor) and switch between them
from the dashboard, so the effect on CQI, MCS and throughput can be shown live.

## Experiment 0 on the bench: presets during a DL speed test (2026-10-14)
The testbed moved to the bench (core on the P3 Tiny, RAN on REDLAB, OAI 2026.w40, UE with the channel model since stage 4d).
`infra/exp/exp00-noise-timeline.sh` repeats the first timeline run (see [Earlier runs](#earlier-runs-on-the-old-lab-servers-2026-10-08-to-2026-10-11)) with the same schedule, CSV format and phase checks; the
switches go through the dashboard API and the samples come from the dashboard's 1 s history.
Run `bench-timeline-20261014T013731Z`: **RESULT: PASS** (every phase in its MCS range, one UE context `c79d`,
no out-of-sync sample, 200 samples).

![Experiment 0 bench timeline](img/EXP-00-noise-timeline-bench.png)

Medians per phase (samples from 10 s after the switch, 30 per phase), next to the first run on the old lab:

| Phase | `noise_power_dB` | UE SINR bench / old | CQI | DL MCS | DL MAC goodput bench / old |
|---|---|---|---|---|---|
| Off | -100 | 45.1 / 45.1 dB | 15 / 15 | 28 / 28 | 48.4 / 90.3 Mbit/s |
| Clean | -11 | 22.1 / 21.6 dB | 14 / 14 | 26 / 26 | 44.6 / 84.1 Mbit/s |
| Moderate | -6.5 | 13.8 / 13.3 dB | 9 / 9 | 15 / 15 | 38.8 / 39.7 Mbit/s |
| Poor | -3 | 6.2 / 5.6 dB | 5 / 5 | 6 / 6 | 14.0 / 14.3 Mbit/s |
| Off | -100 | 45.1 / 45.1 dB | 15 / 15 | 28 / 28 | 45.8 / 90.3 Mbit/s |

Findings:
- **The presets carry over unchanged.** UE SINR within 0.6 dB, CQI and MCS identical in every phase: no recalibration needed.
- **The radio is not what limits Off and Clean on the bench.** At Moderate and Poor the goodput is flat (38.8 and 14.0,
  the same as on the old lab): there the MCS sets the rate. At Off and Clean it swings between about 30 and 77 Mbit/s
  (p10-p90 39.6-70.5 at Off) with MCS 28 and BLER 0. Right after the switch back to Off the goodput reached 83-88 Mbit/s
  for about 4 s (162.8-165.8 s) and then fell back to about 40-50: the queue that built up during Poor drained at the
  full rate. So the link carries about 88 Mbit/s at MCS 28 (as on the old lab), and in steady state the DL speed test
  (one TCP flow, iperf3 `-R`) does not keep the gNB queue full. Hypothesis, tested in Experiment 0c: the TCP flow is
  limited by its sender or round-trip time through rfsim (or the core path), not by the scheduler; a UDP test at a fixed
  rate above 88 Mbit/s separates the two.
- Consequence for the KPIs: the stage 3 baseline (DL 50.9 Mbit/s) is this TCP-limited rate, not the radio capacity.

Reproduce (on REDLAB, repo root, about 3.5 min, no dashboard controls meanwhile):
```
MODE=run bash infra/exp/exp00-noise-timeline.sh
python3 plot-noise-timeline.py docs/experiments/data/bench-timeline-<time> docs/experiments/img/EXP-00-noise-timeline-bench.png "Experiment 0 on the bench: ..."
```

## Experiment 0c: link capacity vs single-flow TCP (2026-10-14)
Question from the bench rerun of Experiment 0: is the DL speed test (one TCP flow) what keeps the goodput near 50 Mbit/s at Off?
`infra/exp/exp00c-tcp-udp.sh` runs three DL phases of 30 s with noise off through a temporary iperf3 client pod bound
to `oaitun_ue1` (server 10.45.0.1:5202, `-R`): TCP, UDP at 200 Mbit/s offered (wall clock), TCP again.
Run `bench-tcpudp-20261014T025110Z`: **RESULT: PASS** (all phases complete, one UE context `c79d`, no out-of-sync).
**Verdict: hypothesis supported.**

![Experiment 0c TCP vs UDP](img/EXP-00c-tcp-udp.png)

| Phase | iperf3 at the UE (wall clock) | MAC goodput median (p90), sim time | DL MCS | DL BLER |
|---|---|---|---|---|
| TCP | 89.0 Mbit/s, 1261 retransmissions | 54.6 (88.4) Mbit/s | 28 | 0 |
| UDP, 200 Mbit/s offered | ~128 Mbit/s received (27.4 % lost) | 87.5 (87.7) Mbit/s | 28 | 0 |
| TCP again | 82.7 Mbit/s, 260 retransmissions | 49.8 (69.6) Mbit/s | 28 | 0 |

Findings:
- The link carries **87.5 Mbit/s** of MAC goodput at MCS 28, steady, with BLER 0: the same as the old lab (~88-90).
  Use UDP at a fixed rate above the link rate when an experiment measures capacity (Experiment 1 onwards).
- One TCP flow reaches that rate for about 6-9 s after its start (MAC 88 Mbit/s, iperf3 ~130 Mbit/s wall clock), then
  loses packets (1261 and 260 retransmissions) and settles at 60-90 Mbit/s wall clock, about 40-60 Mbit/s of MAC
  goodput. The radio stays at MCS 28 and BLER 0 throughout, so the losses are not on the air interface.
  Hypothesis, not tested: a queue on the path (gNB RLC/PDCP buffer, GTP-U or the UE tunnel) overflows when TCP fills
  it, and TCP (CUBIC) backs off and recovers slowly over the long round trip of the simulated link.
- Wall clock vs simulated time in this run: 128 / 87.5 = about 1.46.
- The dashboard speed test stays TCP on purpose (it shows what one application flow gets). The stage 3 baseline
  (50.9 Mbit/s) and the KPI targets built on it describe that TCP flow, not the radio capacity.

Reproduce (on REDLAB, repo root, about 2.5 min, dashboard speed tests stopped, no controls meanwhile):
```
MODE=run bash infra/exp/exp00c-tcp-udp.sh
python3 plot-tcp-udp.py docs/experiments/data/bench-tcpudp-<time> docs/experiments/img/EXP-00c-tcp-udp.png
```

## Experiment 0b: SINR to CQI/MCS curve, noise sweep (2026-10-14)
`infra/exp/exp00b-noise-sweep.sh` keeps one UDP DL flow above the link rate (200 Mbit/s offered) running and steps the
UE's noise from -100 dB through -20 ... -2 dB (1 dB steps, 20 s each, median of the last 12 s) and back to -100 dB.
The noise is set through the UE telnet with the relay's own functions and read back at every step.
Run `bench-sweep-20261014T064929Z`: **RESULT: PASS** (every value read back, 12 samples per step, one UE context `c79d`,
no out-of-sync sample, BLER 0 at every step).

![Experiment 0b noise sweep](img/EXP-00b-noise-sweep.png)

| `noise_power_dB` | UE SINR | CQI (typical) | DL MCS | MAC goodput |
|---|---|---|---|---|
| -100 | 44.1 dB | 15 (15) | 28 | 87.5 Mbit/s |
| -20 to -12 | 38.2 to 23.9 dB | 15 (15) | 28 | 87.5 |
| -11 | 22.5 | 14 (14) | 26 | 81.6 |
| -10 | 20.1 | 13 (13) | 24 | 72.5 |
| -9 | 18.5 | 12 (12) | 21 | 54.5 |
| -8 | 16.9 | 11 (12) | 20 | 52.3 |
| -7 | 13.9 | 10 (10) | 18 | 43.7 |
| -6 | 11.8 | 8 (10) | 13 | 30.4 |
| -5 | 10.1 | 7 (8) | 11 | 23.5 |
| -4 | 8.7 | 6 (8) | 8 | 18.6 |
| -3 | 6.4 | 5 (7) | 6 | 13.9 |
| -2 | 4.3 | 4 (6) | 4 | 9.6 |

Full data: [`data/bench-sweep-20261014T064929Z/curve.csv`](data/bench-sweep-20261014T064929Z/curve.csv).
"Typical" CQI uses the link-level SINR thresholds of the dashboard's CQI panel (BLER 10 %); they are not 3GPP values.

Findings:
- **The UE SINR falls 2.00 dB for every 1 dB of the `noise_power_dB` setting** (linear fit over the 13 steps below
  30 dB SINR; with added AWGN power 1.00 is expected). So the setting does not behave as a noise power in dB: going
  from -11 to -3 dB (8 dB) costs 16 dB of SINR. Hypothesis, not checked against the source: the OAI channel model
  turns the setting into a noise amplitude with 10^(x/10) instead of 10^(x/20), so the noise power moves 2 dB per dB.
  Consequence: report results against the measured SINR, not against the setting.
- **CQI follows the typical table above about 18 dB SINR and sits 1-2 steps lower below it** (median -1, range -2 to 0
  over the 10 steps below CQI 15). OAI is more conservative at low SINR. Hypothesis: a margin in OAI's CQI selection,
  or the gap between the SSB SINR shown here and the CSI-RS SINR the CQI is computed from.
- The gNB follows the CQI one to one: every step of CQI gives a lower MCS, and the BLER stays 0. The link reaches
  MCS 28 and 87.5 Mbit/s at about 24 dB SINR; below that the goodput falls with the MCS (9.6 Mbit/s at 4.3 dB).
- No link loss down to -2 dB (SINR 4.3 dB); the loss point is lower and not measured.

Reproduce (on REDLAB, repo root, about 8 min, dashboard speed tests stopped, no controls meanwhile):
```
MODE=run bash infra/exp/exp00b-noise-sweep.sh
python3 plot-noise-sweep.py docs/experiments/data/bench-sweep-<time> docs/experiments/img/EXP-00b-noise-sweep.png
```


## Running Experiment 0 from the dashboard

The lecturer can run this experiment from the dashboard (Experiments → 0 in the object tree); students only watch and fill in their tables.

1. Unlock the controls with the admin password in the toolbar. gNB and UE must be running; use the 106 PRB baseline carrier.
2. Press **UDP downlink (capacity)** (200M offered at 106 PRB).
3. Choose a noise preset (Off −100 dB, Clean −11 dB, Moderate −6.5 dB, Poor −3 dB) and press **Apply noise preset**. The noise relay changes the UE channel model within a second; no restart.
4. Wait until MCS and goodput have been flat for 20 s, then press **Record**. The row holds SINR, CQI, MCS, BLER, goodput, the noise preset and level and the DL loss; the page adds the spectral efficiency η(MCS) and the prediction k × η × (1 − BLER) with k = 15.9 M RE/s (Module 0).
5. Repeat for each preset, press **Back to Off**, and download the CSV.

Bench check of this path: `MODE=check bash infra/dash/exp-api.sh` (sets Moderate, checks that the MCS goes down and that the goodput is within 20 % of the MCS prediction, then sets Off again).

## Earlier runs on the old lab servers (2026-10-08 to 2026-10-11)
These ran on FCT0170/FCT0173 with the old dashboard (relay on 10.0.129.7). Kept for comparison; the bench results above replace them.

### Method
- AWGN on the UE receive path through the OAI channel model (`channelmod`, model 0), changed through
  the OAI telnet server on 127.0.0.1:9090. rfsim only.
- `exp-noise.sh` sweeps `noise_power_dB`, idle and with the DL speed test, and saves raw statistics and logs.
- Each preset was confirmed with 6 x 10 s samples (first discarded), same RNTI, always in-sync.

### Results
| Preset | `noise_power_dB` | CQI | DL MCS | DL MAC goodput |
|---|---|---|---|---|
| Off | -100 | 15 | 28 | ~78-86 Mbit/s |
| Clean | -11 | 14 | 26 | ~84 Mbit/s |
| Moderate | -6.5 | 9 | 15 | ~39.7 Mbit/s |
| Poor | -3 | 5 | 6 | ~14.3 Mbit/s |

Reproduced on the baseline UE after the integration (`run-20261010T144928Z`). The gNB uses the 64QAM
MCS table (TS 38.214 Table 5.1.3.1-1). Down to -2 dB there was no link loss.

### Integration
1. **Stage A** `ue-chanmod.sh`: the baseline UE carries the channel model (AWGN, -100 dB) and telnet on 127.0.0.1.
2. **Stage B** `noise-relay.py`: a relay on FCT0173 (10.0.129.7:8092) that accepts only the four preset
   names and a shared token; no Kubernetes API access.
3. **Stage C** dashboard v0.8.0: Controls bar "DL channel: Off / Clean / Moderate / Poor".

Tests: `noise-relay.sh` MODE=test PASS; `d6-test.sh` step 6b (Moderate gives MCS 15, Off gives MCS 28) PASS;
`iperf-regress.sh` and `uu-check.sh` PASS.

### Timeline: presets switched during a running DL speed test
`exp-noise-timeline.sh` keeps the DL speed test running and switches Off, Clean, Moderate, Poor, Off every 40 s
through the noise relay (the same path as the dashboard buttons). It samples the gNB MAC statistics and the UE SINR
about every 1.4 s and records the time of every switch. Run `timeline-20261011T160138Z`: **RESULT: PASS**
(every phase in its MCS range, one UE context `607b` throughout, no out-of-sync sample).

![Experiment 0 timeline, old lab servers](img/EXP-00-noise-timeline-oldlab.png)

Raw data: [`data/timeline-20261011T160138Z/`](data/timeline-20261011T160138Z/). Medians per phase (samples from 10 s after the switch, 22 per phase):

| Phase (switch time) | `noise_power_dB` | UE SINR | CQI | DL MCS | DL MAC goodput |
|---|---|---|---|---|---|
| Off (0.0 s) | -100 | 45.1 dB | 15 | 28 | 90.3 Mbit/s |
| Clean (40.3 s) | -11 | 21.6 dB | 14 | 26 | 84.1 Mbit/s |
| Moderate (80.6 s) | -6.5 | 13.3 dB | 9 | 15 | 39.7 Mbit/s |
| Poor (120.9 s) | -3 | 5.6 dB | 5 | 6 | 14.3 Mbit/s |
| Off (161.5 s) | -100 | 45.1 dB | 15 | 28 | 90.3 Mbit/s |

Observations (from this run):
- The chain is visible end to end: more noise lowers the UE SINR, the UE reports a lower CQI, the gNB picks a lower MCS,
  and the goodput falls. CQI, MCS, BLER and goodput change; the UE stays attached and in sync.
- A switch takes 1.0-1.5 s through the relay. CQI and MCS follow in the first or second sample after it.
- Going down, MCS drops in one step (26 to 15, 15 to 6). Going back up to Off, CQI is 15 at once but MCS climbs over
  about 5 s (7, 13, 25, 28 between 163.0 and 167.1 s). Hypothesis, not tested: the gNB raises MCS gradually after a low-BLER period.
- BLER rises briefly after the switches to worse channels (peak 0.027 at Moderate, 0.006 at Poor) and falls below 0.001
  within about 8 s; at Clean it stays 0.
- Goodput reaches the new level 2-8 s after a switch, later than MCS; the goodput value appears to be averaged over a
  window (hypothesis).
- Off gave 90.3 Mbit/s here, above the 78-86 Mbit/s in the table above (different runs and days).

Reproduce (from FCT0170):
```
ssh fct0173 'bash -s' < ~/rdt/exp-noise-timeline.sh
# copy timeline.csv and events.csv from the run folder it names, then:
python3 plot-noise-timeline.py docs/experiments/data/timeline-20261011T160138Z docs/experiments/img/EXP-00-noise-timeline-oldlab.png
```
Do not press the dashboard DL channel buttons while it runs (about 4 minutes).

## Lessons
- `lab0-run.sh` re-creates the UE from `ran/oai-nr-ue-deploy.json`: change the source file, and run lab0 in the test.
- With no DL traffic the gNB reports MCS 0, goodput 0 and a decaying BLER; that is the idle state.
- A slow relay (fixed waits, two telnet sessions) made the dashboard time out although the noise was applied;
  the relay test now fails if a change takes 5 s or more.

## Open
- Check in the OAI source how `noise_power_dB` is turned into noise (hypothesis: amplitude 10^(x/10), giving 2 dB of SINR per dB).
- Why OAI's CQI is 1-2 below the typical value at low SINR (CQI margin, or SSB vs CSI-RS SINR).
- Where the link is lost (below 4.3 dB SINR), and which queue drops the TCP packets in Experiment 0c.
- Steady-state UL goodput on the bench (UL speed test and UDP).
- Add the active preset as a column in the KPI CSV export.
