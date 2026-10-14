# Module 0: Signal quality, link adaptation and what "speed" means

Experiments: 0, 0b and 0c ([record](../experiments/EXP-00-downlink-noise.md)). Testbed: OAI gNB and nrUE in rfsim,
n78, 106 PRB, 30 kHz SCS, TDD, one layer, 64QAM MCS table. All numbers below come from the bench runs of 2026-10-14
unless a line says otherwise.

## 1. Why it matters

A radio channel changes all the time: a user walks behind a building, a neighbour cell gets busy, it rains. A 5G
cell cannot send at one fixed rate; it must choose, every few milliseconds and for every user, how many bits to put
on each resource element. Too many and the user cannot decode them (errors, retransmissions); too few and capacity
is wasted. This choice is **link adaptation**, and it is why the same phone gets 900 Mbit/s near a site and 20 Mbit/s
at the cell edge. This module follows the chain end to end:

```
noise -> SINR -> CQI (UE reports) -> MCS (gNB chooses) -> BLER -> goodput
```

It also separates three numbers that are often confused: what the radio can carry (capacity), what the MAC layer
delivers (goodput), and what one application sees (one TCP flow).

## 2. Learning objectives

After this module a student can:

1. Convert between dB and linear ratios and reason with dB arithmetic.
2. Compute the Shannon capacity of a channel and explain the gap between it and a real system.
3. Read the CQI and MCS tables of TS 38.214 and compute spectral efficiency from modulation order and code rate.
4. Explain how CQI reports and the BLER target drive the gNB's MCS choice (inner and outer loop).
5. Predict the MAC goodput of the testbed from SINR, and check the prediction against a measurement.
6. Explain why one TCP flow can get less than the link capacity, and when to measure with UDP or TCP.

Prerequisites: logarithms, basic probability, the OSI/3GPP layer model (PHY, MAC, RLC, PDCP, IP, TCP/UDP).

## 3. Theory and formulas

### 3.1 Decibels

A ratio of two powers in decibels:

$$x_{\mathrm{dB}} = 10 \log_{10}\frac{P}{P_{\mathrm{ref}}} \qquad\Longleftrightarrow\qquad \frac{P}{P_{\mathrm{ref}}} = 10^{x_{\mathrm{dB}}/10}$$

For amplitudes (voltage, sample values) the factor is 20, because power is proportional to amplitude squared:
$20\log_{10}(A/A_{\mathrm{ref}})$. Rules worth memorising: +3 dB is about x2, +10 dB is x10, +20 dB is x100;
multiplying ratios means adding dB. dBm is power relative to 1 mW (0 dBm = 1 mW, 30 dBm = 1 W).

### 3.2 SINR

The quality of a received signal is the signal power over everything that disturbs it:

$$\gamma = \mathrm{SINR} = \frac{S}{I + N}$$

S is the wanted signal power, I the interference from other transmitters, N the thermal and receiver noise. In the
testbed there is no other cell, so I = 0 and the channel model adds white Gaussian noise (AWGN) of power N.

Even with no added noise the SINR is not infinite: the simulator and the receiver have their own small errors
(quantisation, channel estimation). Model them as a floor $\gamma_0$; noise powers add in linear units, so

$$\frac{1}{\gamma} = \frac{1}{\gamma_0} + \frac{N}{S}$$

This is why the UE SINR stops at about 44-45 dB at `noise_power_dB` = -100 and -20: the floor dominates.

### 3.3 Shannon capacity

The maximum error-free rate over a channel of bandwidth B with AWGN at SINR $\gamma$ is

$$C = B \log_2(1+\gamma) \quad \text{bit/s}, \qquad \eta = \frac{C}{B} = \log_2(1+\gamma) \quad \text{bit/s/Hz}$$

$\eta$ is the spectral efficiency. Shannon is a bound: it needs infinitely long codes and perfect receivers. A real
system with finite block lengths, a fixed set of modulation and coding schemes and a 10 % BLER target needs more SINR
for the same efficiency. A simple and useful model is the **Shannon gap** $\Gamma$:

$$\eta_{\mathrm{real}} \approx \log_2\!\left(1 + \frac{\gamma}{\Gamma}\right)$$

$\Gamma$ (in dB) says how far the system is from Shannon. Section 6 measures it on the testbed.

### 3.4 Modulation, coding and spectral efficiency

Each resource element (RE: one subcarrier for one OFDM symbol) carries one modulation symbol. A symbol of modulation
order $Q_m$ carries $Q_m$ coded bits (QPSK 2, 16QAM 4, 64QAM 6, 256QAM 8). The channel code (LDPC in NR) adds
redundancy: code rate R is information bits over coded bits. Information bits per RE per layer:

$$\eta_{\mathrm{MCS}} = Q_m \cdot R$$

An **MCS** (modulation and coding scheme) index is a row in a table that fixes $Q_m$ and R. The testbed uses MCS index
table 1 for PDSCH (TS 38.214 Table 5.1.3.1-1, 64QAM, indices 0-28). Extract:

| MCS | $Q_m$ | R x 1024 | $\eta$ (bit/RE) | | MCS | $Q_m$ | R x 1024 | $\eta$ (bit/RE) |
|---|---|---|---|---|---|---|---|---|
| 0 | 2 | 120 | 0.2344 | | 17 | 6 | 438 | 2.5664 |
| 4 | 2 | 308 | 0.6016 | | 18 | 6 | 466 | 2.7305 |
| 6 | 2 | 449 | 0.8770 | | 20 | 6 | 567 | 3.3223 |
| 9 | 2 | 679 | 1.3262 | | 24 | 6 | 772 | 4.5234 |
| 10 | 4 | 340 | 1.3281 | | 26 | 6 | 873 | 5.1152 |
| 15 | 4 | 616 | 2.4063 | | 28 | 6 | 948 | 5.5547 |

Check one row: MCS 28 is $6 \times 948/1024 = 5.5547$. Note the change of modulation between MCS 9 and 10: 16QAM at
a low code rate gives almost the same efficiency as QPSK at a high rate.

### 3.5 CQI: the UE's report

The UE measures the channel on reference signals (CSI-RS) and reports a **CQI** index. TS 38.214 clause 5.2.2.1 defines
it as the highest index whose modulation and code rate "could be received with a transport block error probability
not exceeding 0.1" (for CQI table 1). So CQI is not a SINR value; it is the UE's estimate of the best MCS at 10 % BLER.
CQI table 1 (Table 5.2.2.1-2) reuses rows of the MCS table: CQI 15 = 64QAM, R 948/1024 = MCS 28; CQI 9 = 16QAM 616 =
MCS 15; CQI 5 = QPSK 449 = MCS 6. CQI 0 means out of range.

### 3.6 Link adaptation: inner and outer loop

**Inner loop.** The gNB maps the latest CQI to an MCS of about the same efficiency.

**Outer loop (OLLA).** CQI can be biased (the UE is optimistic or pessimistic, the channel changed since the report).
The gNB corrects with an offset $\Delta$ driven by HARQ feedback: after each ACK it raises the offset by
$\delta_{\mathrm{up}}$, after each NACK it lowers it by $\delta_{\mathrm{down}}$. In steady state the expected change
is zero:

$$(1-\mathrm{BLER})\,\delta_{\mathrm{up}} = \mathrm{BLER}\,\delta_{\mathrm{down}} \quad\Rightarrow\quad \mathrm{BLER} = \frac{\delta_{\mathrm{up}}}{\delta_{\mathrm{up}}+\delta_{\mathrm{down}}}$$

For a 10 % target, $\delta_{\mathrm{down}} = 9\,\delta_{\mathrm{up}}$. This is the generic textbook scheme; how OAI
implements it is checked in Experiment 5.

### 3.7 BLER, HARQ and goodput

BLER (block error rate) is the fraction of transport blocks that fail their CRC on the first transmission. HARQ
retransmits them, so they are not lost, but a retransmission uses resources that carry no new data. To first order:

$$\text{goodput} \approx \text{throughput} \times (1 - \mathrm{BLER})$$

**Throughput** counts every bit sent, including retransmissions; **goodput** counts only new data delivered. At
BLER 0 they are equal. Above them sit the application rates: one TCP flow may get less than the MAC goodput (Section 3.10).

### 3.8 From efficiency to bit rate on the testbed

The number of REs per second in the downlink of our carrier:

- subcarriers: $N_{\mathrm{PRB}} \times 12 = 106 \times 12 = 1272$ (38.16 MHz occupied of the 40 MHz channel)
- OFDM symbols per second at numerology $\mu = 1$ (30 kHz): $14 \times 2^{\mu} \times 1000 = 28\,000$
- TDD share of the downlink: the pattern repeats every 5 ms with 7 DL slots, 1 special slot with 6 DL symbols,
  2 UL slots; DL symbols $= 7 \times 14 + 6 = 104$ of 140, so $104/140 = 0.743$

$$\mathrm{RE}_{\mathrm{DL}}/\mathrm{s} = 1272 \times 28\,000 \times 0.743 = 26.5 \times 10^{6}$$

Not every RE carries user data: PDCCH (control), DMRS (demodulation reference), CSI-RS, SSB and other overheads take a
share. With an overhead fraction OH and one layer:

$$\text{goodput} \approx \mathrm{RE}_{\mathrm{DL}}/\mathrm{s} \times (1-\mathrm{OH}) \times \eta_{\mathrm{MCS}} \times (1-\mathrm{BLER}) = k \cdot \eta_{\mathrm{MCS}} \cdot (1-\mathrm{BLER})$$

where $k$ (in mega-RE per second) is a constant of the configuration. Section 6 measures it.

### 3.9 The 3GPP peak-rate formula

TS 38.306 clause 4.1.2 gives the approximate maximum data rate of one carrier:

$$\text{rate} = 10^{-6} \cdot v_{\mathrm{layers}} \cdot Q_m \cdot f \cdot R_{\max} \cdot \frac{N_{\mathrm{PRB}}^{BW,\mu} \cdot 12}{T_s^{\mu}} \cdot (1-OH) \quad \text{Mbit/s}$$

with $R_{\max} = 948/1024$, $T_s^{\mu} = 10^{-3}/(14 \cdot 2^{\mu})$ s (average symbol duration), scaling factor $f$ (1 here)
and OH = 0.14 for FR1 downlink. The formula does not include TDD, so multiply by the DL share. For our carrier
(1 layer, 64QAM, 106 PRB, $\mu = 1$):

$$1 \cdot 6 \cdot 1 \cdot 0.9258 \cdot \frac{1272}{35.71\,\mu\mathrm{s}} \cdot 0.86 = 170.1 \text{ Mbit/s}, \qquad \times 0.743 = 126.4 \text{ Mbit/s (TDD)}$$

### 3.10 TCP vs UDP

**UDP** sends at whatever rate the application chooses, with no feedback. Sent above the link rate, it fills the
gNB's queue and the MAC runs at full capacity; the excess is dropped. That makes UDP the right tool to **measure
capacity**.

**TCP** controls its rate with a congestion window (cwnd): the amount of unacknowledged data in flight. Its rate is
about cwnd / RTT. To fill a link it needs a window of at least the **bandwidth-delay product**:

$$\mathrm{BDP} = \text{rate} \times \mathrm{RTT}$$

for example 87.5 Mbit/s x 20 ms = 219 kB. When a packet is lost, TCP cuts its window (CUBIC by 30 %, Reno by 50 %)
and grows it back slowly. The classic approximation for a loss-limited Reno flow (Mathis et al., 1997):

$$\text{rate} \approx \frac{\mathrm{MSS}}{\mathrm{RTT}} \cdot \frac{1.22}{\sqrt{p}}$$

with MSS the segment size and p the packet loss probability. It shows that a flow with a long RTT and a little loss
stays well below the link rate. Linux uses CUBIC, which recovers faster than Reno, but the trend is the same. TCP is
the right tool to measure **what one application gets**.

## 4. Worked examples

**Example 1: the presets in linear terms.**

| Preset | UE SINR | Linear $\gamma$ | Shannon $\eta = \log_2(1+\gamma)$ |
|---|---|---|---|
| Off | 45.1 dB | 32 359 | 15.0 bit/s/Hz |
| Clean | 22.1 dB | 162 | 7.35 |
| Moderate | 13.8 dB | 24.0 | 4.64 |
| Poor | 6.2 dB | 4.2 | 2.37 |

Off and Poor differ by 39 dB: the noise-free signal is almost 8 000 times cleaner. Yet the Shannon efficiency is
only about 6 times higher, because capacity grows with the logarithm of SINR. Doubling SINR (+3 dB) adds only about
1 bit/s/Hz at high SINR.

**Example 2: predict Moderate from its SINR.** Using the measured gap $\Gamma = 7.3$ dB (factor 5.37) and $k = 15.9$
(both from Section 6):

1. $\gamma = 10^{1.38} = 24.0$; $\gamma/\Gamma = 4.47$
2. $\eta = \log_2(1 + 4.47) = 2.45$ bit/RE
3. The highest MCS with $\eta_{\mathrm{MCS}} \le 2.45$ is MCS 15 ($\eta = 2.4063$)
4. goodput $= 15.9 \times 2.4063 = 38.3$ Mbit/s

Measured: MCS 15 and 38.8 Mbit/s. The same steps give MCS 25 for Clean (measured 26) and MCS 5 for Poor (measured 6):
the simple model is right to within one MCS step.

**Example 3: why the noise setting is not a power in dB.** In Experiment 0b, going from `noise_power_dB` -11 to -3
(8 dB) lowered SINR from 22.5 to 6.4 dB (16 dB). If the setting were a power in dB, N would rise by 8 dB and SINR fall
by 8 dB. A fall of 2 dB per dB is what happens if the setting is used as an amplitude with $10^{x/10}$ instead of
$10^{x/20}$, since power is amplitude squared: $(10^{x/10})^2 = 10^{2x/10}$. This is a hypothesis until the OAI source
is checked; the lesson is to always report results against the **measured** SINR, not the knob.

**Example 4: peak rate vs measured capacity.** The TDD-adjusted 3GPP peak rate is 126.4 Mbit/s; UDP measured 87.5
Mbit/s at MCS 28 with BLER 0 (69 %). The 3GPP formula uses a flat 14 % overhead; the measurement implies more. Section 6
quantifies it.

## 5. Testbed procedure

All scripts run on REDLAB from the repo root as the login user (no sudo); each has a `preview` mode that only checks the
preconditions. Do not use the dashboard controls while a run is going.

| Experiment | Command | Duration | What it does |
|---|---|---|---|
| 0 | `MODE=run bash infra/exp/exp00-noise-timeline.sh` | 3.5 min | DL speed test (TCP), switches Off, Clean, Moderate, Poor, Off every 40 s |
| 0c | `MODE=run bash infra/exp/exp00c-tcp-udp.sh` | 2.5 min | DL TCP 30 s, UDP 200 Mbit/s 30 s, TCP 30 s, noise off |
| 0b | `MODE=run bash infra/exp/exp00b-noise-sweep.sh` | 8 min | UDP 200 Mbit/s, noise -100, -20 ... -2 dB in 1 dB steps of 20 s |

PASS criteria: every step has its samples, one UE context (RNTI) throughout, no out-of-sync sample; for Experiment 0,
the MCS of each phase is inside its expected range. Plots:

```
python3 plot-noise-timeline.py docs/experiments/data/bench-timeline-<time> out.png
python3 plot-tcp-udp.py docs/experiments/data/bench-tcpudp-<time> out.png
python3 plot-noise-sweep.py docs/experiments/data/bench-sweep-<time> out.png
```

Without the bench, use the recorded data: `bench-timeline-20261014T013731Z`, `bench-tcpudp-20261014T025110Z`,
`bench-sweep-20261014T064929Z` in `docs/experiments/data/`.

## 6. Measured results

![SINR sweep](../experiments/img/EXP-00b-noise-sweep.png)

**6.1 The chain works as the theory says.** In the sweep (Experiment 0b) every dB of lost SINR shows up as a lower CQI,
the gNB follows with a lower MCS, and the BLER stays at 0. The link stays up down to 4.3 dB SINR (MCS 4).

**6.2 Goodput is proportional to the MCS efficiency.** Dividing the measured MAC goodput by $\eta_{\mathrm{MCS}}$ gives
the same number at every step:

| SINR (dB) | MCS | $\eta_{\mathrm{MCS}}$ | Goodput (Mbit/s) | $k$ = goodput / $\eta$ | Shannon $\eta$ | Gap $\Gamma$ (dB) |
|---|---|---|---|---|---|---|
| 23.9 | 28 | 5.5547 | 87.5 | 15.75 | 7.95 | 7.3 |
| 22.5 | 26 | 5.1152 | 81.6 | 15.95 | 7.48 | 7.2 |
| 20.1 | 24 | 4.5234 | 72.5 | 16.03 | 6.69 | 6.7 |
| 18.5 | 21 | 3.6094 | 54.5 | 15.10 | 6.17 | 8.0 |
| 16.9 | 20 | 3.3223 | 52.3 | 15.74 | 5.64 | 7.4 |
| 13.9 | 18 | 2.7305 | 43.7 | 16.00 | 4.68 | 6.4 |
| 11.8 | 13 | 1.9141 | 30.4 | 15.88 | 4.01 | 7.4 |
| 10.1 | 11 | 1.4766 | 23.5 | 15.91 | 3.49 | 7.6 |
| 8.7 | 8 | 1.1758 | 18.6 | 15.82 | 3.07 | 7.7 |
| 6.4 | 6 | 0.8770 | 13.9 | 15.85 | 2.42 | 7.2 |
| 4.3 | 4 | 0.6016 | 9.6 | 15.96 | 1.88 | 7.2 |

$k$ has a median of 15.9 M data RE/s (range 15.1-16.0). Compared with the 26.5 M DL RE/s of Section 3.8, about **60 %**
of the downlink REs carry user data and 40 % go to overhead, far more than the 14 % assumed by TS 38.306. Candidate
causes (hypotheses, to be separated in Experiments 1, 3 and 6): PDCCH symbols at the start of each slot, DMRS symbols,
CSI-RS and SSB, the special slot not used for data, and transport block size rounding.

**6.3 The Shannon gap is constant.** The gap column is $\gamma_{\mathrm{dB}} - 10\log_{10}(2^{\eta_{\mathrm{MCS}}} - 1)$:
the SINR measured minus the SINR Shannon would need for that efficiency. It is 7.3 dB (median, range 6.4-8.0) at every
step. So the testbed's link adaptation behaves like "Shannon minus 7 dB", the model used in Example 2.

**6.4 CQI vs typical tables.** Above about 18 dB SINR, OAI's CQI matches typical link-level thresholds; below, it reports
1-2 steps lower (more conservative). Hypothesis: a margin in OAI's CQI selection, or the difference between the SSB SINR
we read and the CSI-RS SINR the UE uses.

**6.5 Capacity vs one TCP flow (Experiment 0c).**

| Phase | MAC goodput median (sim time) | DL MCS | BLER | Notes |
|---|---|---|---|---|
| TCP | 54.6 Mbit/s | 28 | 0 | 1261 retransmissions in 30 s |
| UDP 200 Mbit/s offered | **87.5 Mbit/s** | 28 | 0 | link full, excess dropped |
| TCP again | 49.8 Mbit/s | 28 | 0 | 260 retransmissions |

The radio is the same in all three phases (MCS 28, BLER 0), so the difference is TCP. One TCP flow reaches 87.5 for
6-9 s, then loses packets in a queue on the path and settles at 50-55. From the first phase: about 230 000 segments of
1448 bytes were sent and 1261 retransmitted, so $p \approx 0.55\,\%$. Which queue drops them is still open.

**6.6 Two clocks.** iperf3 measured about 128 Mbit/s (wall clock) in the UDP phase while the MAC delivered 87.5 Mbit/s
in simulated time: rfsim ran about 1.46 times faster than real time. Rates from the gNB counters and rates from
applications are on different clocks; say which one you use.

## 7. From the lab to a live network

- **Link adaptation is everywhere.** Every LTE and NR cell runs the loop of Section 3.6 per user, per few ms.
  Operators tune the BLER target (often 10 %, lower for latency-critical traffic) and the OLLA step sizes; a badly
  tuned loop shows up as high BLER or as MCS that never reaches the top.
- **CQI and MCS distributions are standard cell KPIs.** Network management systems report the share of CQI reports per
  index, the average MCS and the share of 64QAM/256QAM. A cell whose CQI histogram shifts down after a change (a new
  neighbour site, a tilt change) has more interference: the radio planner reads SINR through CQI.
- **Capacity planning uses this module's formula.** Cell capacity is estimated as
  bandwidth x average spectral efficiency x DL share x (1 - overhead); the average spectral efficiency comes from the
  SINR distribution over the coverage area (from drive tests or simulation) mapped through a curve like Section 6.2.
  The Shannon gap and $k$ we measured are the two calibration numbers of such a model.
- **Cell edge vs cell centre.** Shannon's logarithm explains why improving the worst users (cell edge, low SINR) gains
  more capacity per dB than improving the best ones. This drives features such as coordinated scheduling and
  interference management.
- **Speed tests and SLAs.** A single TCP flow under-reports the link (Section 6.5). Public speed-test tools open several
  TCP connections in parallel for this reason. For an enterprise SLA, measure capacity with UDP and user experience
  with TCP, and state which one a number is.
- **Clocks and averaging.** Field KPIs are averages over 15 min or 1 h counters; the dashboard here uses 1 s samples.
  Short windows show transients (like the MCS ramp after a preset switch) that hourly KPIs hide.

## 8. Research extension

The noise sweep (Experiment 0b) is the reference curve for anything that touches link adaptation or scheduling.
Its outputs, the goodput-vs-SINR curve, $k$, the Shannon gap and the BLER per step, form a baseline. Examples:

- **An xApp that adjusts the MCS offset (Experiment 12).** Run the sweep with and without the xApp. A useful xApp
  lowers the gap (more goodput at the same SINR) without raising BLER above the target. Report: gap per step, BLER per
  step, and goodput summed over the sweep.
- **A new channel model (fading, Doppler).** With fading, CQI reports become stale; the OLLA loop matters more. Compare
  the curve under AWGN (this module) with the curve under fading at the same average SINR.
- **A new TCP variant or a queue change (AQM).** Rerun Experiment 0c: the target is a TCP phase close to the UDP
  capacity with fewer retransmissions. The UDP phase must stay unchanged, proving the radio did not change.

Method: one change at a time, three repeats of baseline and change, compare medians with the p10-p90 spread
(see [README](README.md#how-to-use-the-testbed-for-research)).

## 9. Exercises

1. A UE measures SINR 16 dB. Convert to linear and compute the Shannon efficiency.
2. With the testbed gap of 7.3 dB and $k = 15.9$, predict the MCS and goodput at SINR 16 dB. Compare with the 0b row at 16.9 dB.
3. Why does the SINR not go above about 45 dB, even at `noise_power_dB` = -100? Use the formula in Section 3.2.
4. With $\delta_{\mathrm{up}} = 0.01$ dB, what $\delta_{\mathrm{down}}$ gives a 10 % BLER target? A 1 % target?
5. From the TDD pattern, what share of symbols are uplink? Why is the special slot partly guard time?
6. A TCP flow has RTT 30 ms and must fill 87.5 Mbit/s. What window does it need in kB?
7. The UDP phase of Experiment 0c delivered 87.5 Mbit/s (MAC) and iperf3 reported about 128 Mbit/s. Which number would you
   put in a report on cell capacity, and why?
8. Explain in two sentences why QPSK MCS 9 and 16QAM MCS 10 have almost the same efficiency, and why the table still
   switches to 16QAM.

<details><summary>Answers</summary>

1. $10^{1.6} = 39.8$; $\log_2(40.8) = 5.35$ bit/s/Hz.
2. $\gamma/\Gamma = 39.8/5.37 = 7.41$; $\log_2(8.41) = 3.07$; highest MCS with $\eta \le 3.07$ is MCS 19 (3.0293);
   goodput $15.9 \times 3.03 = 48.2$ Mbit/s. At 16.9 dB the testbed used MCS 20 and delivered 52.3: one step above, as
   expected from a model accurate to one step.
3. The floor $\gamma_0$ of the simulator and receiver dominates when N is tiny: $1/\gamma \approx 1/\gamma_0$.
4. $\delta_{\mathrm{down}} = \delta_{\mathrm{up}}(1-T)/T$: 0.09 dB for 10 %, 0.99 dB for 1 %.
5. UL symbols $2 \times 14 + 4 = 32$ of 140 = 22.9 %. The special slot has 6 DL + 4 UL symbols; the remaining 4 are a
   gap so the UE can switch from receive to transmit and so the UL arrives in time despite propagation delay.
6. $87.5 \times 10^6 \times 0.030 / 8 = 328$ kB.
7. 87.5 Mbit/s: it is in simulated time, the time base of the radio. The wall-clock figure is inflated by rfsim
   running faster than real time.
8. $2 \times 679/1024 = 1.326$ and $4 \times 340/1024 = 1.328$. At the same efficiency, the lower code rate of 16QAM gives
   more coding gain, and higher MCS values need the higher-order modulation anyway; the overlap makes the switch smooth.

</details>

## 10. References

- 3GPP TS 38.214, clause 5.1.3.1 (MCS tables) and 5.2.2.1 (CQI definition and tables).
- 3GPP TS 38.306, clause 4.1.2 (approximate maximum data rate).
- 3GPP TS 38.211, clause 4 (frame structure, numerology).
- C. E. Shannon, "A Mathematical Theory of Communication", Bell System Technical Journal, 1948.
- M. Mathis, J. Semke, J. Mahdavi, T. Ott, "The Macroscopic Behavior of the TCP Congestion Avoidance Algorithm",
  ACM SIGCOMM CCR, 1997.
- Experiment record: [EXP-00](../experiments/EXP-00-downlink-noise.md).
