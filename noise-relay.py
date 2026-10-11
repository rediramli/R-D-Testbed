#!/usr/bin/env python3
"""Noise relay for the FCT dashboard (noise presets, stage B).

Runs on the RAN host (FCT0173) with host networking, next to the baseline UE.
It is the only way the dashboard can change the downlink noise, and it can do
exactly one thing: set the UE channel model (model 0, AWGN) to one of four
fixed presets through the OAI telnet server on 127.0.0.1:9090.

  GET  /healthz          -> "ok"
  GET  /noise            -> {"preset": ..., "noiseDb": ..., "ageS": ..., "presets": {...}}   (no token needed)
                            answered from memory; a background thread re-reads the UE every 5 s
  POST /noise            -> body {"preset": "off|clean|moderate|poor"}, header X-Relay-Token

No other input reaches the telnet server: the command text is built only from
the PRESETS table below. The token is read from a file (a Kubernetes Secret)
and compared in constant time. rfsim only; there is no radio here.
"""
import hmac
import json
import os
import re
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BIND = os.environ.get("RELAY_BIND", "10.0.129.7")
PORT = int(os.environ.get("RELAY_PORT", "8092"))
TOKEN_FILE = os.environ.get("RELAY_TOKEN_FILE", "/etc/noise-relay/token")
TELNET = ("127.0.0.1", 9090)
# Measured 2026-10-09/10 (README, "Downlink noise presets"): noise_power_dB of model 0.
PRESETS = {"off": -100.0, "clean": -11.0, "moderate": -6.5, "poor": -3.0}
MAX_BODY = 256
REFRESH_S = 5
LOCK = threading.Lock()                      # one telnet session at a time
CACHE = {"state": None, "error": "not read yet", "t": 0.0}
NOISE_RE = re.compile(r"model 0 rfsimu_channel_enB0 type AWGN:.*?noise:\s*(-?[\d.]+)", re.S)


def telnet(*commands):
    """Run the commands one after the other in ONE OAI telnet session and return
    everything printed after the last one. Earlier commands get at most 0.5 s for
    their reply; the last one is read until the channel-model report (NOISE_RE)
    has arrived and the server is quiet for 0.2 s, at most 4 s. A request takes
    about 1 s instead of fixed sleeps."""
    with socket.create_connection(TELNET, 3) as s:
        s.settimeout(0.2)

        def read(max_s, want_report):
            out, end = b"", time.time() + max_s
            while time.time() < end:
                try:
                    d = s.recv(65536)
                except socket.timeout:
                    if not want_report and out:
                        break              # some reply and then quiet: next command
                    if want_report and NOISE_RE.search(out.decode(errors="replace")):
                        break              # report complete and the server is quiet
                    continue
                if not d:
                    break
                out += d
            return out.decode(errors="replace")

        read(0.5, False)                   # banner / prompt, if any
        out = ""
        for i, c in enumerate(commands):
            s.sendall((c + "\n").encode())
            last = i == len(commands) - 1
            out = read(4.0 if last else 0.5, last)
        return out


def parse_noise(text):
    m = NOISE_RE.search(text)
    if not m:
        raise RuntimeError("channel model 0 (AWGN) not reported by the UE")
    return float(m.group(1))


def read_noise():
    return parse_noise(telnet("channelmod show current"))


def remember(noise):
    preset = next((k for k, v in PRESETS.items() if abs(v - noise) < 0.01), "custom")
    st = {"preset": preset, "noiseDb": noise, "presets": PRESETS}
    CACHE.update(state=st, error=None, t=time.time())
    return st


def state():
    """Read the UE now (caller holds LOCK) and remember the answer."""
    try:
        return remember(read_noise())
    except (OSError, RuntimeError) as e:
        CACHE.update(state=None, error=str(e), t=time.time())
        raise


def refresher():
    """Keep the cached state fresh, so GET /noise answers at once without touching the UE."""
    while True:
        try:
            with LOCK:
                state()
        except (OSError, RuntimeError):
            pass
        time.sleep(REFRESH_S)


def token_ok(given):
    try:
        with open(TOKEN_FILE) as f:
            want = f.read().strip()
    except OSError:
        return False
    return bool(given) and bool(want) and hmac.compare_digest(given.encode(), want.encode())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):  # quiet access log; actions are logged below
        pass

    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            return self.send(200, "ok")
        if self.path != "/noise":
            return self.send(404, {"error": "not found"})
        st, err, t = CACHE["state"], CACHE["error"], CACHE["t"]
        if st is None:
            return self.send(503, {"error": f"UE telnet not available: {err}"})
        return self.send(200, {**st, "ageS": round(time.time() - t, 1)})

    def do_POST(self):
        if self.path != "/noise":
            return self.send(404, {"error": "not found"})
        if not token_ok(self.headers.get("X-Relay-Token", "")):
            print(time.strftime("%FT%TZ", time.gmtime()), "REFUSED bad token from", self.client_address[0], flush=True)
            return self.send(401, {"error": "bad token"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            n = -1
        if n < 0 or n > MAX_BODY:
            return self.send(400, {"error": "body too large or invalid length"})
        try:
            preset = json.loads(self.rfile.read(n) or b"{}").get("preset")
        except (ValueError, AttributeError):
            return self.send(400, {"error": "body must be JSON {\"preset\": ...}"})
        if not isinstance(preset, str) or preset not in PRESETS:
            return self.send(400, {"error": "unknown preset", "allowed": sorted(PRESETS)})
        value = PRESETS[preset]
        try:
            with LOCK:
                out = telnet(f"channelmod modify 0 noise_power_dB {value:g}", "channelmod show current")
                st = remember(parse_noise(out))
        except (OSError, RuntimeError) as e:
            return self.send(503, {"error": f"UE telnet not available: {e}"})
        if abs(st["noiseDb"] - value) >= 0.01:
            return self.send(500, {"error": "noise not applied", "state": st})
        print(time.strftime("%FT%TZ", time.gmtime()), "SET", preset, f"{value:g} dB", "from", self.client_address[0], flush=True)
        return self.send(200, st)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            return                      # the client hung up; nothing to report
        super().handle_error(request, client_address)


if __name__ == "__main__":
    print(f"noise relay on {BIND}:{PORT}, presets {PRESETS}", flush=True)
    threading.Thread(target=refresher, daemon=True).start()
    Server((BIND, PORT), Handler).serve_forever()
