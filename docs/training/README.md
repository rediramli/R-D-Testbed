# Training modules

Teaching material built on the experiments in [`docs/experiments/`](../experiments/README.md). One module per
experiment. Each module takes a concept from its formula, through a measurement on the testbed, to how an operator
uses it in a live 5G network, and ends with how to use the experiment as a baseline for research.

Audience: final-year undergraduate and master's students in telecommunications, and researchers who want to
measure the impact of a change (a new xApp, scheduler, or integration) on the testbed.

**Safety first.** Everything runs in OAI RF simulator mode (`--rfsim`): the radio signal is a stream of samples in
software and nothing is transmitted over the air. There is no spectrum licence for over-the-air tests. Never remove
`--rfsim`, never use a USRP, and never commit SIM keys or passwords.

## Modules

| Module | Experiment | Core ideas | Status |
|---|---|---|---|
| [0](MOD-00-link-adaptation.md) | 0, 0b, 0c | dB, SINR, Shannon, CQI/MCS tables, link adaptation, BLER, goodput vs throughput, TCP vs UDP | Ready (measured) |
| [1](MOD-01-bandwidth.md) | 1 | PRB grid, numerology, NR-ARFCN, peak rate (TS 38.306), RIV, cost of bandwidth in CPU | Ready (measured) |
| 2 | 2 | Carrier placement, GSCN/SSB raster, point A | Planned |
| 3 | 3 | TDD frame, DL/UL split, latency | Planned |
| 4 | 4 | FDD, duplex spacing | Planned |
| 5 | 5 | Fixed vs adaptive MCS, outer-loop link adaptation, BLER target | Planned |
| 6 | 6 | Bandwidth parts, CORESET, PDCCH aggregation level, CCE blocking | Planned |
| 7 | 7 | Random access, PRACH formats, RACH success rate | Planned |
| 8 | 8 | MIMO rank, layers, capacity of parallel channels | Planned |
| 9 | 9 | LDPC, HARQ, UL decoding errors | Planned |
| 10 | 10 | GTP-U, user-plane inspection, overhead per layer | Planned |
| 11 | 11 | 5G AKA, key hierarchy, ciphering and integrity | Planned |
| 12 | 12 | Near-RT RIC, E2, KPM monitoring, RC control, closed loop (xApps) | Planned |
| 13 | 13 | PLMN, TAC, subscriber provisioning | Planned |
| 14 | 14 | Registration, PDU session, core procedures end to end | Planned |
| 15 | 15 | N2 control-plane flood, anomaly detection (isolated bench only) | Planned |

A module is written once its experiment has a scripted PASS run; until then it only states the theory and the
predictions, so students can predict first and measure after.

## The structure of every module

1. **Why it matters**: the operator problem the concept solves.
2. **Learning objectives**: what a student can do after the module.
3. **Theory and formulas**: from first principles to the 3GPP definition, with the clause number.
4. **Worked examples**: the formulas applied to the testbed configuration.
5. **Testbed procedure**: the script, its preview and run modes, and the PASS criteria.
6. **Measured results**: the numbers from our runs, and what they prove or leave open.
7. **From the lab to a live network**: how operators use the same idea (KPIs, planning, optimisation).
8. **Research extension**: how to use the experiment as a baseline for a new feature.
9. **Exercises**: questions with answers in collapsed blocks.
10. **References**: 3GPP clauses and the experiment record.

## Suggested teaching plan

Each module fits one session of about 3 hours: 60 min theory and worked examples, 20 min prediction (students write
down what they expect), 60 min testbed run (or replay of our recorded data), 40 min comparison and discussion.
Students who cannot use the bench can work from the recorded data in `docs/experiments/data/`; every figure in the
modules can be reproduced from those CSV files with the plot scripts in the repo root.

## How to use the testbed for research

The experiments are designed so a change can be measured against a recorded baseline:

1. **Baseline.** Run the experiment script unchanged and keep its data folder (`docs/experiments/data/...`).
2. **One change.** Change one thing only: an xApp, a scheduler parameter, a new network function.
3. **Same script, same conditions.** Rerun with the same noise settings, traffic and duration.
4. **Compare like with like.** Compare medians and the p10-p90 spread per step, not single samples. Repeat each run
   at least three times; a difference smaller than the spread between repeats of the baseline is not a result.
5. **Look at the whole chain.** SINR, CQI, MCS, BLER, goodput (the K4 diagnosis order on the dashboard): a change that
   raises goodput by raising BLER is a different result from one that raises goodput at the same BLER.
6. **Keep the history.** Prometheus keeps 30 days of the gNB MAC and UE radio counters, so a before/after can also be
   read from the dashboard's KPI trends.

Limits of the testbed that every result must state:

- The channel is simulated: AWGN only (no fading, no interference from other cells, no mobility) unless a module says
  otherwise. Results show how the protocol reacts, not how a real radio channel behaves.
- rfsim does not run in real time. Rates measured by applications (iperf3, wall clock) differ from rates in
  simulated time (gNB MAC counters): in Experiment 0c the ratio was about 1.46. Always say which clock a rate uses.
- One gNB, one UE (unless a module adds more). Scheduler results for many users need more UEs.
