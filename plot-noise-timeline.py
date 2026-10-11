#!/usr/bin/env python3
"""LAB-0: annotated timeline graph from exp-noise-timeline.sh output.

Usage: python3 plot-noise-timeline.py RUN_DIR [OUT.png]
RUN_DIR holds timeline.csv and events.csv. Three stacked panels share the time axis:
CQI and DL MCS, DL MAC goodput, DL BLER. Each preset switch is a dashed line with its label;
the phases are shaded by preset.
"""
import csv
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SHADE = {"off": "#ffffff", "clean": "#e8f3ec", "moderate": "#fdf3df", "poor": "#fbe4e2"}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    run = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else run / "LAB-00-noise-timeline.png"
    rows = list(csv.DictReader(open(run / "timeline.csv")))
    ev = list(csv.DictReader(open(run / "events.csv")))
    t = [float(r["t_s"]) for r in rows]
    col = lambda k: [num(r[k]) for r in rows]
    t_end = max(t) if t else 1

    fig, ax = plt.subplots(3, 1, figsize=(11, 8), sharex=True,
                           gridspec_kw={"height_ratios": [1.3, 1.1, 0.8]})
    ax[0].step(t, col("mcs_dl"), where="post", color="#1f5fa8", lw=1.8, label="DL MCS")
    ax[0].step(t, col("cqi"), where="post", color="#d9822b", lw=1.8, label="CQI")
    ax[0].set_ylabel("index"); ax[0].set_ylim(0, 35); ax[0].legend(loc="lower left", ncol=2, fontsize=9)
    ax[1].plot(t, col("goodput_dl"), color="#2e7d4f", lw=1.8, marker=".", ms=4)
    ax[1].set_ylabel("DL goodput\n(Mbit/s, MAC)"); ax[1].set_ylim(bottom=0)
    ax[2].plot(t, col("bler_dl"), color="#8e3b8a", lw=1.5, marker=".", ms=4)
    ax[2].set_ylabel("DL BLER"); ax[2].set_ylim(bottom=0)
    ax[2].set_xlabel("time since first switch (s)")

    for i, e in enumerate(ev):
        t0 = float(e["t_s"]); t1 = float(ev[i + 1]["t_s"]) if i + 1 < len(ev) else t_end
        for a in ax:
            a.axvspan(t0, t1, color=SHADE.get(e["preset"], "#f0f0f0"), zorder=0)
            if i > 0:
                a.axvline(t0, color="#555", ls="--", lw=1)
        label = f"{e['preset'].capitalize()}\n{float(e['noise_dB']):g} dB"
        ax[0].annotate(label, xy=(t0, 35), xytext=(4, -3), textcoords="offset points",
                       va="top", fontsize=9, fontweight="bold")
        if i > 0:
            ax[2].annotate(f"t = {t0:.0f} s", xy=(t0, 0), xytext=(3, 3), textcoords="offset points",
                           fontsize=8, color="#555")
    for a in ax:
        a.grid(alpha=0.3); a.set_xlim(0, t_end)
    fig.suptitle("LAB-0: DL channel presets switched during a DL speed test (OAI rfsim, n78 40 MHz)",
                 fontsize=12)
    fig.text(0.01, 0.005, "Noise: AWGN on the UE receive path (channelmod model 0), switched through the "
             "dashboard relay. Goodput in simulated time (rfsim ~1.88x real time).", fontsize=8, color="#555")
    fig.tight_layout(rect=(0, 0.02, 1, 0.97))
    fig.savefig(out, dpi=130)
    print("saved", out)


if __name__ == "__main__":
    main()
