# Module 1: Carrier bandwidth, the resource grid and capacity

Experiment: 1 (carrier bandwidth and capacity; script `infra/exp/exp01-bandwidth.sh`). Status: **theory and
predictions ready; the measured results are added after the run.** Students should write down their own predictions
(Section 4) before looking at Section 6.

## 1. Why it matters

Spectrum is the most expensive resource an operator has: it is bought from the regulator per MHz, for a region and a
licence period. The first question about any carrier is how much capacity each MHz gives. This module builds the NR
resource grid from first principles, shows how a carrier is described to the UE (NR-ARFCN, point A, SSB position,
bandwidth part), and tests a simple claim: **capacity is proportional to the number of PRBs**. It is almost true, and
the "almost" is the interesting part.

## 2. Learning objectives

After this module a student can:

1. Derive subcarrier spacing, slot length and PRB width from the numerology $\mu$.
2. Find the number of PRBs for a channel bandwidth (TS 38.101-1) and compute the spectrum utilisation.
3. Convert NR-ARFCN to frequency and locate point A, the carrier centre and the SSB.
4. Encode and decode a bandwidth part with the RIV formula.
5. Estimate the peak and the expected rate of a carrier of any width, and explain why small carriers fall short.
6. Relate bandwidth to computing load in a software RAN.

Prerequisite: [Module 0](MOD-00-link-adaptation.md) (spectral efficiency, $k$, UDP for capacity).

## 3. Theory and formulas

### 3.1 Numerology

NR scales one OFDM design by powers of two (TS 38.211 clause 4):

$$\Delta f = 15 \cdot 2^{\mu}\ \text{kHz}, \qquad T_{\mathrm{slot}} = \frac{1\ \text{ms}}{2^{\mu}}, \qquad 14 \text{ symbols per slot (normal CP)}$$

| $\mu$ | $\Delta f$ | Slot | Slots per frame (10 ms) | Typical use |
|---|---|---|---|---|
| 0 | 15 kHz | 1 ms | 10 | FDD below 3 GHz |
| 1 | 30 kHz | 0.5 ms | 20 | n78 TDD (our testbed) |
| 3 | 120 kHz | 0.125 ms | 80 | mmWave (FR2) |

The OFDM symbol lasts $1/\Delta f$ plus a cyclic prefix of about 7 %; wider spacing gives shorter symbols, shorter
slots (lower latency) and more tolerance to Doppler, but a shorter cyclic prefix (less tolerance to delay spread).

### 3.2 The resource grid

A **resource block** (PRB) is 12 consecutive subcarriers: $12 \Delta f$ wide, 360 kHz at 30 kHz. A carrier of
$N_{\mathrm{RB}}$ PRBs occupies $N_{\mathrm{RB}} \cdot 12 \cdot \Delta f$. The rest of the channel bandwidth is guard band,
so the signal fits the emission mask. TS 38.101-1 Table 5.3.2-1 fixes $N_{\mathrm{RB}}$ (30 kHz column):

| Channel bandwidth | $N_{\mathrm{RB}}$ | Occupied | Utilisation |
|---|---|---|---|
| 10 MHz | 24 | 8.64 MHz | 86.4 % |
| 20 MHz | 51 | 18.36 MHz | 91.8 % |
| 40 MHz | 106 | 38.16 MHz | 95.4 % |
| 100 MHz | 273 | 98.28 MHz | 98.3 % |

Wider carriers waste less spectrum on guard bands: the guard is roughly fixed in kHz while the carrier grows.
(LTE used about 90 % at every width; NR's tighter filtering is one of its efficiency gains.)

### 3.3 Where the carrier is: NR-ARFCN, point A, SSB

Frequencies are signalled as NR-ARFCN numbers (TS 38.104 clause 5.4.2.1). From 3 GHz to 24.25 GHz:

$$F = 3000\ \text{MHz} + 15\ \text{kHz} \times (N - 600\,000)$$

- **Point A** (`dl_absoluteFrequencyPointA`) is the lower edge reference of the grid: subcarrier 0 of PRB 0.
- The **carrier centre** is $F_{\mathrm{A}} + N_{\mathrm{RB}} \cdot 6 \cdot \Delta f$ (half the PRBs above point A).
  The OAI UE in rfsim needs it as `-C`.
- The **SSB** (synchronisation signal block, 20 PRB = 240 subcarriers wide, 4 symbols) is what the UE finds first.
  `absoluteFrequencySSB` gives its centre. The OAI UE option `--ssb` is the first SSB subcarrier counted from point A:
  $(F_{\mathrm{SSB}} - F_{\mathrm{A}})/\Delta f - 120$.

### 3.4 Bandwidth part and RIV

A UE does not have to use the whole carrier: it works inside a **bandwidth part** (BWP), a contiguous set of PRBs
(Experiment 6 explores this). The start and length are packed into one number, the resource indication value, with
$N = 275$ (TS 38.331 `locationAndBandwidth`, formula of TS 38.214 clause 5.1.2.2.2), length $L$ and start $S$:

$$\mathrm{RIV} = \begin{cases} N(L-1) + S & \text{if } L-1 \le \lfloor N/2 \rfloor \\ N(N-L+1) + (N-1-S) & \text{otherwise} \end{cases}$$

### 3.5 Rate vs bandwidth

From Module 0, with everything else fixed (MCS, TDD pattern, one layer):

$$\text{goodput} = k(N_{\mathrm{RB}}) \cdot \eta_{\mathrm{MCS}}, \qquad k(N_{\mathrm{RB}}) = N_{\mathrm{RB}} \cdot 12 \cdot 28\,000 \cdot 0.743 \cdot \big(1-\mathrm{OH}(N_{\mathrm{RB}})\big)$$

If the overhead fraction OH were the same at every width, goodput would be exactly proportional to $N_{\mathrm{RB}}$.
But some overheads have a **fixed size**, not a fixed share:

- The SSB is always 20 PRB wide for 4 symbols. In a 24-PRB carrier an SSB symbol leaves only 4 PRBs for data; in a
  273-PRB carrier it leaves 253.
- CORESET0 and the PDCCH have a size set by configuration tables, not by the carrier width.
- System information (SIB1) and paging take a fixed number of bits per period.

So OH falls as the carrier grows: **small carriers should deliver less than their PRB-proportional share**
(hypothesis tested in Experiment 1).

### 3.6 Bandwidth costs computing

In a software RAN every sample is processed by a CPU. The sample rate grows with the bandwidth (the FFT size grows to
cover more subcarriers), FFT work grows as $N \log N$, and channel decoding (LDPC) grows with the bits per second. To
first order, the CPU load of the PHY grows in proportion to the PRBs in use, plus a fixed part. In rfsim, a slower
simulation shows up as a lower ratio of simulated to wall-clock time, not as errors.

## 4. Worked examples and predictions

**Example 1: frequencies of the testbed carrier (106 PRB).**

- Point A: $N = 620\,040$; $F_{\mathrm{A}} = 3000 + 0.015 \times 20\,040 = 3300.60$ MHz
- Centre: $3300.60 + 106 \times 6 \times 0.03 = 3300.60 + 19.08 = 3319.68$ MHz (UE `-C 3319680000`)
- SSB: $N = 621\,312$; $F_{\mathrm{SSB}} = 3319.68$ MHz (the SSB sits at the carrier centre here)
- `--ssb` $= (3319.68 - 3300.60)/0.03 - 120 = 636 - 120 = 516$

**Example 2: RIV.** 106 PRB from PRB 0: $L - 1 = 105 \le 137$, so $\mathrm{RIV} = 275 \times 105 + 0 = 28\,875$ (the value
in `gnb.yaml`). 273 PRB from 0: $L - 1 = 272 > 137$, so $\mathrm{RIV} = 275 \times 3 + 274 = 1099$.

**Example 3: the four carriers of Experiment 1.** Parameters from OAI's own configurations at tag 2026.w40; all derived
values check against the formulas above:

| PRB | Point A | $F_{\mathrm{A}}$ (MHz) | Centre `-C` (MHz) | SSB ARFCN | `--ssb` | RIV |
|---|---|---|---|---|---|---|
| 24 | 640032 | 3600.48 | 3604.80 | 640320 | 24 | 6325 |
| 51 | 639996 | 3599.94 | 3609.12 | 640704 | 234 | 13750 |
| 106 | 620040 | 3300.60 | 3319.68 | 621312 | 516 | 28875 |
| 273 | 626772 | 3401.58 | 3450.72 | 630048 | 1518 | 1099 |

**Example 4: predictions at MCS 28, noise off.** Two references: the 3GPP peak rate (TS 38.306, 1 layer, 64QAM,
x 0.743 for TDD) and the PRB-proportional scaling of the measured 87.5 Mbit/s at 106 PRB.

| PRB | 3GPP peak, TDD (Mbit/s) | PRB-proportional (Mbit/s) | Hypothesis |
|---|---|---|---|
| 24 | 28.6 | 19.8 | below 19.8 (fixed overheads weigh most) |
| 51 | 60.8 | 42.1 | slightly below 42.1 |
| 106 | 126.4 | 87.5 (measured) | reference |
| 273 | 325.5 | 225.4 | close to 225, if the CPU keeps up |

Students: fill in your own prediction column before the run, with a one-line reason.

## 5. Testbed procedure

Run on REDLAB from the repo root as the login user, on branch `exp/01-bandwidth`, with noise off and the dashboard
speed tests stopped.

```
MODE=preview bash infra/exp/exp01-bandwidth.sh
```

PASS criteria of the preview: all preconditions PASS; the running gNB config equals the repo file; for 24 and 51 PRB
the temporary gNB config differs from the repo file in the expected lines and the UE command line gets the new
`-C` and `--ssb`; for 106 PRB the repo files are used unchanged.

```
MODE=run bash infra/exp/exp01-bandwidth.sh
```

For each bandwidth the script reconfigures gNB and UE (about 1 min without a UE each time), waits for registration,
runs 30 s of UDP above the link rate, records MCS, BLER, goodput and the CPU of the gNB and UE processes, and at the
end always restores the 106 PRB configuration. PASS per bandwidth: enough MAC samples, DL MCS 27 or higher, BLER below
0.01. The FINDING lines compare each bandwidth with the PRB-proportional value. 273 PRB runs on its own
(`BWS=273`) because of its CPU load. If anything is left in a wrong state: `MODE=restore bash infra/exp/exp01-bandwidth.sh`.

## 6. Measured results

*To be added after the run: goodput per PRB, $k(N_{\mathrm{RB}})$ and OH per bandwidth, the simulated/wall-clock ratio and
CPU per bandwidth, compared with the predictions in Section 4.*

## 7. From the lab to a live network

- **Spectrum value.** Operators compare offers in MHz, but the network delivers bits. The utilisation table (Section
  3.2) and the fixed-overhead effect (Section 3.5) mean that one 100 MHz carrier gives more than five 20 MHz carriers.
  This is one reason regulators try to award contiguous blocks in mid-band (n78) auctions.
- **Carrier aggregation.** When spectrum is fragmented, NR aggregates carriers; the TS 38.306 formula then sums over
  the component carriers ($J$ in clause 4.1.2). Each carrier keeps its own SSB and control overhead.
- **Site capacity planning.** Capacity per site = sectors x carriers x $k(N_{\mathrm{RB}})$ x average spectral efficiency.
  The $k$ measured per width in this experiment is the calibration number.
- **Configuration errors are common and silent.** A wrong point A or SSB ARFCN means the UE never finds the cell, with
  no error message on the gNB side. Being able to recompute these values by hand, as in Example 3, is a daily skill
  for RAN integration engineers.
- **Cloud RAN sizing.** In a virtualised RAN the CPU cost per MHz decides how many cells one server can host; the CPU
  column of this experiment is a small-scale version of that sizing exercise.

## 8. Research extension

- **A new scheduler or xApp that reallocates PRBs** (for example between slices, Experiment 12): use the per-bandwidth
  $k$ from this experiment to check whether the goodput a slice gets matches the PRBs it is given.
- **A new numerology** (60 kHz) or a different TDD pattern (Experiment 3): repeat the sweep and compare
  $k(N_{\mathrm{RB}})$; the formula in Section 3.5 tells you what should change and by how much.
- **A hardware accelerator for LDPC** or a new PHY implementation: the CPU and simulated/wall-clock columns are the
  baseline; the goodput must not change.

## 9. Exercises

1. What is the slot length and the PRB width at $\mu = 2$?
2. A 60 MHz carrier at 30 kHz has 162 PRB. Compute the occupied bandwidth and the utilisation.
3. Convert NR-ARFCN 640 000 to MHz.
4. Decode RIV 13 750 into start and length.
5. With 24 PRB and the SSB 20 PRB wide, what share of the PRBs is left for data in an SSB symbol? Why does this hurt
   small carriers more?
6. Using the TS 38.306 formula, what is the TDD peak rate of 273 PRB with 2 layers?
7. Why does the script measure capacity with UDP and not with the dashboard's TCP speed test?

<details><summary>Answers</summary>

1. 0.25 ms; $12 \times 60 = 720$ kHz.
2. $162 \times 12 \times 0.03 = 58.32$ MHz; 97.2 %.
3. $3000 + 0.015 \times 40\,000 = 3600.00$ MHz.
4. $13\,750 / 275 = 50$ remainder 0, and $50 \le 137$: $L - 1 = 50$, so $L = 51$, start 0.
5. 4 of 24 PRB (17 %) during the 4 SSB symbols; in a 273-PRB carrier 253 of 273 (93 %). The SSB has a fixed size,
   so its share of the resources is larger in a small carrier.
6. Twice the 1-layer value: $2 \times 325.5 = 651$ Mbit/s.
7. One TCP flow does not fill the link (Module 0, Section 6.5); UDP above the link rate keeps the gNB queue full, so
   the MAC goodput is the capacity of the carrier.

</details>

## 10. References

- 3GPP TS 38.211, clause 4 (numerology, frame structure); clause 7.4.3 (SS/PBCH block).
- 3GPP TS 38.101-1, clause 5.3.2 (maximum transmission bandwidth configuration).
- 3GPP TS 38.104, clause 5.4.2.1 (NR-ARFCN and channel raster).
- 3GPP TS 38.214, clause 5.1.2.2.2 (resource allocation type 1, RIV); TS 38.331 (`locationAndBandwidth`).
- 3GPP TS 38.306, clause 4.1.2 (approximate maximum data rate).
- Experiment record: [docs/experiments/README.md](../experiments/README.md) (Experiment 1).
