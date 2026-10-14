#!/usr/bin/env python3
"""Experiment 0b: curves from infra/exp/exp00b-noise-sweep.sh (curve.csv).
Usage: python3 plot-noise-sweep.py RUN_DIR OUT.png
Left: UE SINR vs the channel-model noise setting, with a 1 dB/dB reference line. Middle: reported CQI vs UE SINR, next to
the typical CQI for that SINR (link-level values, not 3GPP). Right: DL MCS and MAC goodput (UDP above the link rate) vs SINR."""
import csv, sys
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
TYP = [-6.7, -4.7, -2.3, 0.2, 2.4, 4.3, 5.9, 8.1, 10.3, 11.7, 14.1, 16.3, 18.7, 21.0, 22.7]
rows = [r for r in csv.DictReader(open(sys.argv[1] + "/curve.csv")) if float(r["noise"]) > -50]
f = lambda r, k: float(r[k]) if r[k] not in ("", "None") else None
n = [f(r, "noise") for r in rows]; s = [f(r, "sinrUe") for r in rows]
fig, ax = plt.subplots(1, 3, figsize=(14, 4.6))
ax[0].plot(n, s, "o-", color="#1f5fa8", label="measured UE SINR")
ref = [s[0] - (x - n[0]) for x in n]
ax[0].plot(n, ref, "--", color="#999", label="1 dB per dB (AWGN power)")
ax[0].set_xlabel("noise_power_dB setting (channel model 0)"); ax[0].set_ylabel("UE SINR, SSB (dB)")
ax[0].legend(fontsize=8); ax[0].set_title("SINR falls 2 dB per dB of the setting", fontsize=10)
xs = [x / 10 for x in range(-80, 400)]
ax[1].step(xs, [sum(1 for t in TYP if x >= t) for x in xs], where="post", color="#999", ls="--", label="typical CQI (BLER 10 %, link level)")
ax[1].plot(s, [f(r, "cqi") for r in rows], "o", color="#d9822b", label="reported CQI (OAI)")
ax[1].set_xlim(0, 40); ax[1].set_ylim(0, 16); ax[1].set_xlabel("UE SINR (dB)"); ax[1].set_ylabel("CQI")
ax[1].legend(fontsize=8, loc="lower right"); ax[1].set_title("CQI matches above ~18 dB, 1-2 lower below", fontsize=10)
a2 = ax[2]; b2 = a2.twinx()
a2.plot(s, [f(r, "mcsDl") for r in rows], "s-", color="#1f5fa8", label="DL MCS")
b2.plot(s, [f(r, "goodputDl") for r in rows], "o-", color="#2e7d4f", label="MAC goodput")
a2.set_xlabel("UE SINR (dB)"); a2.set_ylabel("DL MCS (64QAM table)", color="#1f5fa8"); b2.set_ylabel("DL MAC goodput (Mbit/s, UDP)", color="#2e7d4f")
a2.set_ylim(0, 30); b2.set_ylim(0, 100); a2.set_title("MCS 28 / 87.5 Mbit/s from ~24 dB", fontsize=10)
for a in ax: a.grid(alpha=0.3)
fig.suptitle("Experiment 0b on the bench: DL noise sweep -20 to -2 dB with UDP above the link rate (OAI rfsim, n78 40 MHz)", fontsize=12)
fig.tight_layout(rect=(0, 0, 1, 0.94)); fig.savefig(sys.argv[2], dpi=130); print("saved", sys.argv[2])
