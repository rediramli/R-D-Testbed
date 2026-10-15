#!/usr/bin/env python3
"""Experiment 16 MEC server on the Jetson: object detection (YOLO) over HTTP, with timing of every step.

Runs inside the Ultralytics JetPack 5 container (Python 3.8), started and stopped by infra/exp/exp16-edge-ai.sh:
  python3 edge_server.py --port 8500 --model yolo11n.engine --image bus.jpg
Endpoints (HTTP/1.1, keep-alive):
  GET  /health          {"ok": true, "model": ..., "warm": n}
  GET  /frame?h=720     a 16:9 JPEG test frame of height h (the test image centred on grey), the same bytes every time
  POST /infer           body = JPEG; returns {"n": detections, "cls": {...}, "decode_ms", "pre_ms", "inf_ms", "post_ms",
                        "server_ms", "bytes"}; server_ms runs from the complete request body to the response being built
--model stub skips the AI (fixed 5 ms) so the HTTP path can be tested without a GPU.
Nothing is written to disk.
"""
import argparse, json, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8500)
ap.add_argument("--model", default="yolo11n.engine")
ap.add_argument("--image", default="bus.jpg")
ap.add_argument("--imgsz", type=int, default=640)
a = ap.parse_args()

import numpy as np
import cv2

LOCK = threading.Lock()
FRAMES = {}
SRC = cv2.imread(a.image)
if SRC is None:
    SRC = np.full((1080, 810, 3), 128, np.uint8)


def frame(h):
    if h not in FRAMES:
        w = (h * 16 // 9) // 2 * 2
        img = np.full((h, w, 3), 114, np.uint8)
        sw = SRC.shape[1] * h // SRC.shape[0]
        img[:, (w - sw) // 2:(w - sw) // 2 + sw] = cv2.resize(SRC, (sw, h), interpolation=cv2.INTER_AREA)
        FRAMES[h] = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 85])[1].tobytes()
    return FRAMES[h]


if a.model == "stub":
    def detect(img):
        time.sleep(0.005)
        return 0, {}, {"preprocess": 0.0, "inference": 5.0, "postprocess": 0.0}
else:
    from ultralytics import YOLO
    MODEL = YOLO(a.model, task="detect")

    def detect(img):
        r = MODEL(img, imgsz=a.imgsz, device=0, verbose=False)[0]
        cls = {}
        for c in r.boxes.cls.tolist():
            n = r.names[int(c)]
            cls[n] = cls.get(n, 0) + 1
        return len(r.boxes), cls, r.speed

WARM = 0
for _ in range(10):  # first TensorRT calls are slow; do them before anyone measures
    detect(cv2.imdecode(np.frombuffer(frame(720), np.uint8), cv2.IMREAD_COLOR))
    WARM += 1


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True  # headers and body go out as separate writes; Nagle + delayed ACK would add ~40 ms

    def log_message(self, *args):
        pass

    def reply(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/health":
            self.reply(200, json.dumps({"ok": True, "model": a.model, "warm": WARM}).encode())
        elif u.path == "/frame":
            h = int(parse_qs(u.query).get("h", ["720"])[0])
            if h not in (240, 360, 480, 720, 1080):
                return self.reply(400, b'{"error": "h must be 240, 360, 480, 720 or 1080"}')
            self.reply(200, frame(h), "image/jpeg")
        else:
            self.reply(404, b'{"error": "not found"}')

    def do_POST(self):
        if urlparse(self.path).path != "/infer":
            return self.reply(404, b'{"error": "not found"}')
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        t0 = time.perf_counter()
        img = cv2.imdecode(np.frombuffer(body, np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            return self.reply(400, b'{"error": "not a JPEG"}')
        t1 = time.perf_counter()
        with LOCK:  # one GPU, one inference at a time
            k, cls, sp = detect(img)
        out = {"n": k, "cls": cls, "decode_ms": round((t1 - t0) * 1e3, 3), "pre_ms": round(sp["preprocess"], 3),
               "inf_ms": round(sp["inference"], 3), "post_ms": round(sp["postprocess"], 3), "bytes": n}
        out["server_ms"] = round((time.perf_counter() - t0) * 1e3, 3)
        self.reply(200, json.dumps(out).encode())


print("edge_server: model %s, warm-up %d, port %d" % (a.model, WARM, a.port), flush=True)
ThreadingHTTPServer(("0.0.0.0", a.port), H).serve_forever()
