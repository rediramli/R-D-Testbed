#!/usr/bin/env python3
"""LAB-0c: MAC goodput and iperf3 rate for the TCP / UDP / TCP phases of lab00c-tcp-udp.sh.
Usage: python3 plot-tcp-udp.py RUN_DIR OUT.png"""
import csv, json, sys
import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
d, outp = sys.argv[1], sys.argv[2]
rows = list(csv.DictReader(open(d + "/timeline.csv"))); ph = list(csv.DictReader(open(d + "/phases.csv")))
t0 = float(ph[0]["start"]) - float(list(csv.DictReader(open(d + "/events.csv")))[0]["t_s"])
fig, ax = plt.subplots(2, 1, figsize=(11, 6.5), sharex=True, gridspec_kw={"height_ratios": [1.3, 1]})
t = [float(r["t_s"]) for r in rows]; g = [float(r["goodput_dl"]) if r["goodput_dl"] else None for r in rows]
ax[0].plot(t, g, color="#2e7d4f", lw=1.8, marker=".", ms=4, label="DL MAC goodput (gNB, simulated time)")
ax[0].axhline(87.5, color="#555", ls=":", lw=1)
ax[0].text(max(t), 89.5, "link at MCS 28: 87.5 (UDP median)", fontsize=8, color="#555", ha="right")
ax[0].set_ylabel("Mbit/s (sim time)"); ax[0].set_ylim(0, 112); ax[0].legend(loc="lower right", fontsize=9)
col = {"tcp": "#1f5fa8", "udp": "#d9822b", "tcp2": "#1f5fa8"}
for p in ph:
    j = json.load(open(d + "/" + p["phase"] + ".json")); s = float(p["start"]) - t0
    xs = [s + i["sum"]["end"] for i in j["intervals"]]; ys = [i["sum"]["bits_per_second"] / 1e6 for i in j["intervals"]]
    ax[1].plot(xs, ys, color=col[p["phase"]], lw=1.6, marker=".", ms=4)
    for a in ax:
        a.axvspan(s, float(p["end"]) - t0, color={"tcp": "#e8eef8", "udp": "#fdf3df", "tcp2": "#e8eef8"}[p["phase"]], zorder=0)
    lab = {"tcp": "TCP (1 flow)", "udp": "UDP, 200 Mbit/s offered", "tcp2": "TCP again"}[p["phase"]]
    if p["phase"] != "udp":
        lab += ", %s retransmissions" % j["end"]["sum_sent"].get("retransmits")
    ax[0].annotate(lab, xy=(s + 1, 0.98), xycoords=("data", "axes fraction"), va="top", fontsize=9, fontweight="bold")
ax[1].set_ylabel("iperf3 at the UE\n(Mbit/s, wall clock)"); ax[1].set_ylim(bottom=0); ax[1].set_xlabel("time (s)")
for a in ax: a.grid(alpha=0.3)
fig.suptitle("LAB-0c on the bench: one TCP flow vs UDP, DL, noise off (OAI rfsim, n78 40 MHz, MCS 28)", fontsize=12)
fig.text(0.01, 0.005, "TCP reaches the link rate for about 6-9 s, then loses packets (retransmissions) and settles near 60-90 Mbit/s wall clock; "
         "UDP holds ~128 Mbit/s wall clock = 87.5 Mbit/s MAC goodput.", fontsize=8, color="#555")
fig.tight_layout(rect=(0, 0.03, 1, 0.96)); fig.savefig(outp, dpi=130); print("saved", outp)
