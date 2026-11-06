# OCUDU gNB JSON metrics -> Prometheus text (Experiment 16, stage S4). Runs as the metrics-relay container of the
# ocudu-cell pod: it subscribes to the gNB remote control on ws://127.0.0.1:8001 (pod loopback, no auth, never exposed)
# and serves the last report as Prometheus text on :9105 (pod IP; a NetworkPolicy lets only Prometheus in).
# Standard library only (minimal WebSocket client), so it runs on the dashboard's python:3.12-alpine image as non-root.
# Rates are in SIMULATED time: the gNB reports every 1000 ms of simulated time and ZMQ is not paced, so
# ocudu_sim_speed_ratio = 1 / (wall seconds between two DU reports) tells how fast the cell runs.
import base64, json, os, socket, struct, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WS_HOST, WS_PORT = "127.0.0.1", int(os.environ.get("WS_PORT", "8001"))
PORT = int(os.environ.get("PORT", "9105"))
CELL = os.environ.get("CELL", "ocudu")
STALE = float(os.environ.get("STALE_SECONDS", "15"))   # the slowest cell seen (0.2x real time) reported every 4.9 s

lock = threading.Lock()
S = {"connected": 0, "reports": 0, "reconnects": 0, "cells": None, "cells_t": 0.0, "app": None, "app_t": 0.0,
     "du_walls": []}


def ws_connect():
    s = socket.create_connection((WS_HOST, WS_PORT), timeout=10)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall(("GET / HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (WS_HOST, WS_PORT, key)).encode())
    head = b""
    while b"\r\n\r\n" not in head:
        c = s.recv(1024)
        if not c:
            raise ConnectionError("closed during handshake")
        head += c
    if b" 101 " not in head.split(b"\r\n", 1)[0]:
        raise ConnectionError("handshake refused: %r" % head[:80])
    return s, head.split(b"\r\n\r\n", 1)[1]


def ws_send(s, opcode, data):
    """Client frames must be masked (RFC 6455 5.3)."""
    mask = os.urandom(4)
    n = len(data)
    hdr = bytes([0x80 | opcode]) + (bytes([0x80 | n]) if n < 126 else
                                     struct.pack("!BH", 0x80 | 126, n) if n < 65536 else struct.pack("!BQ", 0x80 | 127, n))
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


class Reader:
    def __init__(self, s, buf):
        self.s, self.buf = s, buf

    def take(self, n):
        while len(self.buf) < n:
            c = self.s.recv(65536)
            if not c:
                raise ConnectionError("closed")
            self.buf += c
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def message(self):
        """Next complete text message; answers pings, raises on close."""
        parts = []
        while True:
            b0, b1 = self.take(2)
            op, n = b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack("!H", self.take(2))[0]
            elif n == 127:
                n = struct.unpack("!Q", self.take(8))[0]
            data = self.take(n)   # server frames are not masked
            if op == 8:
                raise ConnectionError("server closed")
            if op == 9:
                ws_send(self.s, 0xA, data)
                continue
            if op in (0, 1, 2):
                parts.append(data)
                if b0 & 0x80:
                    return b"".join(parts).decode("utf-8", "replace")


def ingest(d):
    now = time.time()
    with lock:
        if "du" in d:     # one DU report per 1000 ms of simulated time
            S["du_walls"] = (S["du_walls"] + [now])[-6:]
        if "cells" in d:
            S["cells"], S["cells_t"] = d["cells"], now
            S["reports"] += 1
        if "app_resource_usage" in d:
            S["app"], S["app_t"] = d["app_resource_usage"], now


def ws_loop():
    while True:
        try:
            s, rest = ws_connect()
            s.settimeout(STALE * 2)
            ws_send(s, 1, json.dumps({"cmd": "metrics_subscribe"}).encode())
            r = Reader(s, rest)
            with lock:
                S["connected"] = 1
            while True:
                try:
                    d = json.loads(r.message())
                except ValueError:
                    continue
                if isinstance(d, dict) and "cmd" not in d:
                    ingest(d)
        except Exception as e:  # gNB not up yet, restarted, or silent too long: reconnect
            print("relay: %s; reconnecting in 2 s" % e, flush=True)
        with lock:
            S["connected"] = 0
            S["reconnects"] += 1
        time.sleep(2)


UE_GAUGES = [  # (metric, JSON field, scale, help)
    ("ocudu_ue_cqi", "cqi", 1, "Latest wideband CQI reported by the UE."),
    ("ocudu_ue_dl_mcs", "dl_mcs", 1, "DL MCS index chosen by the scheduler."),
    ("ocudu_ue_ul_mcs", "ul_mcs", 1, "UL MCS index chosen by the scheduler."),
    ("ocudu_ue_dl_brate_bps", "dl_brate", 1, "DL MAC bit rate, bit/s of SIMULATED time."),
    ("ocudu_ue_ul_brate_bps", "ul_brate", 1, "UL MAC bit rate, bit/s of SIMULATED time."),
    ("ocudu_ue_dl_nof_ok", "dl_nof_ok", 1, "DL HARQ transmissions acknowledged in the last report (1000 ms simulated)."),
    ("ocudu_ue_dl_nof_nok", "dl_nof_nok", 1, "DL HARQ transmissions not acknowledged in the last report."),
    ("ocudu_ue_ul_nof_ok", "ul_nof_ok", 1, "UL CRC ok in the last report."),
    ("ocudu_ue_ul_nof_nok", "ul_nof_nok", 1, "UL CRC not ok in the last report."),
    ("ocudu_ue_pusch_snr_db", "pusch_snr_db", 1, "PUSCH SNR measured by the gNB, dB (absent while the UE sends no PUSCH)."),
    ("ocudu_ue_pucch_snr_db", "pucch_snr_db", 1, "PUCCH SNR measured by the gNB, dB."),
    ("ocudu_ue_dl_bs_bytes", "dl_bs", 1, "DL buffer status (bytes waiting at the gNB)."),
]


def num(v):
    try:
        x = float(v)
    except (TypeError, ValueError):
        return None
    return None if x != x else x


def metrics():
    now = time.time()
    with lock:
        cells = S["cells"] if now - S["cells_t"] < STALE else None
        app = S["app"] if now - S["app_t"] < STALE else None
        walls, conn, reps, rec, age = list(S["du_walls"]), S["connected"], S["reports"], S["reconnects"], now - S["cells_t"]
    c = 'cell="%s"' % CELL
    out = ["# HELP ocudu_relay_connected 1 while the relay is subscribed to the gNB remote control.",
           "# TYPE ocudu_relay_connected gauge", "ocudu_relay_connected{%s} %d" % (c, conn),
           "# HELP ocudu_relay_reports_total Cell reports received since the relay started.",
           "# TYPE ocudu_relay_reports_total counter", "ocudu_relay_reports_total{%s} %d" % (c, reps),
           "# HELP ocudu_relay_reconnects_total WebSocket reconnects since the relay started.",
           "# TYPE ocudu_relay_reconnects_total counter", "ocudu_relay_reconnects_total{%s} %d" % (c, rec)]
    if S["cells_t"]:
        out += ["# HELP ocudu_relay_report_age_seconds Wall seconds since the last cell report.",
                "# TYPE ocudu_relay_report_age_seconds gauge", "ocudu_relay_report_age_seconds{%s} %.3f" % (c, age)]
    iv = sorted(b - a for a, b in zip(walls, walls[1:]))
    if iv and now - walls[-1] < STALE:
        med = iv[len(iv) // 2]
        out += ["# HELP ocudu_sim_speed_ratio Simulated seconds per wall second (1 / wall interval between DU reports, median of the last 5).",
                "# TYPE ocudu_sim_speed_ratio gauge", "ocudu_sim_speed_ratio{%s} %.4f" % (c, 1 / med if med > 0 else 0)]
    ues = []
    for cell in cells or []:
        pci = cell.get("cell_metrics", {}).get("pci")
        for u in cell.get("ue_list") or []:
            ues.append((pci, u))
    out += ["# HELP ocudu_cell_ues UEs in the last cell report.", "# TYPE ocudu_cell_ues gauge",
            "ocudu_cell_ues{%s} %d" % (c, len(ues))] if cells is not None else []
    for name, field, scale, help_ in UE_GAUGES:
        rows = [(p, u, num(u.get(field))) for p, u in ues]
        # no measurement: null, or -99.9 dB for an SNR (idle UE, no PUSCH/PUCCH in the report)
        rows = [r for r in rows if r[2] is not None and not (field.endswith("_snr_db") and r[2] <= -99)]
        if rows:
            out += ["# HELP %s %s" % (name, help_), "# TYPE %s gauge" % name]
            out += ['%s{%s,pci="%s",rnti="%04x"} %s' % (name, c, p, int(u.get("rnti", 0)), repr(v * scale)) for p, u, v in rows]
    for d in ("dl", "ul"):
        rows = []
        for p, u in ues:
            ok_, nok = num(u.get(d + "_nof_ok")) or 0, num(u.get(d + "_nof_nok")) or 0
            if ok_ + nok:
                rows.append('ocudu_ue_%s_bler{%s,pci="%s",rnti="%04x"} %s' % (d, c, p, int(u.get("rnti", 0)), repr(nok / (ok_ + nok))))
        if rows:
            out += ["# HELP ocudu_ue_%s_bler %s BLER 0-1 of the last report (nok / (ok + nok)); absent without transmissions." % (d, d.upper()),
                    "# TYPE ocudu_ue_%s_bler gauge" % d] + rows
    if app:
        for k, name, scale, help_ in (("cpu_usage_percent", "ocudu_app_cpu_usage_percent", 1, "gNB process CPU, percent of one core."),
                                      ("mem_total_mb", "ocudu_app_mem_bytes", 1048576, "gNB process memory, bytes."),
                                      ("mem_usage_percent", "ocudu_app_mem_usage_percent", 1, "gNB process memory, percent of the host.")):
            v = num(app.get(k))
            if v is not None:
                out += ["# HELP %s %s" % (name, help_), "# TYPE %s gauge" % name, "%s{%s} %s" % (name, c, repr(v * scale))]
    return "\n".join(out) + "\n"


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path != "/metrics":
            self.send_error(404)
            return
        b = metrics().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)


if __name__ == "__main__":
    threading.Thread(target=ws_loop, daemon=True).start()
    print("relay: ws://%s:%d -> :%d/metrics (cell=%s)" % (WS_HOST, WS_PORT, PORT, CELL), flush=True)
    ThreadingHTTPServer(("", PORT), H).serve_forever()
