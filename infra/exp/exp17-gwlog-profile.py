#!/usr/bin/env python3
# Experiment 17, decision D6: per-SIM coverage profiles from the ship gateway's own log (the vessel's two cellular
# routers, one SIM each), as the stage M2 input. Unlike the M1 scanner profiles, the routers report the SINR and RSRQ
# their modem actually sees on the serving cell, along real voyages.
# The log belongs to a client project and stays OUTSIDE this public repo: pass its path as an argument and write the
# output outside the repo too. This script holds no data.
#
# Input: the gateway's "measurements" table exported as CSV (gzip or plain); columns used:
#   timestamp (ISO), device_id (one router = one SIM), rsrp, sinr, rsrq, network (RAT text), band, lat, lon.
#   The routers report every 10-16 s. A cut-off gzip export is read up to where it ends (with a warning).
# Method:
#   1 s grid per SIM by sample-and-hold, held at most --hold s (default 30); longer = gap (no reading).
#   Sessions = stretches where both SIMs have a reading. Each session is cut into --window s replay windows.
#   Two rankings of the windows, --top of each written as profiles:
#     joint: share of seconds where BOTH SIMs are below --bad dB SINR (a joint outage: what multilink must survive);
#     swap:  number of times the better SIM changes (SINR lead of 3 dB or more, hysteresis) while the other one is
#            below --bad, so staying on the wrong SIM costs: what steering must track.
#   A window where one SIM is bad all hour and the other fine is easy to steer; swap finds the ones that are not.
#
# Usage:  python3 -I infra/exp/exp17-gwlog-profile.py <measurements.csv[.gz]> <out_dir> --links <dev_a>,<dev_b>
#           [--window 3600] [--top 3] [--bad 0] [--hold 30]
# Output: <out_dir>/<joint|swap><k>_<dev>.csv  t_s,lat,lon,rsrp_dbm,sinr_db,rsrq_db,rat   (empty = no reading)
#         <out_dir>/gwlog_summary.json  per SIM distributions, windows ranked, gate result
import argparse, csv, datetime, gzip, json, os, sys, zlib

GATE_MIN_WINDOWS = 1     # D6 gate: at least one full window with both SIMs, and it must hold stress (joint outage > 0)


def rows(path):
    fh = gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")
    csv.field_size_limit(1 << 30)
    try:
        yield from csv.DictReader(fh)
    except (EOFError, zlib.error, OSError) as e:
        print(f"WARNING: input ends early ({e}); using the rows read so far", file=sys.stderr)


def num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def pct(v, q):
    v = sorted(v)
    return v[int(q * (len(v) - 1))] if v else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log"); ap.add_argument("out")
    ap.add_argument("--links", required=True, help="the two device_id values, one per SIM")
    ap.add_argument("--window", type=int, default=3600); ap.add_argument("--top", type=int, default=3)
    ap.add_argument("--bad", type=float, default=0.0, help="SINR below this (dB) counts as a bad second")
    ap.add_argument("--hold", type=int, default=30, help="max seconds a reading is held on the 1 s grid")
    a = ap.parse_args()
    links = a.links.split(",")
    repo = os.path.abspath(os.path.dirname(__file__) + "/../..")
    out = os.path.abspath(a.out)
    if os.path.commonpath([out, repo]) == repo:
        sys.exit("refusing to write gateway-log profiles inside the repo: choose an output folder outside it")
    os.makedirs(out, exist_ok=True)

    samples = {d: [] for d in links}       # (epoch_s, rsrp, sinr, rsrq, rat, lat, lon)
    for r in rows(a.log):
        d = r.get("device_id")
        if d not in samples or num(r.get("sinr")) is None:
            continue
        t = int(datetime.datetime.fromisoformat(r["timestamp"][:19]).timestamp())
        samples[d].append((t, num(r["rsrp"]), num(r["sinr"]), num(r["rsrq"]), r.get("network", ""),
                           num(r.get("lat")), num(r.get("lon"))))
    for d in links:
        samples[d].sort()
        if not samples[d]:
            sys.exit(f"no readings for {d}")

    # 1 s grid, sample-and-hold
    t0 = min(s[0][0] for s in samples.values()); t1 = max(s[-1][0] for s in samples.values())
    grid = {}
    for d, s in samples.items():
        g = [None] * (t1 - t0 + 1)
        for k, x in enumerate(s):
            end = min(x[0] + a.hold, s[k + 1][0] if k + 1 < len(s) else x[0] + a.hold, t1 + 1)
            for t in range(x[0], end):
                g[t - t0] = x
        grid[d] = g
    ga, gb = grid[links[0]], grid[links[1]]

    # sessions where both SIMs have a reading, cut into windows
    wins, start = [], None
    for i in range(len(ga) + 1):
        both = i < len(ga) and ga[i] is not None and gb[i] is not None
        if both and start is None:
            start = i
        elif not both and start is not None:
            wins += [(w, w + a.window) for w in range(start, i - a.window + 1, a.window)]
            start = None
    scored = []
    for w0, w1 in wins:
        bad_a = [ga[i][2] < a.bad for i in range(w0, w1)]; bad_b = [gb[i][2] < a.bad for i in range(w0, w1)]
        joint = sum(x and y for x, y in zip(bad_a, bad_b)) / a.window
        either = sum(x or y for x, y in zip(bad_a, bad_b)) / a.window
        lead, swaps = 0, 0
        for i in range(w0, w1):
            diff = ga[i][2] - gb[i][2]
            now = 1 if diff >= 3 else -1 if diff <= -3 else lead
            swaps += lead != 0 and now != lead and min(ga[i][2], gb[i][2]) < a.bad; lead = now
        scored.append((joint, either, swaps, w0, w1))
    scored.sort(reverse=True)
    picks = [("joint", w) for w in scored[:a.top]] + \
            [("swap", w) for w in sorted(scored, key=lambda w: (w[2], w[0]), reverse=True)[:a.top]]

    summary = {"span": [datetime.datetime.fromtimestamp(t0).isoformat(), datetime.datetime.fromtimestamp(t1).isoformat()],
               "window_s": a.window, "bad_sinr_db": a.bad, "hold_s": a.hold, "full_windows": len(wins), "sims": {}, "top": []}
    for d, s in samples.items():
        sinr = [x[2] for x in s]; rsrp = [x[1] for x in s if x[1] is not None]
        summary["sims"][d] = {"readings": len(s), "sinr_p10_p50_p90": [pct(sinr, q) for q in (.1, .5, .9)],
                              "rsrp_p10_p50_p90": [pct(rsrp, q) for q in (.1, .5, .9)],
                              "sinr_below_bad_pct": round(100 * sum(v < a.bad for v in sinr) / len(sinr), 1)}
    for n, (kind, (joint, either, swaps, w0, w1)) in enumerate(picks):
        k = n % a.top + 1
        for d in links:
            with open(os.path.join(out, f"{kind}{k}_{d}.csv"), "w") as fh:
                fh.write("t_s,lat,lon,rsrp_dbm,sinr_db,rsrq_db,rat\n")
                for i in range(w0, w1):
                    x = grid[d][i]
                    fh.write(",".join("" if v is None else str(v) for v in (i - w0, x[5], x[6], x[1], x[2], x[3], x[4])) + "\n")
        summary["top"].append({"win": f"{kind}{k}", "start": datetime.datetime.fromtimestamp(t0 + w0).isoformat(),
                               "joint_bad_pct": round(100 * joint, 1), "either_bad_pct": round(100 * either, 1),
                               "swaps": swaps})
    ok = len(wins) >= GATE_MIN_WINDOWS and bool(scored) and scored[0][0] > 0
    summary["gate"] = "PASS" if ok else "FAIL"
    json.dump(summary, open(os.path.join(out, "gwlog_summary.json"), "w"), indent=1)
    for d, s in summary["sims"].items():
        print(f"  {d}: {s['readings']} readings, SINR p10/p50/p90 {s['sinr_p10_p50_p90']} dB, "
              f"{s['sinr_below_bad_pct']} % below {a.bad} dB")
    print(f"  {len(wins)} full {a.window} s windows with both SIMs")
    for w in summary["top"]:
        print(f"  {w['win']:7} {w['start']}: both bad {w['joint_bad_pct']} %, either bad {w['either_bad_pct']} %, "
              f"{w['swaps']} swaps of the better SIM")
    print(f"RESULT: {summary['gate']} (profiles in {out})")


if __name__ == "__main__":
    main()
