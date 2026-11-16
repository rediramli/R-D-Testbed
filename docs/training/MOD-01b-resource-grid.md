# Module 1b: The resource grid, live — what each PRB and symbol carries

Experiment: 1b (the resource grid through the gNB's T tracer; script `infra/exp/exp01b-grid.sh`). Status: **measured
2026-11-03** ([record](../experiments/EXP-01b-resource-grid.md), stage G1; the dashboard page of stages G2-G3 is built
and shown from recorded captures until its bench install). Prerequisite: [Module 1](MOD-01-bandwidth.md) Section 3.2
(the resource grid). Students should write down their own predictions (Section 4) before looking at Section 6.

## 1. Why it matters

An operator's dashboards show counters: throughput, BLER, connected users. They do not show the resource grid: which
PRBs and symbols actually carry which channel in each slot. Yet most integration and planning questions are grid
questions — where does the SSS sit (a mis-planned SSB means a UE that never finds the cell), how much of the carrier is
left for data, what a random access looks like, why an UL slot is not fully used. On a live network this visibility
needs a spectrum analyser or drive test; on this testbed the gNB's own T tracer shows its transmitted DL grid
(`txdataF`) and received UL grid (`rxdataF`) per slot, together with the scheduler's own labels. The signal and the
scheduler agree — and where they do not, that is the finding.

## 2. Learning objectives

After this module a student can:

1. Draw the slot structure of a TDD pattern (DL slots, the mixed slot, UL slots) and name the channels per symbol.
2. Compute where the SSB sits in the grid from the point A and SSB ARFCNs, and verify it from a measured grid.
3. Read a measured grid: PDCCH, PDSCH (+ DMRS), SSB, CSI-RS in DL; PUSCH, PUCCH, SRS, PRACH in UL.
4. Tell the random access story from the grid: Msg1 to Msg4, with slots, channels and RNTIs.
5. Explain which resources are reserved at fixed places (SSB, CORESET0, CSI-RS, SRS) and what that costs a carrier.
6. Use occupancy-per-slot as a diagnostic: idle cell, full-buffer DL, full-buffer UL, a UE attaching.

## 3. Theory and formulas

### 3.1 The slot structure of the testbed

The bench runs n78, 40 MHz (106 PRB), 30 kHz SCS, and the TDD pattern of `gnb.yaml`
(`dl_ULTransmissionScheduling`): 7 DL slots, 1 mixed slot, 2 UL slots per 10-slot half-frame (0.5 ms per slot,
10 slots per 5 ms). The mixed slot carries 6 DL symbols (0-5), a guard symbol, then UL symbols. So of every 140
symbols: 104 DL symbols, 32 UL symbols, 4 guard — the 7:1:2 slot split (Module 0's x 0.743 DL factor comes from this
arithmetic, not from a table).

### 3.2 The DL grid: what lives where

Per slot of 14 symbols (TS 38.211 clause 7.3/7.4, TS 38.214 clause 5.1):

| Channel | Where | Fixed or scheduled? |
|---|---|---|
| PDCCH (CORESET) | symbol 0 (and 1) of DL slots, PRBs from the CORESET config | fixed place, scheduled content |
| PDSCH + DMRS | anywhere the scheduler gives (type 1 RIV, Module 1 Section 3.4) | scheduled |
| SSB (PSS/SSS/PBCH) | 20 PRB x 4 symbols, every 20 ms | fixed by config |
| CSI-RS | configured density/period (`do_CSIRS: 1` on the bench: full carrier, symbol 13) | fixed by config |
| DMRS of PDSCH | symbols 2-3 of the PDSCH allocation | follows the PDSCH |

The SSB block (TS 38.211 clause 7.4.3.1) is 240 subcarriers (20 PRB) wide and 4 symbols long:

| Block symbol | Content |
|---|---|
| 0 | PSS: 127 subcarriers on the middle 12 PRB (57 reserved each side) |
| 1 | PBCH: all 240 subcarriers |
| 2 | SSS: 127 subcarriers in the middle, PBCH on the edges |
| 3 | PBCH: all 240 subcarriers |

PSS/SSS/PBCH are designed so a blind UE finds them with no other knowledge: PSS gives the physical cell ID group
(3 values), SSS the group's member (336 values), PBCH the rest (SFN, SSB index, core config).

### 3.3 The UL grid: what lives where

| Channel | Where | Note |
|---|---|---|
| PUSCH + DMRS | anywhere the scheduler gives | carries data and, in random access, Msg3 |
| PUCCH | last symbols of UL slots (format 0-4) | SR, HARQ-ACK, CSI; often below the energy threshold in rfsim |
| SRS | configurable last symbol(s) of UL slots | sounding; hypothesis for the bench's UL symbol 13 (Section 6.5) |
| PRACH | configured occasions, long format (839-length sequence) | its own waveform, not part of the PUCCH/PUSCH IQ event (Section 6.4) |

PRACH is a separate waveform at the edge of the UL band; the tracer's UL grid event (`GNB_PHY_PUCCH_PUSCH_IQ`) covers
the PUCCH/PUSCH processing, so a preamble shows up as a *label* (detection event), not as grid energy.

### 3.4 Measuring occupancy from energy

`grid-trace.py` turns on a few T events for 20-80 slots and computes, per slot, the mean energy of the 12 subcarriers
of each PRB in each symbol (dB, whole numbers). A PRB/symbol is **occupied** when it is within 60 dB of the strongest
one in that slot. The 60 dB threshold is the judgement call: it must sit above the noise floor of the simulator
(noise off: the floor is far down; noise on: it rises) and below the weakest real channel (the PBCH edges were 6 dB
down, CSI-RS 11 dB down on the bench — both well inside).

The grid is checked against the scheduler's labels (`rb=[start,end] sym=[s,e] mcs=` for PUSCH, MAC PDUs for PDSCH,
SSB slot from `GNB_PHY_MIB`, RA steps from the detection events). Agreement of both is the PASS criterion.

### 3.5 The random access timeline

From TS 38.213 clause 4.8/8 and the bench values (SCS 30 kHz, 0.5 ms slots):

| Step | Channel | When (bench) |
|---|---|---|
| Msg1 | PRACH (preamble detected) | slot $t$, a UL symbol region |
| Msg2 | PDSCH with the RAR, RA-RNTI | DL slot $t + 11$ (5.5 ms later, inside the RAR window) |
| Msg3 | PUSCH with the TC-RNTI, PRB 0-7, low MCS | 9 slots after the RAR (4.5 ms) |
| Msg4 | PDSCH to the TC-RNTI (contention resolution), 225 bytes on the bench | 11 slots after Msg3 (5.5 ms) |

Msg3's small, low-MCS allocation is the point: a new UE has no CQI yet, so the scheduler plays safe (MCS 1, 8 PRB).
PUCCH first appears after Msg4: the UE answers Msg4's HARQ-ACK on it. Random access itself does **not** use PUCCH.

## 4. Worked examples and predictions

**Example 1: where is the SSB?** From `gnb.yaml`: `dl_absoluteFrequencyPointA: 620040`, `absoluteFrequencySSB: 621312`.

- Frequency of the SSB centre: $F = 3000 + 0.015 \times (621\,312 - 600\,000) = 3319.68$ MHz.
- Offset from point A: $3319.68 - 3300.60 = 19.08$ MHz = $19\,080/30 = 636$ subcarriers $= 53$ PRB.
- The block is 20 PRB wide, centred on 53: **PRB 43 to 62**. (Equivalently the UE's `--ssb` option: $636 - 120 = 516$;
  $516/12 = 43$ = the block's first PRB.)
- Predicted SSB slots: every 20 ms = every 40 slots; on the bench it sits in slot 0 of its period (slot 144.0 in the
  capture: $144 = 3 \times 40 + 24$? No — the capture's slot numbering starts at an arbitrary frame; what matters is
  the period of 40, and the idle grid showed exactly that).

**Example 2: the idle cell.** Predict before running: which slots carry anything? Answer after measuring (Section 6):
the SSB block every 40 slots, CSI-RS on symbol 13 of the SSB slot (full carrier, 11 dB down), and in the following
slot PDCCH + SIB1 PDSCH on PRB 29-68. Every other DL slot empty.

**Example 3: full-buffer DL.** Predict: which PRBs and symbols, which MCS? Measured: PDSCH on PRB 0-105 in every DL
symbol of DL slots, symbols 0-5 of the mixed slot; but *not* the SSB slots' SSB symbols — the scheduler avoids the
block (Module 1's fixed-overhead story, now visible instead of computed).

**Example 4: full-buffer UL.** Predict: PUSCH on all PRBs of UL slot 8. Measured: PRB 0-105, symbols 0-12, symbol 13
left (PUCCH/SRS); the label says `rb=[0,105] sym=[0,12]`.

**Example 5: a UE attaches.** Predict the four steps with channels, PRBs and timings (Section 3.5), then compare with
the measured table in Section 6.

Students: write your prediction table before the run, with a one-line reason per row.

## 5. Testbed procedure

Run on REDLAB from the repo root as the login user, on branch `exp/01b-resource-grid`, rfsim only, **one mode at a
time** (the tracer takes one client, and the modes restart the UE under each other):

```
sudo MODE=preview bash infra/exp/exp01b-grid.sh   # preconditions, changes nothing
sudo MODE=on     bash infra/exp/exp01b-grid.sh    # firewall, gNB with T tracer, UE restart
sudo MODE=check  bash infra/exp/exp01b-grid.sh    # idle, UDP DL, UDP UL captures
sudo MODE=ra     bash infra/exp/exp01b-grid.sh    # random access (capture armed, then UE restart)
sudo MODE=off    bash infra/exp/exp01b-grid.sh    # back to the normal gNB, rules removed
```

PASS criteria (mode `check`): the SSB is found per symbol at the predicted PRB block (symbols 9-11 at PRB 43-62 here —
the check looks for a symbol whose occupied PRBs are exactly the predicted block, not for the whole slot); the UDP DL
grid fills PRB 0-105 in the DL symbols; every PUSCH label matches received energy. PASS for `ra`: Msg1, Msg2, Msg3,
Msg4 in order, twice.

Safety notes (already enforced by the script, worth understanding):

- The T tracer always binds 0.0.0.0 and the gNB uses the host network. `MODE=on` therefore first installs iptables
  rules (DROP TCP 2021 on every interface except lo, comment `fct-exp01b`) and a systemd unit that restores them at
  boot before k3s; every mode fails if the T options are set while the rules are missing. (Learned the hard way,
  2026-10-28 to 2026-11-03: the port was open on the bench LAN, campus WiFi and Tailscale for 6 days. No client was
  connected in that time.) A tracer client receives IQ samples and MAC PDUs, and MAC PDUs can hold NAS identities.
- The tracer costs 2 GiB of RAM (the T cache) while on; one DL slot of grid data must fit the 256 KiB T buffer, so
  captures are refused above 106 PRB (273 PRB would be 344 KB and would abort the gNB).

The same view is on the dashboard (Experiments, 1b): one Snapshot (20/40/80 slots), Live (a new 20-slot snapshot every
about 5 s), the random-access capture, and UDP DL/UL to fill the grid. Install on the bench:
`sudo MODE=apply bash infra/dash/dash.sh`, then `MODE=apply bash infra/dash/grid.sh`, then the tracer with `MODE=on`.

## 6. Measured results

Runs [bench-grid-20261103T064844Z](../experiments/data/bench-grid-20261103T064844Z) (idle, UDP DL, UDP UL) and
[bench-grid-ra-20261103T063206Z](../experiments/data/bench-grid-ra-20261103T063206Z) (random access, two runs),
106 PRB, noise off.

| Case | What the grid shows |
|---|---|
| Idle cell | SSB in slot 0 every 20 ms, PRB 43-62: PSS in block symbol 0, PBCH in 1-3, SSS in the middle of symbol 2 — exactly the prediction of Example 1. CSI-RS across PRB 0-105 on symbol 13, 11 dB weaker. Next slot: PDCCH + SIB1 on PRB 29-68. Every other DL slot empty |
| UDP DL | PDSCH on PRB 0-105 in DL slots (symbols 0-13) and the mixed slot (symbols 0-5); MCS 26-28, TBS about 10 KB per slot; the SSB block is skipped while it is present |
| UDP UL | PUSCH on PRB 0-105, symbols 0-12 of UL slot 8, matching the label `rb=[0,105] sym=[0,12]`; symbol 13 dark |
| Random access | Msg1 (preamble) -> RAR +5.5 ms -> Msg3 on PRB 0-7, MCS 1, TC-RNTI -> Msg4 +5.5 ms, 225 bytes; the same pattern in two runs |

**6.1 Every prediction of Section 4 held** except the SSB slot arithmetic (Example 1's last point): the block period
is 40 slots as predicted; the absolute slot number depends on where the capture starts.

**6.2 The scheduler avoids the SSB, visibly.** In slot 0 under DL load, PDSCH runs on PRB 0-42 only while the SSB sits
on 43-62. Module 1 counted this as fixed overhead; here you can see it.

**6.3 Limits of this view (all found with evidence, see the experiment record).** The UL grid is only available for
slots with slot % 4 = 0 (the tracer event always sends entry 0 of the 4-slot `rxdataF` ring); PRACH has no signal
event (labels only); PUCCH labels are rare in rfsim; captures above 106 PRB are refused (T buffer).

**6.4 The PBCH edges and the SSS are measurable.** In symbol 10 the middle 12 PRB (SSS) are strongest and the edge PRB
(PBCH) are about 6 dB down — the theory picture of TS 38.211 7.4.3.1, read straight off the bench.

**6.5 Open hypotheses (not yet proven).** (a) UL slot symbol 13 occupied across the carrier with no PUSCH label:
hypothesis SRS, to be verified from the gNB config on the bench. (b) One capture had a `GNB_PHY_MIB` label in a slot
whose grid held only CSI-RS, one slot before the SSB block: the MIB event and the DL grid may refer to different slots.

## 7. From the lab to a live network

- **Integration.** RAN integration engineers verify SSB placement, PCI/ARFCN plan and TDD pattern exactly the way
  Section 6 does — with a spectrum capture instead of the T tracer. A wrong SSB position has no gNB-side error: the UE
  just never syncs. Recomputing Example 1 by hand is the daily skill.
- **Load diagnosis.** Occupancy per PRB/symbol is the raw material of capacity work: how full are the UL slots, is the
  mixed slot used, is PUCCH eating symbols. Operators get this from counters (PRB utilisation KPIs); the grid is the
  ground truth those counters are derived from.
- **Interference.** On a live network, occupancy that should not be there (another cell, a jammer, a radar in n78)
  shows up as broadband energy in "empty" slots. The 60 dB threshold method of Section 3.4 is the cheap version of
  that measurement.
- **Random access health.** Msg2/Msg3/Msg4 timings (Section 3.5) are exactly what a RACH KPI investigation looks at:
  preamble detected but no RAR (uplink problem), RAR but no Msg3 (coverage), Msg3 but no Msg4 (contention). The grid
  shows which of the four steps went missing.
- **Spectrum value.** The idle grid is the picture behind Module 1's overhead numbers: SSB every 20 ms, SIB1 after it,
  CSI-RS each SSB slot — all fixed, all paid for before the first data bit.

## 8. Research extension

- **Scheduler studies with ground truth.** Compare scheduled allocations (labels) against measured energy per slot:
  a new scheduler or xApp (Experiment 12) can be audited this way — did the slice really get its PRBs?
- **Occupancy as a cheap spectrum sensor.** The energy-threshold method runs inside the gNB with no extra hardware; an
  O-RAN research question is which KPM/M-series report can carry enough of this picture for a near-RT RIC closed loop.
- **Multi-UE grids.** With two or more UEs (a planned extension), the grid directly shows fairness: who got which PRBs
  in which slot, per RNTI, per TTI.
- **UL ring fix.** The `rxdataF` ring limitation (Section 6.3) is an OAI upstream fix candidate: send the ring entry
  matching the slot instead of entry 0. A good first contribution-sized change, verifiable with this very test.

## 9. Exercises

1. Compute the SSB PRB range of the 51-PRB carrier of Experiment 1 (point A ARFCN 639 996, SSB ARFCN 640 704).
2. Why does PSS occupy only 12 PRB while PBCH occupies all 20?
3. One DL slot of grid data at 106 PRB is 14 symbols x 1536 x 4 bytes = 86 KB. Compute it for 273 PRB and show why the
   T tracer refuses the capture.
4. Convert the measured RA timeline of run 1 (Msg1 slot 847.19, Msg2 848.10, Msg3 848.19, Msg4 849.10) into
   milliseconds after Msg1.
5. Which channel carries the HARQ-ACK of Msg4, and in which slot after Msg4 does it appear? Does random access use
   PUCCH before that?
6. Why does Msg3 use MCS 1 on PRB 0-7 while the connected UE gets MCS 28 on PRB 0-105?
7. Why is the UL grid of this capture only available for slot 8 of each frame (slot % 4 = 0)?
8. In the idle capture, the SSB slot also carries CSI-RS on symbol 13 across all PRBs. What is CSI-RS for, and why
   does the scheduler not avoid it the way it avoids the SSB?
9. A UL slot shows one symbol occupied across the whole carrier and no PUSCH label. Name the two candidate channels
   and say what measurement would separate them.
10. From the UDP DL grid, what is the per-slot TBS at MCS 26-28 on 106 PRB, and how does it build up to the 87.5 Mbit/s
    goodput measured in Module 1?

<details><summary>Answers</summary>

1. Offset $= (640\,704 - 639\,996) \times 15$ kHz $= 10.62$ MHz $= 354$ subcarriers $= 29.5$ PRB — the SSB centre sits
   between two PRBs; the 20-PRB block covers PRB 20-39 (the OAI UE's `--ssb` $= 354 - 120 = 234$ gives the block start
   in half-PRB units: 234/12 $= 19.5$). SSB placement on a narrower carrier needs the GSCN raster rules (Experiment 2).
2. PSS is 127 subcarriers, centred, with 57 reserved subcarriers each side (density 1); PBCH fills the whole 240 to
   carry the master information and its DMRS.
3. $14 \times 6144 \times 4 = 344$ KB — the tracer sends the full FFT buffer (6144 samples per symbol at 273 PRB, the
   FFT size of Module 1), which exceeds the 256 KiB T buffer, and OAI aborts rather than truncate.
4. Msg2 $+5.5$ ms, Msg3 $+10.0$ ms, Msg4 $+15.5$ ms (11, 9, 11 slots x 0.5 ms added to the previous step).
5. PUCCH (HARQ-ACK, format 1 typically); at the earliest the PUCCH resource configured for the UE after Msg4. No:
   random access itself uses PRACH (Msg1) and PUSCH (Msg3) only.
6. The scheduler has no CQI from a UE that has just attached, so it plays safe; Msg3 must decode even if the UE's
   actual SINR is unknown. After the UE reports CQI, link adaptation opens up (Module 0).
7. The tracer's UL grid event always sends ring entry 0 of the 4-slot `rxdataF` ring, so the grid belongs to the
   captured slot only when the slot index modulo the ring depth (4) is 0 — slot 8 in this TDD pattern. An OAI bug
   (Section 8, research extension).
8. CSI-RS lets the UE measure CSI (and RSRP) per configured resource; it is configured with a periodicity and
   occupies little (one symbol), and the scheduler can rate it around: on the idle bench it shares its slot with the
   SSB. The SSB is avoided because a UE must be able to decode it blindly, with no prior knowledge.
9. SRS or a PUCCH the label is missing for (rare labels in rfsim). Separate them: check the gNB config for `do_SRS`
   and the PUCCH resource config, and repeat the capture with the traffic stopped — SRS persists with a configured
   periodicity, PUCCH follows HARQ feedback timing.
10. TBS 9737-10497 bytes (~10 KB) per DL slot. Over ~14 DL-slot-equivalents per 10 ms (7 DL + the mixed slot's DL part,
    twice) that is ~110 Mbit/s of scheduled DL TBs; the measured 87.5 Mbit/s goodput is what remains after the DL/UL
    split, the guard symbols and the SSB/PDCCH/DMRS/CSI-RS overhead (Module 1's ~40 %).

</details>

## 10. References

- 3GPP TS 38.211, clause 7.3/7.4 (PDCCH/PDSCH, SS/PBCH block); clause 5.3 (PRACH).
- 3GPP TS 38.213, clauses 4.8 and 8 (random access procedures and timings).
- 3GPP TS 38.214, clause 5.1 (PDSCH resource allocation, RIV).
- OAI T tracer (`common/utils/T/`, `local_tracer.c`) and the event list the gNB sends on connect (`T_messages.txt`).
- Experiment record: [docs/experiments/EXP-01b-resource-grid.md](../experiments/EXP-01b-resource-grid.md) with the
  raw captures under [docs/experiments/data/](../experiments/data/) (bench-grid-*, bench-grid-ra-*).
