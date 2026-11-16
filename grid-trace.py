#!/usr/bin/env python3
"""Resource grid snapshots from the OAI gNB T tracer (Experiment 1b, stage G1).

Connects to the gNB's T tracer (127.0.0.1:2021; the gNB runs with --T_stdout 2 --T_nowait), turns on a few events
for a short capture, turns them off again and prints the resource grid of each captured slot:

  GNB_PHY_DL_OUTPUT_SIGNAL   txdataF: the transmitted DL grid of a slot (14 symbols x OFDM size, int16 I/Q)
  GNB_PHY_PUCCH_PUSCH_IQ     rxdataF: the received UL grid; only sent in slots where the gNB expects PUCCH or PUSCH
  GNB_PHY_UL_FD_PUSCH_IQ     labels: RNTI, rb_start, rb_size and symbols of each PUSCH
  GNB_MAC_PUCCH_POWER_CONTROL, GNB_MAC_DL, GNB_MAC_UL, GNB_MAC_DL_RAR_PDU_WITH_DATA, GNB_PHY_MIB   labels per slot
  ENB_PHY_INITIATE_RA_PROCEDURE   PRACH preamble detected (Msg1; the gNB reuses this LTE event name)
  GNB_MAC_DL_PDU_WITH_DATA        a DL MAC PDU per RNTI (Msg4 is the first one to the Msg3 RNTI after the RAR); size only
GNB_MAC_PUCCH_POWER_CONTROL is sent only when the gNB measured the PUCCH SNR (ul_cqi != 0xff); in rfsim that is rare
(1-2 labels per random access on the bench), so PUCCH shows mostly as energy in the UL grid.

The event formats and IDs come from the T_messages.txt the gNB sends on connect, so this works with the image's own
OAI version. Payload bytes of MAC PDUs are never kept or printed (they can hold NAS identities); only sizes and
scheduling values are.

Safety: one event must fit the gNB's T buffer (256 KiB) or the gNB aborts. A DL slot is 14 x OFDM size x 4 bytes:
106 PRB (OFDM 1536) = 86 KB, 273 PRB (OFDM 6144) = 344 KB. The capture refuses carriers above 106 PRB.
The gNB's local tracer queues without limit, so the capture reads continuously, stops after --slots slots of the
radio timeline (20 slots = one 10 ms frame at 30 kHz) or after --timeout seconds, and turns the events off at once.

  python3 grid-trace.py --prb 106 --slots 20 [--json out.json] [--ascii]
  python3 grid-trace.py --ra-wait 90 --slots 40      (start this, then restart the UE: Msg2 RAR onwards)
The PRACH signal itself is not traced (OAI 2026.w40 defines GNB_PHY_PRACH_INPUT_SIGNAL but never sends it); Msg1 is
known from the preamble detection event, and its PRBs from the configuration (msg1-FrequencyStart, FDM).
"""
import argparse
import json
import socket
import struct
import sys
import time

import numpy as np

EVENTS = ["GNB_PHY_DL_OUTPUT_SIGNAL", "GNB_PHY_PUCCH_PUSCH_IQ", "GNB_PHY_UL_FD_PUSCH_IQ",
          "GNB_PHY_MIB", "GNB_MAC_DL", "GNB_MAC_UL", "GNB_MAC_DL_RAR_PDU_WITH_DATA", "GNB_MAC_PUCCH_POWER_CONTROL",
          "GNB_MAC_PUSCH_POWER_CONTROL", "ENB_PHY_INITIATE_RA_PROCEDURE", "GNB_MAC_DL_PDU_WITH_DATA"]
RA_EVENTS = [e for e in EVENTS if e != "GNB_PHY_DL_OUTPUT_SIGNAL"]   # light set while waiting for a random access
MAX_PRB = 106
RX_RING = 4            # RU_RX_SLOT_DEPTH: rxdataF holds 4 slots, but GNB_PHY_PUCCH_PUSCH_IQ always sends ring entry 0,
                       # so the traced UL grid belongs to the slot only when slot % 4 == 0 (an OAI 2026.w40 limitation)          # largest carrier whose DL slot fits T_BUFFER_MAX (see above)
SYMBOLS = 14
FLOOR_DB = -60.0       # grid values below (slot maximum + FLOOR_DB) count as empty


class TClient:
    def __init__(self, host, port, timeout=10):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.buf = bytearray()
        self.timed = None
        self.ids, self.fmt = {}, {}

    def _read(self, n):
        while len(self.buf) < n:
            d = self.s.recv(1 << 20)
            if not d:
                raise ConnectionError("T tracer closed the connection")
            self.buf += d
        out = bytes(self.buf[:n]); del self.buf[:n]
        return out

    def message(self):
        """-> (id, timestamp or None, payload after the id)"""
        size = struct.unpack("<i", self._read(4))[0]
        m = self._read(size)
        if self.timed is None:   # the first message is ID -1 (T_messages.txt); find out whether a timespec comes first
            self.timed = struct.unpack_from("<i", m, 0)[0] != -1
        if self.timed:
            sec, nsec = struct.unpack_from("<qq", m, 0)
            return struct.unpack_from("<i", m, 16)[0], sec + nsec / 1e9, m[20:]
        return struct.unpack_from("<i", m, 0)[0], None, m[4:]

    def handshake(self):
        """Read T_messages.txt (messages -1, ended by -2) and build name -> id and id -> field list."""
        txt = bytearray()
        while True:
            i, _, p = self.message()
            if i == -1:
                n = struct.unpack_from("<i", p, 0)[0]; txt += p[4:4 + n]
            elif i == -2:
                break
        name, n = None, 0
        for line in txt.decode(errors="replace").splitlines():
            line = line.strip()
            if line.startswith("ID ="):
                name = line.split("=", 1)[1].strip(); self.ids[name] = n; n += 1
            elif line.startswith("FORMAT =") and name:
                f = line.split("=", 1)[1].strip()
                self.fmt[self.ids[name]] = [tuple(x.strip().split(",", 1)) for x in f.split(":")] if f else []
        self.n_ids = n
        return hashlib_md5(bytes(txt))

    def set_events(self, names):
        on = {self.ids[x] for x in names}
        flags = [1 if i in on else 0 for i in range(self.n_ids)]
        self.s.sendall(struct.pack("<bi", 1, self.n_ids) + struct.pack("<%di" % self.n_ids, *flags))

    def decode(self, i, p):
        out, o = {}, 0
        for typ, name in self.fmt.get(i, []):
            if typ == "int":
                out[name] = struct.unpack_from("<i", p, o)[0]; o += 4
            elif typ == "float":
                out[name] = struct.unpack_from("<f", p, o)[0]; o += 4
            elif typ == "ulong":
                out[name] = struct.unpack_from("<Q", p, o)[0]; o += 8
            elif typ == "buffer":
                n = struct.unpack_from("<i", p, o)[0]; o += 4
                out[name] = p[o:o + n]; o += n
            elif typ == "string":
                e = p.index(b"\0", o); out[name] = p[o:e].decode(errors="replace"); o = e + 1
            else:
                raise ValueError("unknown T field type %s" % typ)
        return out


def hashlib_md5(b):
    import hashlib
    return hashlib.md5(b).hexdigest()


def grid_db(buf, nrb):
    """int16 I/Q grid (14 symbols x OFDM size) -> PRB x symbol energy in dB (nrb x 14).
    In OAI 2026.w40 both txdataF and the fft-shifted rxdataF hold the carrier contiguously from index 0:
    PRB p is subcarriers 12p..12p+11 (nr_dlsch.c get_block_start_sc, slot_fep_nr.c fftshift_inplace)."""
    iq = np.frombuffer(buf, dtype="<i2").astype(np.float32)
    nfft = iq.size // 2 // SYMBOLS
    if nfft * SYMBOLS * 2 != iq.size:
        raise ValueError("grid of %d samples is not %d symbols" % (iq.size // 2, SYMBOLS))
    p = (iq[0::2] ** 2 + iq[1::2] ** 2).reshape(SYMBOLS, nfft)
    e = p[:, :nrb * 12].reshape(SYMBOLS, nrb, 12).mean(axis=2).T     # nrb x 14
    return 10 * np.log10(e + 1e-3), nfft


def occupied(db):
    """PRB x symbol mask of resource elements carrying energy, relative to the strongest RE of the slot."""
    top = db.max()
    return db > max(top + FLOOR_DB, 0.0) if np.isfinite(top) else np.zeros_like(db, dtype=bool)


def ranges(v):
    """sorted ints -> 'a-b,c' text"""
    out, start, prev = [], None, None
    for x in v:
        if start is None:
            start = prev = x
        elif x == prev + 1:
            prev = x
        else:
            out.append("%d-%d" % (start, prev) if prev > start else str(start)); start = prev = x
    if start is not None:
        out.append("%d-%d" % (start, prev) if prev > start else str(start))
    return ",".join(out) or "-"


def capture(host, port, nrb, nslots, timeout=5.0, ra_wait=0.0):
    if nrb > MAX_PRB:
        raise SystemExit("refused: %d PRB; a DL slot above %d PRB does not fit the gNB T buffer (the gNB would abort)" % (nrb, MAX_PRB))
    t = TClient(host, port)
    md5 = t.handshake()
    missing = [e for e in EVENTS if e not in t.ids]
    if missing:
        raise SystemExit("events not in this OAI version: %s" % ", ".join(missing))
    ev = {v: k for k, v in t.ids.items() if k in EVENTS}
    slots, labels, n_msgs, n_bytes = {}, {}, 0, 0
    order = {}                  # key -> arrival rank, so rows stay in time order across the frame wrap (1023 -> 0)
    t0, first, last = time.time(), {}, {}
    waiting = ra_wait > 0       # random access mode: UL grids and labels only, until the first RAR
    t.set_events(RA_EVENTS if waiting else EVENTS)
    try:
        while time.time() - t0 < (ra_wait + timeout if waiting or ra_wait else timeout) and max([(last[k] - first[k]) % 20480 for k in first] or [0]) < nslots:
            i, ts, p = t.message()
            n_msgs += 1; n_bytes += len(p)
            name = ev.get(i)
            if not name:
                continue
            d = t.decode(i, p)
            key = (d.get("frame"), d.get("slot", d.get("subframe")))
            k3 = ("dl" if name in ("GNB_PHY_DL_OUTPUT_SIGNAL", "GNB_MAC_DL", "GNB_MAC_DL_RAR_PDU_WITH_DATA", "GNB_PHY_MIB",
                                   "GNB_MAC_DL_PDU_WITH_DATA") else "mac-ul" if name == "GNB_MAC_UL" else "ul",) + key
            order.setdefault(k3, len(order))
            if waiting and name in ("ENB_PHY_INITIATE_RA_PROCEDURE", "GNB_MAC_DL_RAR_PDU_WITH_DATA"):
                waiting = False; t.set_events(EVENTS); first, last = {}, {}   # random access seen: DL grids too
            if not waiting and name in ("GNB_PHY_DL_OUTPUT_SIGNAL", "GNB_PHY_PUCCH_PUSCH_IQ"):
                # DL events carry the TX slot, UL events the RX slot (a few slots apart): one timeline each
                k = "dl" if name == "GNB_PHY_DL_OUTPUT_SIGNAL" else "ul"
                a = key[0] * 20 + key[1]                       # 20 slots per frame at 30 kHz; wraps at 1024 frames
                first.setdefault(k, a); last[k] = a
            if name == "GNB_PHY_DL_OUTPUT_SIGNAL" and d.get("antenna", 0) == 0:
                db, nfft = grid_db(d["txdata"], nrb)
                slots[("dl",) + key] = {"dir": "dl", "frame": key[0], "slot": key[1], "nfft": nfft, "db": db}
            elif name == "GNB_PHY_PUCCH_PUSCH_IQ" and key[1] % RX_RING == 0:
                db, nfft = grid_db(d["rxdataF"], nrb)
                slots[("ul",) + key] = {"dir": "ul", "frame": key[0], "slot": key[1], "nfft": nfft, "db": db}
            elif name == "GNB_PHY_UL_FD_PUSCH_IQ":
                labels.setdefault(("ul",) + key, []).append(
                    {"ch": "PUSCH", "rnti": "%04x" % d["rnti"], "rb": [d["rb_start"], d["rb_start"] + d["rb_size"] - 1],
                     "sym": [d["start_symbol_index"], d["start_symbol_index"] + d["nr_of_symbols"] - 1], "mcs": d["mcs_index"]})
            elif name == "GNB_MAC_PUCCH_POWER_CONTROL":
                labels.setdefault(("ul",) + key, []).append({"ch": "PUCCH", "rnti": "%04x" % d["rnti"], "snr_db": d["snrx10"] / 10})
            elif name == "GNB_MAC_DL":
                labels.setdefault(("dl",) + key, []).append({"ch": "PDSCH", "rnti": "%04x" % d["rnti"], "mcs": d["mcs"], "tbs": d["tbs"]})
            elif name == "GNB_MAC_UL":
                labels.setdefault(("mac-ul",) + key, []).append({"ch": "PUSCH-sched", "rnti": "%04x" % d["rnti"], "mcs": d["mcs"], "tbs": d["tbs"]})
            elif name == "GNB_MAC_DL_RAR_PDU_WITH_DATA":
                labels.setdefault(("dl",) + key, []).append({"ch": "RAR", "rnti": "%04x" % d["rnti"], "bytes": len(d["data"])})
            elif name == "ENB_PHY_INITIATE_RA_PROCEDURE":
                labels.setdefault(("ul",) + key, []).append({"ch": "PRACH", "preamble": d["preamble"], "energy_db": d["energy"] / 10, "delay": d["delay"]})
            elif name == "GNB_MAC_DL_PDU_WITH_DATA":
                labels.setdefault(("dl",) + key, []).append({"ch": "DL-PDU", "rnti": "%04x" % d["rnti"], "bytes": len(d["data"])})
            elif name == "GNB_PHY_MIB":
                labels.setdefault(("dl",) + key, []).append({"ch": "SSB/PBCH"})
    finally:
        t.set_events([])
        t.s.close()
    secs = time.time() - t0
    if ra_wait and waiting:
        raise SystemExit("no random access (PRACH or RAR) within %.0f s" % ra_wait)
    return {"md5": md5, "nrb": nrb, "slots": slots, "labels": labels, "order": order, "msgs": n_msgs, "bytes": n_bytes, "secs": secs}


def summary(c):
    """One row per slot with a grid or a label (PRACH and MAC-UL labels can be in slots without a traced grid)."""
    rows = []
    for k in sorted(set(c["slots"]) | set(c["labels"]), key=lambda k: c["order"].get(k, 1 << 30)):
        lab = c["labels"].get(k, [])
        s = c["slots"].get(k)
        if s is None:
            rows.append({"dir": k[0], "frame": k[1], "slot": k[2], "nfft": None, "prbs": "-", "nPrb": 0, "symbols": "-",
                         "maxDb": None, "labels": lab})
            continue
        m = occupied(s["db"])
        prbs = [i for i in range(m.shape[0]) if m[i].any()]
        syms = [j for j in range(m.shape[1]) if m[:, j].any()]
        rows.append({"dir": s["dir"], "frame": s["frame"], "slot": s["slot"], "nfft": s["nfft"],
                     "prbs": ranges(prbs), "nPrb": len(prbs), "symbols": ranges(syms), "maxDb": round(float(s["db"].max()), 1),
                     "labels": lab})
    return rows


def ascii_grid(s, nrb):
    """PRB rows (top = highest PRB) x 14 symbol columns; '#' = occupied."""
    m = occupied(s["db"])
    step = max(1, nrb // 53)
    lines = []
    for r in range(nrb - 1, -1, -step):
        blk = m[max(0, r - step + 1):r + 1]
        lines.append("%4d |%s|" % (r, "".join("#" if blk[:, j].any() else "." for j in range(SYMBOLS))))
    return "\n".join(lines)


def main():
    a = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    a.add_argument("--host", default="127.0.0.1"); a.add_argument("--port", type=int, default=2021)
    a.add_argument("--prb", type=int, default=106); a.add_argument("--slots", type=int, default=20)
    a.add_argument("--timeout", type=float, default=5.0)
    a.add_argument("--ra-wait", type=float, default=0, help="wait up to N s for a random access, then capture --slots")
    a.add_argument("--json"); a.add_argument("--ascii", action="store_true")
    o = a.parse_args()
    c = capture(o.host, o.port, o.prb, o.slots, o.timeout, o.ra_wait)
    rows = summary(c)
    print("T_messages.txt md5 %s; %d messages, %.1f MB in %.2f s; %d DL and %d UL slot grids" % (
        c["md5"], c["msgs"], c["bytes"] / 1e6, c["secs"], sum(k[0] == "dl" for k in c["slots"]), sum(k[0] == "ul" for k in c["slots"])))
    for r in rows:
        print("%-6s %4d.%-2d PRB %-14s (%3d)  symbols %-8s max %5s dB  %s" % (
            r["dir"].upper(), r["frame"], r["slot"], r["prbs"], r["nPrb"], r["symbols"], r["maxDb"],
            "; ".join(" ".join("%s=%s" % kv for kv in l.items()) for l in r["labels"])))
    if o.ascii:
        for k in sorted(c["slots"], key=lambda k: c["order"].get(k, 1 << 30)):
            s = c["slots"][k]
            print("\n%s slot %d.%d (PRB vs symbol 0-13)\n%s" % (s["dir"].upper(), s["frame"], s["slot"], ascii_grid(s, c["nrb"])))
    if o.json:
        out = {"nrb": c["nrb"], "md5": c["md5"], "rows": rows,
               "grids": [{"dir": s["dir"], "frame": s["frame"], "slot": s["slot"],
                          "db": np.round(s["db"].astype(float), 1).tolist()} for s in c["slots"].values()]}
        with open(o.json, "w") as f:
            json.dump(out, f)
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
