# Experiment 12: Near-RT RIC (FlexRIC): E2 monitoring, slice control and closed loop

RF simulator only. The near-RT RIC is FlexRIC; the E2 agent is the one built into the OAI 2026.w40 gNB image.

| Stage | What | Status |
|---|---|---|
| R0 | Check of the FlexRIC installation on the bench, version match with the gNB | Done 2026-11-20 |
| R1 | nearRT-RIC as a pod on REDLAB, E2 from the gNB, KPM monitor xApp, E2 state and KPM on the dashboard and in Prometheus | Done 2026-11-20, `ric.sh` check PASS |
| R2 | Slice control (RC / slice SM) | Planned |
| R3 | Closed loop: KPM in, RC control out | Planned |

## R0: installation check (2026-11-20, read-only)

| Item | Found |
|---|---|
| Where | REDLAB (10.42.0.1), native builds only (no pod, no container). Nothing on tiny |
| New install | `~/R-D-Testbed/flexric` (untracked folder inside the main checkout), gitlab mosaic5g/flexric `dev`, shallow clone `fbd9859` (2026-11-18), Debug, **E2AP v2 / KPM v2.03**. RIC and SMs built, **no xApp** (asn1c missing), not installed |
| `/usr/local` | `nearRT-RIC` from 2026-04, SMs from 2026-08 (older builds); `/usr/local/etc/flexric/flexric.conf` has `NEAR_RIC_IP = 192.168.10.1` (not on the host) |
| gNB image | OAI 2026.w40 builds FlexRIC from its submodule (github duranta-project/flexric **`d7a71285`**, 2026-09-17) with **E2AP v3 / KPM v3.00** (`docker/Dockerfile.build.ubuntu` ARGs) and copies `/usr/local/lib/flexric` into the gNB image |
| Match | **No**: a RIC with E2AP v2 cannot decode the E2 SETUP of an E2AP v3 agent |
| RIC running | No; nothing on SCTP 36421/36422 |
| gNB | No `e2_agent` section in `infra/ran/gnb.yaml`; RAN scaled to 0 since 2026-11-17 |
| Bind address | FlexRIC binds E2 and E42 to `NEAR_RIC_IP` (`src/ric/endpoint_ric.c`), so `127.0.0.1` keeps the RIC off the LAN |

Rebuild on REDLAB (native, for the tests below): asn1c `940dd5fa` (the commit FlexRIC's own Dockerfile uses) into
`~/.local/asn1c` without sudo, FlexRIC `d7a71285` in `~/flexric-w40` with `-DE2AP_VERSION=E2AP_V3 -DKPM_VERSION=KPM_V3_00
-DASN1C_EXEC_PATH=~/.local/asn1c/bin/asn1c`. Without asn1c the xApp library does not compile (it includes RRC/F1AP
code that asn1c generates at build time): that is why the earlier builds had no xApp.

Native tests, 2026-11-20:

| Test | Result |
|---|---|
| nearRT-RIC 12 s, `NEAR_RIC_IP = 127.0.0.1` | SCTP LISTEN on `127.0.0.1:36421` and `:36422` only (`ss`, `/proc/net/sctp/eps`); 8 SMs loaded (KPM 2, RC 3, MAC 142, RLC 143, PDCP 144, SLICE 145, TC 146, GTP 148); clean exit on SIGINT |
| gNB with `e2_agent` (`sudo MODE=apply bash infra/ran/ran.sh`) | gNB log `[E2 AGENT]: nearRT-RIC IP Address = 127.0.0.1, PORT = 36421 ... nb_id = 3584`; RIC log `E2 SETUP-REQUEST rx from PLMN 1.70 Node ID 3584 RAN type ngran_gNB`, all 8 RAN functions accepted |
| `xapp_kpm_moni` 15 s | E42 setup, 2 KPM subscriptions (report styles of the gNB), 24 indications: per UE `DRB.UEThpDl/Ul`, `RRU.PrbTotDl/Ul`, `DRB.PdcpSduVolumeDL/UL`, `DRB.RlcSduDelayDl`; per cell `CARR.PDSCHMCSDist`, `CARR.PUSCHMCSDist`, `RRC.ConnMean`; clean unsubscribe |

## R1: RIC pod, KPM relay, dashboard (2026-11-20)

```
gNB (OAI w40, host network) --E2 SCTP 127.0.0.1:36421--> nearRT-RIC  ┐ pod flexric-ric, namespace fct-dash, REDLAB,
                                                       E42 :36422 <-- xapp_kpm_moni <- kpm-relay ┘ host network, user nobody
kpm-relay 10.42.0.1:8095 (token) <-- dashboard on tiny (/api/state "ric")  <-- Prometheus on tiny (job flexric, bearer token)
```

| File | Purpose |
|---|---|
| `infra/ric/Dockerfile.flexric` | Image `docker.io/fct/flexric:d7a71285-e2ap3`: FlexRIC `d7a71285`, E2AP v3, KPM v3, Release; RIC, KPM xApp, 8 SMs |
| `infra/ric/ric-relay.py` | Runs the xApp, parses its output, E2 state from `/proc/net/sctp`; `GET /healthz`, `/status` (JSON), `/metrics` (Prometheus) with token; read only |
| `infra/ric/flexric.conf` | `NEAR_RIC_IP = 127.0.0.1` (ports fixed at this commit: 36421 / 36422) |
| `infra/dash/ric-ran.yaml` | Deployment `flexric-ric` (two containers, host network, read-only root, no API token, `/tmp` emptyDir 64 Mi) |
| `infra/dash/ric.sh` | `sudo MODE=image` (docker build + k3s import), `preview`, `apply`, `check`, `remove` |
| `infra/ran/gnb.yaml` | `e2_agent: near_ric_ip_addr 127.0.0.1, sm_dir /usr/local/lib/flexric/` |
| `app.py`, `index.html` | `ric` in `/api/state`; O-RAN view: RIC box with commit, E2 state and a KPM line, E2 link live while indications arrive, details per UE; status bar; gNB interfaces |
| `infra/dash/prom-core.yaml`, `prom.sh` | Job `flexric` (5 s, bearer token from Secret `fct-dash-ric`); `prom.sh` expects 7 targets once the token is installed |

Security: the RIC is reachable from REDLAB only (127.0.0.1); the relay listens only on the bench LAN address, needs
the token (Secret `fct-dash/ric-relay-token` on REDLAB, copy `fct-dash/fct-dash-ric` on tiny) for every path except
`/healthz`, compares it in constant time, refuses POST, has no Kubernetes API access and starts nothing but the xApp.

Install order on the bench:

```bash
sudo MODE=image bash infra/dash/ric.sh     # docker build as the login user, import into k3s
sudo MODE=apply bash infra/dash/dash.sh    # dashboard with the RIC view and the token mount
MODE=apply bash infra/dash/prom.sh         # job flexric
MODE=apply bash infra/dash/ric.sh          # RIC pod, token, restart dashboard + Prometheus, check
```

`MODE=check bash infra/dash/ric.sh` (2026-11-20, after the gNB restart): **PASS**, 22 checks: one nearRT-RIC on the
host, in the pod; SCTP endpoints 36421/36422 on 127.0.0.1 only; 1 E2 association; RIC log E2 SETUP from PLMN 001/70
with KPM and RC accepted; relay on 10.42.0.1:8095 only, not on REDLAB's other addresses, 401 without / with a wrong
token on `/status` and `/metrics`, POST 405; KPM indications flowing (latency 0.8 ms); KPM per UE present;
**`DRB.UEThpDl` 0.02 kbit/s idle, 62.7 Mbit/s peak during the dashboard DL speed test** (first apply: 60.0 Mbit/s);
dashboard `/api/state` shows the RIC, E2 up and KPM per UE; Prometheus job `flexric` up, `flexric_kpm_ue_thp_dl_kbps` stored.

### Findings

- **E2AP version must match the gNB image.** The OAI w40 image is E2AP v3 / KPM v3.00 (FlexRIC `d7a71285`); FlexRIC
  `dev` built with its own defaults (E2AP v2 / KPM v2.03) does not interoperate.
- **asn1c is required** even for a plain KPM xApp: the xApp library compiles RRC and F1AP code generated by asn1c
  (mouse07410 fork, `940dd5fa`).
- **The xApp library logs every indication to SQLite** in `/tmp` (measured 165 kB/s on the bench, about 600 MB/h, no
  limit). `XAPP_DB=NONE_XAPP` is offered by CMake at `d7a71285` but not implemented ("Unknown XAPP_DB selected"), so
  the Dockerfile removes the one `write_db_xapp` call (the build stops if the line is not found). In the pod `/tmp`
  stays at about 110 kB.
- **A second nearRT-RIC on a busy port does not exit**: its bind fails and its SCTP sockets end up on `0.0.0.0` with
  ephemeral ports (seen in `/proc/net/sctp/eps`). `ric.sh` refuses to start while another nearRT-RIC runs and checks
  that exactly one exists.
- **The RIC's printf output is block-buffered** when stdout is a pipe: the pod log stayed empty. The container runs
  it under `stdbuf -oL -eL`.
- **After a RIC restart the gNB must be restarted.** The OAI E2 agent re-connects SCTP from the same local port but
  does not repeat E2 SETUP: the new RIC reports `Registered E2 nodes = 0` and drops the indications of the old
  subscriptions (`RIC Indication message arrived for RIC REQ ID 1021 but no xApp associated`); the xApp gets no E2
  node. A gNB restart (then the UE) repeats E2 SETUP. Seen once the other way: when the native RIC had been stopped
  minutes before the pod started, the gNB did a new E2 SETUP on its own (cause not shown). `ric.sh check` names the
  case and says to restart the gNB.
- **The xApp subscribes only to the E2 nodes present at its start** and asserts when there is none. The relay starts
  it only while an E2 association exists and restarts it after 10 s without an indication.
- KPM `DRB.UEThpDl` is the gNB's own measurement in simulated time, like the dashboard MAC goodput.

### Regression gates (2026-11-20/21)

| Gate | Result |
|---|---|
| `sudo MODE=apply bash infra/dash/dash.sh` (includes check) | **PASS** (twice); cell 2, core and RAN KPIs, Prometheus windows, reader RBAC unchanged |
| `MODE=check bash infra/dash/prom.sh` | **PASS**, 7 targets up (ric = FlexRIC relay) |
| `MODE=check bash infra/dash/ric.sh` | **PASS** |
| `sudo MODE=check bash infra/ran/ran.sh` | **PASS**, 18 checks, 2026-11-21 after a UE restart (UE 10.45.0.53, masked `[SIM]` line present). The run before it was FAIL (1): the UE had run since 2026-11-20 11:36Z and log rotation (5 files) had dropped its start line, the only `[SIM]` line. Fixed in this branch: the SIM-log checks read the Running UE pod (a stale Failed pod made them FAIL on 2026-11-20) |
| `MODE=check bash infra/dash/kpi.sh` | **FAIL (8)**, same failures as before Experiment 12: noise off gives 36.1 / 35.4 Mbit/s on one TCP flow (CQI 15, MCS 28, BLER 0), below the 40.7 Mbit/s target, so the "off" phases grade throughput bad; this is EXP-16 open question 10 (34-37 Mbit/s on 2026-11-06, before E2). Poor preset: SINR, CQI, MCS, throughput bad, diagnosis `radio_sinr`, as required. Cell 2 isolation check read CQI -1 (no CQI in that one report) in the poor phase. Hypothesis, not shown: E2/KPM does not change cell 1's rate (values inside the pre-E2 range); an A/B with the RIC scaled to 0 would prove it |

### Next

- Prove that E2/KPM reporting does not lower cell 1's throughput (A/B with `flexric-ric` at 0 replicas, then gNB restart).
- R2: slice SM / RC control from an xApp; R3: KPM-RC closed loop.
- The native builds in `~/R-D-Testbed/flexric` (E2AP v2) and `~/flexric-w40` are not used by the pod.
