# LAB-0: Downlink noise presets and dashboard control

Status: **done** (2026-10-08 to 2026-10-11). Commits `6a37bdc` to `dba4729` on `main`; timeline experiment 2026-10-11 (PR `lab/00-noise-presets`).

## Goal
Offer three repeatable downlink channel conditions (Clean, Moderate, Poor) and switch between them
from the dashboard, so the effect on CQI, MCS and throughput can be shown live.

## Method
- AWGN on the UE receive path through the OAI channel model (`channelmod`, model 0), changed through
  the OAI telnet server on 127.0.0.1:9090. rfsim only.
- `exp-noise.sh` sweeps `noise_power_dB`, idle and with the DL speed test, and saves raw statistics and logs.
- Each preset was confirmed with 6 x 10 s samples (first discarded), same RNTI, always in-sync.

## Results
| Preset | `noise_power_dB` | CQI | DL MCS | DL MAC goodput |
|---|---|---|---|---|
| Off | -100 | 15 | 28 | ~78-86 Mbit/s |
| Clean | -11 | 14 | 26 | ~84 Mbit/s |
| Moderate | -6.5 | 9 | 15 | ~39.7 Mbit/s |
| Poor | -3 | 5 | 6 | ~14.3 Mbit/s |

Reproduced on the baseline UE after the integration (`run-20261010T144928Z`). The gNB uses the 64QAM
MCS table (TS 38.214 Table 5.1.3.1-1). Down to -2 dB there was no link loss.

## Integration
1. **Stage A** `ue-chanmod.sh`: the baseline UE carries the channel model (AWGN, -100 dB) and telnet on 127.0.0.1.
2. **Stage B** `noise-relay.py`: a relay on FCT0173 (10.0.129.7:8092) that accepts only the four preset
   names and a shared token; no Kubernetes API access.
3. **Stage C** dashboard v0.8.0: Controls bar "DL channel: Off / Clean / Moderate / Poor".

Tests: `noise-relay.sh` MODE=test PASS; `d6-test.sh` step 6b (Moderate gives MCS 15, Off gives MCS 28) PASS;
`iperf-regress.sh` and `uu-check.sh` PASS.

## Timeline: presets switched during a running DL speed test
`exp-noise-timeline.sh` keeps the DL speed test running and switches Off, Clean, Moderate, Poor, Off every 40 s
through the noise relay (the same path as the dashboard buttons). It samples the gNB MAC statistics and the UE SINR
about every 1.4 s and records the time of every switch. Run `timeline-20261011T160138Z`: **RESULT: PASS**
(every phase in its MCS range, one UE context `607b` throughout, no out-of-sync sample).

![LAB-0 timeline](img/LAB-00-noise-timeline.png)

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
python3 plot-noise-timeline.py docs/labs/data/timeline-20261011T160138Z docs/labs/img/LAB-00-noise-timeline.png
```
Do not press the dashboard DL channel buttons while it runs (about 4 minutes).

## Lessons
- `lab0-run.sh` re-creates the UE from `ran/oai-nr-ue-deploy.json`: change the source file, and run lab0 in the test.
- With no DL traffic the gNB reports MCS 0, goodput 0 and a decaying BLER; that is the idle state.
- A slow relay (fixed waits, two telnet sessions) made the dashboard time out although the noise was applied;
  the relay test now fails if a change takes 5 s or more.

## Open
- Steady-state UL goodput read 25-38 Mbit/s in the gates vs ~49 documented: to be measured.
- Add the active preset as a column in the KPI CSV export.
