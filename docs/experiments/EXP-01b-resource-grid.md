# Experiment 1b: The resource grid, live (which PRBs and symbols are occupied)

Status: **stage G1 done** 2026-11-03 on the bench (branch `exp/01b-resource-grid`): the gNB's own T tracer shows the
resource grid per slot. Next: G2 (relay and API), G3 (dashboard page), G4 (training material). RF simulator mode only;
nothing is transmitted. Requested by Prof. Pei: see a UE attach and which PRBs it occupies, including during random access.
Background: [Module 1](../training/MOD-01-bandwidth.md), Section 3.2 (the resource grid).

## Summary (G1)
| Question | Answer |
|---|---|
| Can the bench show which PRBs and symbols are occupied, per slot? | Yes, from the signal itself: the gNB's transmitted DL grid (`txdataF`) and received UL grid (`rxdataF`) through the OAI T tracer, with the scheduler's labels (RNTI, PRB range, symbols, MCS) |
| Does the grid match theory? | SSB/PBCH at PRB 43-62, symbols 8-11, exactly as predicted from the SSB and point A ARFCNs; PDSCH fills PRB 0-105 under UDP DL; every PUSCH label matches the received energy (4 of 4) |
| Is random access visible? | Yes, Msg1 to Msg4 in order, twice: PRACH preamble, RAR 5.5 ms later, Msg3 PUSCH on PRB 0-7 (MCS 1) with the TC-RNTI, Msg4 to the same RNTI (225 bytes) |
| What does it cost? | 2 GiB of RAM while the tracer is on (T cache); captures are short (20-80 slots) and read in about 0.03 s |
| Limits found | UL grid only for slots with slot % 4 = 0 (an OAI event limitation); no PRACH signal event; PUCCH labels rare in rfsim; captures refused above 106 PRB |

## Method
`grid-trace.py` connects to the T tracer of the gNB (port 2021, gNB option `--T_stdout 2 --T_nowait`; the normal log
output stays). It reads the event formats from the `T_messages.txt` the gNB sends on connect, turns on a few events for
a short capture, and turns them off again. Per slot it computes the mean energy of the 12 subcarriers of each PRB in
each of the 14 symbols (dB) and marks a PRB/symbol as occupied when it is within 60 dB of the strongest one.

| Event | Gives |
|---|---|
| `GNB_PHY_DL_OUTPUT_SIGNAL` | transmitted DL grid of a slot, 14 x 1536 I/Q at 106 PRB (86 KB) |
| `GNB_PHY_PUCCH_PUSCH_IQ` | received UL grid; only in slots where the gNB expects PUCCH or PUSCH |
| `GNB_PHY_UL_FD_PUSCH_IQ` | PUSCH label: RNTI, `rb_start`, `rb_size`, symbols, MCS |
| `GNB_MAC_DL`, `GNB_MAC_UL`, `GNB_MAC_DL_PDU_WITH_DATA` | PDSCH and PUSCH scheduling per RNTI (MCS, TBS, bytes) |
| `ENB_PHY_INITIATE_RA_PROCEDURE`, `GNB_MAC_DL_RAR_PDU_WITH_DATA` | Msg1 (preamble detected) and Msg2 (RAR) |
| `GNB_PHY_MIB` | SSB/PBCH slot |

No MAC payload is kept or printed (it can hold NAS identities); only sizes and scheduling values.

`infra/exp/exp01b-grid.sh` runs the stage on REDLAB, one mode at a time:
`MODE=on` (firewall, boot unit, gNB with T, UE restart), `MODE=check` (idle cell, UDP DL, UDP UL), `MODE=ra` (UE restart
with the capture armed), `MODE=off` (gNB without T, firewall and boot unit removed).

## Results (2026-11-03, 106 PRB, TDD 7 DL / 1 mixed (6 DL + 4 UL symbols) / 2 UL slots, noise off)
Data: [bench-grid-20261103T064844Z](data/bench-grid-20261103T064844Z) (one `MODE=check` run on its own: idle, UDP DL,
UDP UL), [bench-grid-ra-20261103T063206Z](data/bench-grid-ra-20261103T063206Z) (random access).

| Case | What the grid shows |
|---|---|
| Idle cell | SSB in slot 0 every 20 ms on PRB 43-62, symbols 8-11 (table below); CSI-RS across PRB 0-105 on symbol 13, 11 dB weaker. Slot 1: PDCCH (symbol 0) and SIB1 PDSCH (symbols 2-11) on PRB 29-68. Most DL slots empty |
| UDP DL | PDSCH on PRB 0-105, symbols 0-13 in DL slots, symbols 0-5 in the mixed slot; MCS 26-28, TBS 9737-10497 bytes per slot |
| UDP UL | PUSCH on PRB 0-105, symbols 0-12 in UL slot 8, matching the label `rb=[0,105] sym=[0,12]`; symbol 13 left for PUCCH/SRS |
| UL slot without PUSCH | one symbol (13) occupied across the carrier (hypothesis: SRS) |

The SSB as the grid shows it (slot 144.0, idle), the textbook structure of TS 38.211 Section 7.4.3.1:

| Symbol | PRB | Content |
|---|---|---|
| 8 | 47-58 (12 PRB) | PSS (127 subcarriers) |
| 9 | 43-62 (20 PRB) | PBCH |
| 10 | 43-62 | SSS on the middle 12 PRB, PBCH on the edges (edges 6 dB weaker) |
| 11 | 43-62 (20 PRB) | PBCH |
| 13 | 0-105 | CSI-RS (`do_CSIRS: 1` on the bench), not part of the SSB |

Random access (UE restart; two runs, the same pattern):

| Step | Run 1 | Run 2 | Channel |
|---|---|---|---|
| Msg1 | 847.19, preamble 30 | 541.19, preamble 1 | PRACH (UL) |
| Msg2 | 848.10 (+5.5 ms) | 542.10 (+5.5 ms) | PDSCH with the RAR, RA-RNTI |
| Msg3 | 848.19, PRB 0-7, MCS 1 | 542.19, PRB 0-7, MCS 1 | PUSCH with the TC-RNTI (b7f4, dc7a) |
| Msg4 | 849.10, 225 bytes | 543.10, 225 bytes | PDSCH to the same RNTI (contention resolution) |

For the class: random access does **not** use PUCCH. Msg1 is PRACH, Msg3 is PUSCH; PUCCH first carries the HARQ-ACK for
Msg4, and later SR and CSI once the UE is connected.

## Findings
1. **OAI 2026.w40 grid layout.** Both `txdataF` and the fft-shifted `rxdataF` hold the carrier contiguously from index 0:
   PRB p is subcarriers 12p to 12p+11 (`nr_dlsch.c` `get_block_start_sc`, `slot_fep_nr.c` `fftshift_inplace`). A first
   version assumed the DC-centred layout (offset 900 at 1536) and put the 22-PRB guard band in the middle of the carrier.
2. **UL grid event limitation.** `rxdataF` is a ring of 4 slots (`RU_RX_SLOT_DEPTH`), but `GNB_PHY_PUCCH_PUSCH_IQ` always
   sends ring entry 0. The traced UL grid belongs to the slot only when slot % 4 = 0, which is slot 8 of each frame in
   this TDD pattern. Labels are kept for every slot.
3. **Msg1 without a signal.** `GNB_PHY_PRACH_INPUT_SIGNAL` is defined but never sent; the preamble detection event
   (`ENB_PHY_INITIATE_RA_PROCEDURE`) gives the slot and preamble. Its PRBs follow from `msg1-FrequencyStart` and FDM.
4. **PUCCH labels are rare in rfsim:** `GNB_MAC_PUCCH_POWER_CONTROL` is sent only with a measured PUCCH SNR (1-2 labels
   per random access here).
5. **T buffer limit.** One event must fit 256 KiB or the gNB aborts. A DL slot at 273 PRB is 344 KB, so captures are
   refused above 106 PRB.
6. **Security.** The tracer always binds 0.0.0.0 and the gNB uses the host network. On 2026-10-28 REDLAB rebooted with
   the T options in the Deployment and without the iptables rules: port 2021 was open on the bench LAN, campus WiFi and
   Tailscale until 2026-11-03 (found and closed then; no client was connected at that moment). Since then `MODE=on`
   installs a boot unit that restores the rules before k3s, and every mode fails if T is on without the rules.
7. **Check per symbol.** The first SSB check took the PRBs occupied in any symbol of the SSB slot; CSI-RS on symbol 13
   (or PDSCH in the same slot) made that the whole carrier. The check now looks for a symbol whose occupied PRBs are
   exactly the predicted block (symbols 9-11 here).
8. **One client only.** The tracer accepts one client at a time; three modes run in parallel failed with
   `Connection refused` and restarted the UE under each other. Run one mode at a time.

## Open (G2-G4)
- G2: a relay on REDLAB that owns the single tracer connection and serves snapshots and a random-access capture to the
  dashboard (no sudo for captures; the firewall stays).
- G3: dashboard page: DL and UL grid per slot (PRB x symbol), slot player, labels SSB/PDCCH/PDSCH/PRACH/PUSCH/PUCCH.
- G4: training module and exercises (SSB position from the ARFCNs, RA timeline, PDSCH vs MCS).
- Verify the SRS hypothesis for UL symbol 13 from the gNB configuration.
- One capture (run 063157Z) had a `GNB_PHY_MIB` label in slot 656.0 whose grid held only CSI-RS; the SSB was in 658.0.
  Find out whether the MIB event and the DL grid can refer to different slots.
