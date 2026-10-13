# FCT 5G Testbed Dashboard

A custom monitoring and control dashboard for an open-source 5G SA testbed in the FCT Lab It gives one end-to-end view of the testbed: network function status, live signalling, and UE radio KPIs.

The testbed runs **in RF simulator mode only**. There is no over-the-air transmission.

## Testbed

| Host | Role | Software |
|---|---|---|
| FCT0172 (`10.0.129.2`) | 5G core | Open5GS (Helm, single-node Kubernetes), UPF on host network, UE pool `10.45.0.0/16` |
| FCT0173 (`10.0.129.7`) | RAN | OAI gNB and nrUE (develop branch) in rfsim, single-node Kubernetes, host network |

Radio configuration: n78, 40 MHz (106 PRB), 30 kHz SCS, TDD 7 DL / 3 UL slots per 5 ms, PLMN 001/70, SST 1.

### Bench testbed (being rebuilt, 2026-10)

The testbed is being moved to dedicated bench machines on their own LAN (`10.42.0.0/24`, TL-SG105 switch, no link to the lab network).
Everything needed to rebuild it is in `infra/`; secrets stay on the machines.

| Host | Address | Role | Status |
|---|---|---|---|
| REDLAB (Lenovo P3 Ultra SFF Gen 2, Core Ultra 9 285) | `10.42.0.1` | RAN: OAI gNB + nrUE (rfsim); LAN gateway (NetworkManager shared mode) | done, stage 2 PASS |
| P3 Tiny (Core i9-14900, 30 GiB) | `10.42.0.2` | 5G core: Open5GS 2.8.0 on k3s v1.31.4 | done, stage 1 PASS |
| reComputer J4012 (Jetson Orin NX 16 GB) | `10.42.0.3` | MEC / AI (later) | network only |

Core on the P3 Tiny: k3s with pods `10.244.0.0/16` and services `10.96.0.0/16` (the k3s defaults overlap the bench LAN).
Namespace `open5gs`: MongoDB, NRF, SCP, AUSF, UDM, UDR, PCF, BSF, NSSF, SMF; AMF and UPF on the host network
(NGAP `10.42.0.2:38412`, GTP-U `10.42.0.2:2152`, `ogstun` `10.45.0.1/16`, NAT for `10.45.0.0/16`). DNN `fctoai`, TAC 1.
The test SIM (IMSI `001700000000001`, random K/OPc) is in `~/testbed-secrets/ue1.env` on the core host only.
Stage 1 test: `infra/core/open5gs.sh` MODE=check, 5 consecutive runs PASS (2026-10-12).

RAN on REDLAB: k3s with pods `10.248.0.0/16` and services `10.100.0.0/16` (clear of the core ranges and of Docker's bridges).
OAI `2026.w40` gNB and nrUE in rfsim mode only (`--rfsim` in both Deployments, checked by the test), host network:
n78, 106 PRB, 30 kHz SCS, PLMN 001/70, NG to the AMF at `10.42.0.2`, gNB N2/N3 on `10.42.0.1`. The UE gets its address on `oaitun_ue1`.
The UE config is rendered at start from a Kubernetes Secret into memory. The nrUE prints the SIM key at start,
so its output goes through a filter that masks IMSI, K and OPc before it reaches the container log.
Stage 2 test: `infra/ran/ran.sh` MODE=check, 5 consecutive runs PASS (2026-10-13): SCTP NGAP association up on both ends,
UE `10.45.0.3`, ping to the UPF and to the internet through the tunnel, no SIM value in any UE log file (rotated files included),
host default route untouched, no pod restarts.

## What the dashboard shows

- **Overview**: topology (SBI bus, N2/N3/N4/N6) with live status of every core NF, the gNB and the UE; tiles for connected gNBs and UEs and DL/UL MAC goodput.
- **5G SA message flow**: N2 NGAP/NAS captured on the gNB host with tshark, plus Uu events (SSB found, SIB1, RA Msg1–Msg4, RRCSetupComplete) parsed from the gNB and UE logs, in chronological order.
- **UE KPIs**: CQI, MCS, BLER, SNR, RSRP/RSSI and DL/UL goodput from the gNB MAC statistics, sampled once per second, 2/5/15 min windows, CSV export.
- **Controls** (admin password, rfsim mode only): gNB Start/Stop, UE Start/Stop, DL/UL speed test, and **DL channel** presets Off / Clean / Moderate / Poor (AWGN on the UE receiver through the noise relay; the active preset is shown next to the buttons).

Goodput is reported in simulated time. rfsim runs about 1.88x faster than real time, so wall-clock tools such as iperf3 report higher numbers than the MAC goodput.

## Files

| File | Purpose |
|---|---|
| `app.py` | Backend (Python standard library only): reads both clusters through the Kubernetes API, parses AMF and gNB logs, keeps 15 min of KPI history, exposes `/api/*` |
| `index.html` | Front end (single page, no framework) |
| `infra/k3s-node.sh` | Single-node k3s for a bench host, `PROFILE=core` or `ran`: non-overlapping CIDRs, SCTP, kubeconfig for the login user, host network state compared before and after (preview / apply / kubeconfig / check) |
| `infra/core/gen-open5gs.py` | Generates `infra/core/open5gs.yaml` (edit the generator, not the YAML) |
| `infra/core/open5gs.yaml` | Open5GS 2.8.0 manifest for the bench core (generated) |
| `infra/core/open5gs.sh` | Deploy and test the bench core: preview / apply / subscriber / check / remove; test SIM from a local secrets file |
| `infra/ran/gnb.yaml` | OAI gNB config (CI rfsim band 78, 106 PRB) with the bench PLMN and addresses |
| `infra/ran/nr-ue.yaml.tpl` | nrUE config template; SIM placeholders are filled from a Secret at pod start |
| `infra/ran/ran.yaml` | OAI gNB and nrUE Deployments for REDLAB (rfsim, host network, SIM masking filter) |
| `infra/ran/ran.sh` | Deploy and test the bench RAN: preview / apply / check / remove; copies the test SIM from the core host |
| `capture.py`, `n2-capture.yaml` | N2 capture service on the RAN host (tshark on SCTP 38412, JSON over HTTP on port 8091) |
| `fct-dash.yaml` | Dashboard Deployment and NodePort 30880 on the core cluster |
| `ran-control.yaml` | Least-privilege controller account (may only scale `oai-gnb`, `oai-nr-ue`, `speedtest-dl`, `speedtest-ul`) and the iperf3 speed-test clients |
| `iperf-server.yaml` | iperf3 speed-test servers on the UPF host, ports 5201/5202 |
| `build.py` | Builds `fct-dash-install.sh`, a single installer that embeds every file above |
| `fct-dash-install.sh` | Generated installer. Run from a host that can `ssh fct0172` and `ssh fct0173` |
| `d6-test.sh` | Acceptance test of the controls through the API |
| `uu-check.sh` | Checks that Uu events appear in order before InitialUEMessage |
| `iperf-regress.sh` | Regression test: kill the UE mid speed test, require recovery without restarting the server |
| `exp-noise.sh` | Experiment: downlink AWGN sweep through the OAI telnet `channelmod` module |
| `exp-noise-timeline.sh` | LAB-0: switch the DL presets through the relay during a DL speed test; samples CQI, MCS, BLER, goodput, UE SINR with switch times; checks each phase (PASS/FAIL) |
| `plot-noise-timeline.py` | LAB-0: annotated timeline graph from `exp-noise-timeline.sh` output (`docs/labs/img/`) |
   | `ue-chanmod.sh` | Noise presets stage A: OAI channel model (AWGN) and telnet on 127.0.0.1:9090 on the baseline UE. Runs on FCT0173: preview, apply, check (includes lab0), rollback |
      | `noise-relay.py`, `noise-relay.yaml` | Noise relay on the RAN host (10.0.129.7:8092, host network): sets the UE channel model to one of four fixed presets (off/clean/moderate/poor) through the UE telnet on 127.0.0.1:9090; changes need a shared token |
   | `noise-relay.sh` | Install and test the noise relay on FCT0173: preview, install, test, remove |
## Downlink noise presets (measured)

Chosen with `exp-noise.sh` v5 (AWGN on the UE receive path, OAI `channelmod`, DL speed test running).
Confirmation run 2026-10-09 (`run-20261009T151305Z`): each level held 6 x 10 s, first sample discarded,
same RNTI throughout, always in-sync, no link loss. Result: PASS.
- Dashboard (stage C, 2026-10-11, installer v0.8.0): the Controls bar has DL channel buttons. The dashboard calls the relay with the token from the Secret `fct-dash-noise` (copied by the installer). `d6-test.sh` step 6b sets Moderate through the dashboard (DL MCS 15 +/- 3), then Off (MCS >= 24). Relay v3 answers GET from memory and applies a preset in about 1 s. Do not press the buttons while `noise-relay.sh` or `d6-test.sh` is running: they use the same UE.

| Preset | `noise_power_dB` | CQI | DL MCS | DL BLER | MAC goodput DL |
|---|---|---|---|---|---|
| Clean | -11 | 14 | 26 (all 5 samples) | 0 | ~84 Mbit/s |
| Moderate | -6.5 | 9 | 15 (all 5 samples) | 0 | ~39.7 Mbit/s |
| Poor | -3 | 5 | 6 (all 5 samples) | 0 | ~14.3 Mbit/s |
| Off | -100 | 15 | 28 | ~0 | ~78-86 Mbit/s |

Notes:
- The gNB uses the 64QAM MCS table (MCS 28 on new transmissions; in the 256QAM table, index 28 is reserved; TS 38.214 Tables 5.1.3.1-1/-2).
- -11 dB sits on the CQI 14/15 boundary: an earlier single-sample sweep read CQI 15 / MCS 27 there.
- With no DL traffic the gNB reports MCS 0, goodput 0 and a decaying BLER; that is the idle state, not a link problem.
- The sweep reached -2 dB (CQI 4, MCS 4, ~10 Mbit/s) without link loss; the loss threshold is lower and not yet measured.
 - Since 2026-10-10 the baseline UE runs with the channel model (AWGN, -100 dB) and a telnet server on 127.0.0.1:9090 (`ue-chanmod.sh`). The change is in `~/fct-testbed/ran/oai-nr-ue-deploy.json`, which `lab0-run.sh` applies, plus the ConfigMap `oai-ue-chanmod`; `ue.conf` is unchanged. Gates after the change: lab0 T0.4-T0.7, `d6-test.sh`, `iperf-regress.sh` and `uu-check.sh` all PASS.
- `exp-noise.sh` v6 runs on the baseline UE through its telnet (no second UE) and re-reads `noise: -100` when it restores. Re-run of the confirmation sweep on the baseline UE (`run-20261010T144928Z`): PASS, same MCS per preset (-11: 26-27, -6.5: 15, -3: 6). v5 must not be used any more.
-    Noise relay (stage B, 2026-10-11): `GET http://10.0.129.7:8092/noise` shows the active preset; `POST /noise {"preset": ...}` with header `X-Relay-Token` sets one. Only the four preset names are accepted. The token is the Secret `noise-relay-token` (namespace `fct-dash`, FCT0173). `noise-relay.sh` MODE=test: PASS (refusals, command injection, moderate gives DL MCS 15, back to off); gates d6, uu-check, iperf-regress PASS.
## Install

```bash
python3 build.py              # regenerate the installer after editing any file
bash fct-dash-install.sh      # prompts for the admin password on first install
```

Then open `http://10.0.129.2:30880`.

## Security notes

- The read-only account can list pods, logs, services, nodes and events. It cannot read ConfigMaps or Secrets and cannot exec into pods.
- The controller account can only patch the scale of four named Deployments. It cannot create or delete pods.
- The admin password lives in a Kubernetes Secret and is never written to this repository.
- No SIM keys (K/OPc) or other credentials are stored here.
- The noise relay accepts only the preset names off/clean/moderate/poor, checks a token in constant time, builds the telnet command from a fixed table, and has no Kubernetes API access.

## Lessons learned

- **iperf3 "server is busy".** Ubuntu's `iperf3.service` was listening on `*:5201` on the core host, so every DL test ran against it, and it stayed stuck when a client vanished. Disable it with `sudo systemctl disable --now iperf3`. Every iperf3 process here runs under a watchdog that restarts it after 5 s of 0-byte intervals, or after 10 s without progress while a connection is open.
- **Stale NRF registrations in Open5GS.** NFs register with pod IPs. When an NF restarts, its consumers keep the old address. Restart consumers in dependency order (SMF, then AMF).
-  **lab0 re-creates the UE from its source file.** `lab0-run.sh` runs `kubectl apply -f ran/oai-nr-ue-deploy.json`, so a change made only to the live Deployment is undone at the next lab0 run (the first attempt of `ue-chanmod.sh` crashed the UE this way: "cannot open include file"). Change the source file and run lab0 as part of the test.
- **Bench core (k3s, Open5GS 2.8.0).** (1) The k3s default pod CIDR `10.42.0.0/16` collides with the bench LAN; use `--cluster-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/16`. (2) k3s's `kubectl` reads `/etc/rancher/k3s/k3s.yaml` when `KUBECONFIG` is unset, so `~/.kube/config` is ignored; give the file group read (`write-kubeconfig-group`), and keep `--write-kubeconfig-mode` off the service command line (it overrides `config.yaml`). (3) The UPF init container got `ioctl(TUNSETIFF): Operation not permitted` while privileged but not root; it must run with `runAsUser: 0`, as in the Gradiant chart. (4) Right after start, PFCP association takes a few seconds and PCF/UDR can restart while MongoDB starts; test after the NFs have settled.
- **Bench RAN (OAI rfsim on k3s).** (1) The nrUE logs the full SIM at start (`[SIM] UICC simulation: IMSI=..., Ki=..., OPc=...`); its output is piped through `sed` that masks the values before it reaches the container log, and the test scans every log file of the pod. (2) kubelet rotates and compresses container logs at about 10 MB, so start-up lines such as `NGSetupResponse` disappear from `kubectl logs` after a while; tests check current state (SCTP association, tunnel address, ping) instead. (3) `kubectl -o jsonpath` prints arrays as Go JSON, which escapes `<` and `>` as `\u003c` and `\u003e`; do not grep for those characters. (4) Use `k3s kubectl`, not a snap `kubectl` of another version.
- **Relay latency.** The first relay used two telnet sessions with fixed waits per change and a background reader on the same lock, so a change could take more than 8 s and the dashboard timed out although the noise had been applied. Relay v3 uses one session that stops reading as soon as the report is complete; the relay test now fails if a change takes 5 s or more.
