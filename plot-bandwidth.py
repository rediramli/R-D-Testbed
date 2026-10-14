#!/usr/bin/env python3
"""Experiment 1 figure: DL MAC goodput vs carrier bandwidth (PRB count), goodput per PRB, and the computing cost
of the rfsim gNB and UE per simulated second.

Usage: python3 plot-bandwidth.py OUT.png RUN_DIR [RUN_DIR ...]
Each RUN_DIR is a docs/experiments/data/bench-bandwidth-<time> folder written by infra/exp/exp01-bandwidth.sh
(results.json). Only saturated measurements are used; a PRB count measured in several runs is shown as the median.
"""
import json, os, statistics as st, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

out, dirs = sys.argv[1], sys.argv[2:]
by = {}
for d in dirs:
    for x in json.load(open(os.path.join(d, "results.json"))):
        if x.get("saturated") and x.get("goodput") and x.get("rx"):
            by.setdefault(x["prb"], []).append(x)
prbs = sorted(by)
med = lambda k, p: st.median(x[k] for x in by[p])
gp = {p: med("goodput", p) for p in prbs}
ratio = {p: st.median(x["rx"] / x["goodput"] for x in by[p]) for p in prbs}       # simulated s per wall-clock s
cpu_g = {p: st.median(x["cpuGnb"] / 100 / (x["rx"] / x["goodput"]) for x in by[p]) for p in prbs}
cpu_u = {p: st.median(x["cpuUe"] / 100 / (x["rx"] / x["goodput"]) for x in by[p]) for p in prbs}
ref = gp[106] / 106
peak = lambda n: 6 * (948 / 1024) * n * 12 / (1e-3 / 28) * 0.86 / 1e6 * 104 / 140      # TS 38.306, 1 layer, TDD share

BLUE, ORANGE, INK, MUTED, GRID = "#2a78d6", "#eb6834", "#0b0b0b", "#52514e", "#e4e3df"
plt.rcParams.update({"font.size": 10, "axes.edgecolor": MUTED, "axes.labelcolor": INK, "xtick.color": MUTED,
                     "ytick.color": MUTED, "axes.spines.top": False, "axes.spines.right": False})
fig, ax = plt.subplots(1, 3, figsize=(15, 4.6), gridspec_kw={"width_ratios": [1.3, 1, 1]})
fig.patch.set_facecolor("#fcfcfb")

a = ax[0]
xs = [0, 280]
a.plot(xs, [peak(x) for x in xs], color=ORANGE, lw=2, label="TS 38.306 peak, TDD (1 layer, 64QAM)")
a.plot(xs, [ref * x for x in xs], color=MUTED, lw=1.5, ls="--", label="PRB-proportional (from 106 PRB)")
a.plot(prbs, [gp[p] for p in prbs], "o", color=BLUE, ms=9, mec="#fcfcfb", mew=2, label="measured MAC goodput (UDP)", zorder=3)
for p in prbs:
    a.annotate("%.1f (%d MHz)" % (gp[p], {24: 10, 51: 20, 106: 40, 273: 100}.get(p, 0)), (p, gp[p]), textcoords="offset points",
               xytext=(-4, 10) if p > 200 else (7, -13), ha="right" if p > 200 else "left", color=INK, fontsize=9)
a.set_xlabel("carrier bandwidth (PRB, 30 kHz SCS)")
a.set_ylabel("DL MAC goodput (Mbit/s, simulated time)")
a.set_xticks(prbs)
a.set_xlim(0, 285); a.set_ylim(0, 340); a.grid(axis="y", color=GRID); a.legend(frameon=False, loc="upper left", fontsize=9)
a.set_title("Capacity at MCS 28, BLER 0", loc="left", fontsize=11, color=INK)

b = ax[1]
lab = [str(p) for p in prbs]
b.bar(lab, [gp[p] / p for p in prbs], color=BLUE, width=0.55)
b.axhline(ref, color=MUTED, ls="--", lw=1.2)
for i, p in enumerate(prbs):
    b.text(i, gp[p] / p - 0.04, "%.3f\n%.0f %%" % (gp[p] / p, 100 * gp[p] / p / ref), ha="center", va="top", fontsize=9.5,
           color="white", fontweight="bold")
b.set_ylim(0, 1.05); b.set_xlabel("PRB"); b.set_ylabel("Mbit/s per PRB"); b.grid(axis="y", color=GRID)
b.set_title("Goodput per PRB (dashed: 106 PRB)", loc="left", fontsize=11, color=INK)

c = ax[2]
w = 0.36
ix = range(len(prbs))
c.bar([i - w / 2 for i in ix], [cpu_g[p] for p in prbs], w, color=BLUE, label="gNB")
c.bar([i + w / 2 for i in ix], [cpu_u[p] for p in prbs], w, color=ORANGE, label="UE")
for i, p in enumerate(prbs):
    c.text(i, max(cpu_g[p], cpu_u[p]) + 0.05, "sim %.2fx\nreal time" % ratio[p], ha="center", va="bottom", fontsize=8.5, color=MUTED)
c.set_xticks(list(ix)); c.set_xticklabels([("%d*" if p == 24 else "%d") % p for p in prbs])
c.set_ylim(0, 3.4); c.set_xlabel("PRB   (* 24 PRB without -E, full sampling)"); c.set_ylabel("CPU cores per simulated second")
c.grid(axis="y", color=GRID); c.legend(frameon=False, loc="upper left", fontsize=9)
c.set_title("Computing cost of the rfsim RAN", loc="left", fontsize=11, color=INK)

fig.suptitle("Experiment 1: carrier bandwidth and capacity (bench, OAI 2026.w40 rfsim, n78 TDD, 1 layer)", x=0.01, ha="left",
             fontsize=12, color=INK)
fig.tight_layout(rect=(0, 0, 1, 0.94))
fig.savefig(out, dpi=110, facecolor=fig.get_facecolor())
for p in prbs:
    print("%3d PRB: %.1f Mbit/s, %.3f per PRB (%.0f %% of proportional, %.0f %% of the 3GPP TDD peak %.1f), "
          "sim/wall %.2f, CPU per sim s gNB %.2f UE %.2f, runs %d"
          % (p, gp[p], gp[p] / p, 100 * gp[p] / p / ref, 100 * gp[p] / peak(p), peak(p), ratio[p], cpu_g[p], cpu_u[p], len(by[p])))
