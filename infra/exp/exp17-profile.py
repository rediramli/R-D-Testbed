#!/usr/bin/env python3
# Experiment 17, stage M1: per-operator coverage profiles (one value per second) from a shipborne scanner drive test
# (R&S TSMA6B, QualiPoc scanner mode, .sqz recording). The profiles drive the bench cells in stage M2.
# The drive-test data belongs to a client project and stays OUTSIDE this public repo: pass its paths as arguments and
# write the output outside the repo too. This script holds no data.
#
# Decoding (no ROMES), as found on the first recording (2026-11-05):
#   .sqz is a ZIP holding a .mf SQLite file; table Message(MessageType, MessageData, TimeStampCreated).
#   MessageData is hex text with a ",<ref>" suffix. TimeStampCreated is an OLE day number (monotonic).
#   GPS: MessageType 1001/1023, plain CSV "lat,lon,...".
#   Per-cell records: MessageType 10951. A record starts where int32-LE is a frequency in Hz (700-3900 MHz) followed by
#   int32 0; RSRP = int16-LE at +8 / 100 dBm; MCC = uint16 at +22, MNC = uint16 at +24. The record holds no SINR or RSRQ.
# Per second and operator: median RSRP per carrier frequency, then the best carrier (max of the medians). Medians
# because single readings have an unreliable strong tail.
# SINR is NOT measured: it is mapped from RSRP with a stated noise-plus-interference floor per resource element
# (--floor, default -105 dBm) and clipped to [--sinr-min, --sinr-max]. Every result built on it must say so.
#
# Usage:  python3 -I infra/exp/exp17-profile.py <file.mf | file.sqz> <out_dir> --ops <MCC-MNC>,<MCC-MNC> [--floor -105]
# Output: <out_dir>/profile_<MCC-MNC>.csv  t_s,lat,lon,rsrp_dbm,sinr_db,band,n_carriers   (empty rsrp = no reading)
#         <out_dir>/profile_summary.json  per operator: coverage, gaps, RSRP percentiles; plus the gate result
import argparse, binascii, bisect, collections, json, os, sqlite3, statistics, struct, sys, tempfile, zipfile

BANDS = [(758, 803, "700"), (791, 862, "800"), (925, 960, "900"), (1805, 1880, "1800"), (2110, 2170, "2100"),
         (2300, 2400, "2300"), (2570, 2690, "2600"), (3300, 3800, "n78")]
GAP_MAX_S = 5          # M1 gate: no gap without a reading longer than this, per operator


def band(mhz):
    return next((n for lo, hi, n in BANDS if lo <= mhz <= hi), "?")


def hexblob(s):
    s = s.decode() if isinstance(s, (bytes, bytearray)) else s
    h = s.split(",")[0]
    return binascii.unhexlify(h[:len(h) & ~1])


def open_mf(path, tmp):
    if path.endswith(".sqz"):
        with zipfile.ZipFile(path) as z:
            name = next(n for n in z.namelist() if n.endswith(".mf"))
            z.extract(name, tmp)
            return os.path.join(tmp, name)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording"); ap.add_argument("out")
    ap.add_argument("--ops", required=True, help="comma-separated PLMNs as MCC-MNC, e.g. the ship's two SIMs: 001-01,001-02")
    ap.add_argument("--floor", type=float, default=-105.0, help="noise + interference per RE, dBm (assumption)")
    ap.add_argument("--sinr-min", type=float, default=-5.0); ap.add_argument("--sinr-max", type=float, default=30.0)
    a = ap.parse_args()
    want = set(a.ops.split(","))      # "MCC-MNC", MNC two digits
    out = os.path.abspath(a.out)
    if os.path.commonpath([out, os.path.abspath(os.path.dirname(__file__) + "/../..")]) == os.path.abspath(os.path.dirname(__file__) + "/../.."):
        sys.exit("refusing to write drive-test profiles inside the repo: choose an output folder outside it")
    os.makedirs(out, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        c = sqlite3.connect(open_mf(a.recording, tmp)).cursor()
        gps = []
        for data, ts in c.execute("SELECT MessageData, TimeStampCreated FROM Message WHERE MessageType IN (1001,1023) ORDER BY TimeStampCreated"):
            f = (data.decode() if isinstance(data, (bytes, bytearray)) else data).split(",")
            try:
                gps.append((ts, float(f[0]), float(f[1])))
            except (ValueError, IndexError):
                pass
        if not gps:
            sys.exit("no GPS fixes in the recording")
        t0 = gps[0][0]; gts = [g[0] for g in gps]

        def where(ts):
            i = min(max(bisect.bisect_left(gts, ts), 1), len(gps) - 1)
            g = min(gps[i - 1], gps[i], key=lambda g: abs(g[0] - ts))
            return g if abs(g[0] - ts) * 86400 <= 2 else None   # nearest fix within 2 s

        # sec -> op -> freq -> [rsrp]
        acc = collections.defaultdict(lambda: collections.defaultdict(lambda: collections.defaultdict(list)))
        pos = {}
        for data, ts in c.execute("SELECT MessageData, TimeStampCreated FROM Message WHERE MessageType=10951"):
            g = where(ts)
            if not g:
                continue
            sec = int(round((ts - t0) * 86400)); pos[sec] = (g[1], g[2])
            try:
                b = hexblob(data)
            except (binascii.Error, ValueError):
                continue
            o = 0
            while o <= len(b) - 26:
                lo, hi = struct.unpack_from("<II", b, o)
                if hi == 0 and 700e6 <= lo <= 3900e6:
                    r = struct.unpack_from("<h", b, o + 8)[0] / 100
                    op = "%03d-%02d" % struct.unpack_from("<HH", b, o + 22)
                    if op in want and -140 <= r <= -30:
                        acc[sec][op][lo / 1e6].append(r)
                    o += 10
                    continue
                o += 1

    last = max(max(pos), int(round((gps[-1][0] - t0) * 86400)))
    summary = {"duration_s": last + 1, "floor_dbm": a.floor, "sinr_clip": [a.sinr_min, a.sinr_max],
               "gap_max_s": GAP_MAX_S, "operators": {}}
    ok = True
    for op in sorted(want):
        rows, vals, gap, gaps, lastpos = [], [], 0, [], None
        for s in range(last + 1):
            lastpos = pos.get(s, lastpos)
            per = acc.get(s, {}).get(op)
            if per:
                med = {f: statistics.median(v) for f, v in per.items()}
                fbest = max(med, key=med.get); r = med[fbest]
                sinr = min(max(r - a.floor, a.sinr_min), a.sinr_max)
                rows.append((s, *(lastpos or ("", "")), f"{r:.1f}", f"{sinr:.1f}", band(fbest), len(med)))
                vals.append(r)
                if gap:
                    gaps.append(gap)
                gap = 0
            else:
                rows.append((s, *(lastpos or ("", "")), "", "", "", 0)); gap += 1
        if gap:
            gaps.append(gap)
        with open(os.path.join(out, f"profile_{op}.csv"), "w") as fh:
            fh.write("t_s,lat,lon,rsrp_dbm,sinr_db,band,n_carriers\n")
            fh.writelines(",".join(map(str, r)) + "\n" for r in rows)
        v = sorted(vals); pct = lambda p: v[min(len(v) - 1, int(p * len(v)))] if v else None
        longest = max(gaps, default=0)
        summary["operators"][op] = {"seconds_with_reading": len(vals), "coverage_pct": round(100 * len(vals) / (last + 1), 1),
                                    "longest_gap_s": longest, "gaps_over_max": sum(g > GAP_MAX_S for g in gaps),
                                    "rsrp_p10": pct(.1), "rsrp_p50": pct(.5), "rsrp_p90": pct(.9)}
        ok &= longest <= GAP_MAX_S and len(vals) > 0
    summary["gate"] = "PASS" if ok else "FAIL"
    json.dump(summary, open(os.path.join(out, "profile_summary.json"), "w"), indent=1)
    for op, s in summary["operators"].items():
        print(f"  {'PASS' if s['longest_gap_s'] <= GAP_MAX_S and s['seconds_with_reading'] else 'FAIL'}  {op}: "
              f"{s['coverage_pct']} % of {last + 1} s with a reading, longest gap {s['longest_gap_s']} s")
    print(f"RESULT: {summary['gate']} (profiles in {out})")


if __name__ == "__main__":
    main()
