# Experiment 12a (feasibility): an O-RAN SMO managing the OAI gNB over O1

Status: **feasibility study** (2026-11-03). Desk study only; nothing was installed or changed on the bench.
Follows from the professor's question about which SMO to use. Recommended order: O-RAN SC OAM with the OAI O1 adapter
first (O1, FCAPS), then the O-RAN SC Non-RT RIC with rApps over A1, which leads into Experiment 12 (near-RT RIC,
FlexRIC). Nephio (O2, intent-based deployment) comes later. Full ONAP is too heavy for this bench.

## Summary
| Question | Answer |
|---|---|
| Does OAI 2026.w40 have an O1 hook? | Yes. The telnet module `o1` (`libtelnetsrv_o1.so`) is in the source and is copied into the `oai-gnb:2026.w40` image |
| What can it do? | `o1 stats` (cell config and live load as JSON), `o1 bwconfig 20/40/60/100`, `o1 stop_modem`, `o1 start_modem`, `o1 remove_mac_ues`. **`o1 config <values>` only parses its arguments at w40; it does not apply them** |
| What gives the SMO NETCONF/YANG and VES? | The OAI **o1-adapter** (netopeer2 + sysrepo + `gnb-adapter`): 3GPP NRM YANG (`_3gpp-nr-nrm-nrcelldu`, `-bwp`, ...), VES alarms, heartbeat, pnfRegistration and 15-minute PM files |
| Can the SMO change the carrier as in Experiment 1? | Partly. A NETCONF edit of `bSChannelBwDL`/`UL` makes the adapter run `stop_modem`, `bwconfig <MHz>`, `start_modem`. Only 20/40/60/100 MHz are available, at OAI's hard-coded frequencies, which differ from the Experiment 1 profiles. The UE does not follow on its own |
| Alarm when the gNB stops? | Yes, if the gNB process or pod goes away: the adapter raises `internalConnectionLoss` (telnet connection lost for more than 3 s) and clears it on reconnect. `o1 stop_modem` alone raises no alarm because telnet stays up |
| Where does the SMO run? | On a **separate host** on the bench LAN, not on REDLAB (30 GB RAM, already about 23 GB used). Only the small adapter runs on REDLAB |
| Hardware for the SMO | O-RAN SC OAM tested VM: 4 cores, 16 GB RAM, 50 GB disk (the wiki guideline says 100 GB), Ubuntu 24.04, Docker 27.x, Compose v2 |
| Verdict | **Feasible** for read-only management, alarms and PM, and for a 20/40/60/100 MHz switch with a coordinated UE retune. Open points: the adapter's compatibility with the current OAM (M release) and the hard-coded `bwconfig` frequencies |

## 1. OAI side: the telnet `o1` module at tag 2026.w40
Checked in the GitHub mirror `OPENAIRINTERFACE/openairinterface5g`, tag `2026.w40` (commit `f8f76959`, 2026-10-04):
`common/utils/telnetsrv/telnetsrv_o1.c`, `common/utils/telnetsrv/DOC/telneto1.md`, `docker/Dockerfile.gNB.ubuntu`.

| Command | What it does at w40 |
|---|---|
| `o1 stats` | JSON with two parts. `o1-config` holds the BWP (numberOfRBs, startRB, SCS) and NRCellDU fields (ssbFrequency, arfcnDL/UL, bSChannelBwDL/UL in MHz, nRPCI, nRTAC, one PLMN and S-NSSAI) plus gnbId and gnbName. `O1-Operational` holds frame type, band, number of UEs, RNTIs, DL load in % and per-UE DL/UL throughput |
| `o1 stop_modem` | Forces UL failure for the connected UEs, waits 50 ms, stops all L1 threads. The softmodem "freezes"; telnet keeps working |
| `o1 bwconfig 20\|40\|60\|100` | Only while stopped. Writes hard-coded SSB, point A, PRB count and BWP RIV into the cell, rebuilds the MIB and SIB1, and sets 3/4 sampling (on for 40, off otherwise). TDD only |
| `o1 config ssbFrequency arfcnDL bSChannelBwDL numberOfRBs startRB` | Only while stopped. **Parses and prints the values but does not write them into the cell** (code at w40). The doc describes it as a write, so do not rely on it |
| `o1 start_modem` | Restarts L1/L2 with the current cell config; in F1 the DU sends a gNB-DU configuration update |
| `o1 remove_mac_ues` | Clears all UE contexts in the DU |

`bwconfig` values compared with our Experiment 1 profiles (`docs/experiments/EXP-01-bandwidth.md`):

| `bwconfig` | PRB | Point A | SSB ARFCN | 3/4 sampling | Our Experiment 1 profile |
|---|---|---|---|---|---|
| 20 | 51 | 640596 | 641280 | off | bw-51: point A 639996, SSB 640704, `-E` |
| 40 | 106 | 640008 | 641280 | on | bw-106 (baseline): point A 620040, SSB 621312, `-E` |
| 60 | 162 | 620040 | 621984 | off | none (same point A as our baseline) |
| 100 | 273 | 643392 | 646668 | off | bw-273: point A 626772, SSB 630048, `-E` |
| (none) | 24 | | | | bw-24 (10 MHz) has no `bwconfig` value |

So an SMO switch moves the carrier to a different centre frequency than our profiles, and the UE has to be retuned
(`-r`, `-C`, `--ssb`, `-E`) to find the cell again. In rfsim the UE does not scan, so it would stay lost.

**Enabling it on our gNB** (a proposal, not applied). Our gNB pod (`infra/ran/ran.yaml`) has no telnet server today and
runs with `hostNetwork: true`. The telnet default is `listenaddr 0.0.0.0`, which would expose an unauthenticated
shell that can stop the modem on every REDLAB interface. So it must be:

```
USE_ADDITIONAL_OPTIONS="-E --rfsim --log_config.global_log_options level,nocolor,time \
  --telnetsrv --telnetsrv.listenaddr 127.0.0.1 --telnetsrv.listenport 9091 --telnetsrv.shrmod o1"
```

Port 9091 because the UE's telnet already uses 127.0.0.1:9090 (noise relay). 9091 is also the adapter's default.
`ran.sh check` would get the same kind of gate it has for the UE: "gNB telnet listens on 127.0.0.1:9091 only".
Only one telnet client can be connected at a time, so the adapter would own the gNB's telnet. Any later dashboard
use of the gNB telnet has to go through the adapter, or the two have to take turns.

Not yet verified on the bench: whether `/usr/local/lib/libtelnetsrv_o1.so` is really in the pulled image (the
Dockerfile copies it). That needs a read-only `k3s kubectl exec deploy/oai-gnb -- ls /usr/local/lib/libtelnetsrv_o1.so`
on REDLAB.

## 2. The OAI o1-adapter
Repository `gitlab.eurecom.fr/oai/o1-adapter` (Apache-2.0/CSSL; created 2023-12; `main` last commit 2026-06-04
"KPM management using NETCONF server"; **no tags, no release versions, no compatibility table**). Branches:
`main`, `o1-cu`, `o1-cu-tls`, `pm-alarms`, `flexric-support`, `ru-m-plane`, `IISc_cu_config`, `fix_yangname`.
A third-party deployment guide exists at `github.com/ngkore/OAI-O1-Adapter`.

| Part | Content |
|---|---|
| Container | `adapter-gnb` (Ubuntu 22.04), built locally with `./build-adapter.sh --adapter`; no published image |
| NETCONF server | netopeer2 2.1.49 + sysrepo 2.2.36 + libyang 2.1.30; NETCONF over SSH on 830 (mapped to 1830), TLS on 6513; SFTP for PM files |
| YANG | 3GPP SA5 MnS Rel-18 NRM: `_3gpp-common-managed-element`, `-managed-function`, `-fm`, `-measurements`, `-files`, `_3gpp-nr-nrm-gnbdufunction`, `-gnbcucpfunction`, `-gnbcuupfunction`, `-nrcelldu`, `-nrcellcu`, `-bwp`, `-nrsectorcarrier`, `-ep` and others (fetched by `get-yangs.sh` from the 3GPP forge) |
| Telnet side | Polls `o1 stats` every second. A NETCONF edit of `bSChannelBwDL` = `bSChannelBwUL` runs `o1 stop_modem`, `o1 bwconfig <MHz>`, `o1 start_modem`. DL and UL bandwidths must be equal; nothing else is writable towards the gNB |
| VES | `pnfRegistration`, heartbeat (30 s), new/clear alarm, PM `fileReady` (stndDefined), to `https://<collector>/eventListener/v7` with basic auth |
| Alarms | `internalConnectionLoss` (telnet to the softmodem lost > 3 s), `loadDownlinkExceededWarning` (DL load > 50 % for 30 s) |
| PM | `DRB.MeanActiveUeDl/Ul`, `DRB.MaxActiveUeDl/Ul` from `num-ues`, 3GPP measData XML every 15 min, kept 24 h |
| Config | `config.json`: telnet host/port, VES URL and credentials, node-id, NETCONF port. A change needs an image rebuild in the documented flow (or a bind mount) |

How it fits the O-RAN SC OAM: the OAM controller (OpenDaylight-based SDN-R) mounts the adapter as a NETCONF node
(manually in ODLUX, or after the adapter's VES `pnfRegistration`). It reads and edits the YANG data over NETCONF.
The adapter pushes VES events to the OAM VES collector, which publishes them on Kafka (message router). The
controller and ODLUX show them as faults and the PM file notifications as performance data.

Its "with SMO" integration flow (`make run-o1-oai-adapter-smo`) clones the OAM repo at an old Gerrit change from
before the J release and uses ONAP SDNC 2.7.0 images. The ngkore guide calls that path outdated and uses a separate
OAM setup instead. **Compatibility with the current OAM (M release) is unverified.**

## 3. The SMO: O-RAN SC OAM
- Releases: L (2025), **M completed December 2025** (OAM controller moved to OpenDaylight Scandium-SR2; PM file
  transfer from O-DU/O-CU/near-RT RIC to SMO-OAM). N was in planning in early 2026; no N release notice found by
  2026-11-03. Use the M release branch and confirm before installing.
- Deployment: Docker Compose from the `oam` repo, `solution/` folder, started in order: `infra/` (Traefik gateway),
  `smo/common/` (Keycloak identity, Kafka message router, MariaDB), then `smo/common/identity/config.py` (users), then
  `smo/oam/` (controller, VES collector, ODLUX, Node-RED flows). `network/` (simulated O-DU/O-RU) is optional and
  not needed with a real adapter.
- Names: Traefik routes by FQDN under `smo.o-ran-sc.org` (`odlux.oam.`, `controller.dcn.`, `ves-collector.dcn.`,
  `identity.`, ...), resolved through `/etc/hosts` on the SMO host and on REDLAB (for the adapter's VES URL).
- Hardware: tested VM 4 cores, 16 GB RAM, 50 GB disk (wiki guideline: 100 GB); Ubuntu 24.04.1, Docker 27.x,
  Compose v2.29+, Python 3.12.

## 4. Proposed architecture for this bench

```
 bench LAN 10.42.0.0/24 (isolated)
 ┌─────────────────── SMO host (new, e.g. 10.42.0.3) ─────────────────┐
 │ O-RAN SC OAM (M): Traefik · Keycloak · OpenDaylight controller ·   │
 │ VES collector · Kafka · ODLUX · MariaDB  (Docker Compose)          │
 └───────▲ NETCONF/SSH :1830 (SMO -> REDLAB)        │ VES HTTPS :443 ──┘
         │                                          ▼ (REDLAB -> SMO)
 ┌───────┴──────── REDLAB 10.42.0.1 (k3s, hostNetwork) ───────────────┐
 │ o1-adapter pod  ── telnet 127.0.0.1:9091 ──>  oai-gnb (2026.w40)   │
 │                                                --telnetsrv o1      │
 │ oai-nr-ue (telnet 127.0.0.1:9090, noise relay) · profile relay     │
 └────────────────────────────────────────────────────────────────────┘
 tiny 10.42.0.2: Open5GS, dashboard, Prometheus (unchanged)
```

- The adapter runs on REDLAB with host networking, because the gNB telnet is bound to 127.0.0.1. It is small
  (netopeer2 + a C daemon). Its footprint on REDLAB is to be measured; the hypothesis is under 0.2 cores and 300 MB.
  NETCONF (1830) is bound to REDLAB's bench LAN address only, never to the campus interface.
- The SMO runs on its own host on the bench LAN (a mini PC or a VM elsewhere). It does not go on REDLAB, which is
  loaded by the UE simulation (Experiment 1: up to 2.6 cores per simulated second at 273 PRB). It does not go on tiny
  either: the core, dashboard and Prometheus must stay unaffected.
- One controller per parameter. The carrier is already switched by the profile relay (`infra/dash/profile.sh`, 8093),
  which restarts gNB and UE pods from `gnb.yaml`. An SMO `bwconfig` changes the running gNB without touching the
  repo config, so the relay's baseline and the gNB disagree until the next pod restart, which puts the repo config
  back. The experiment must state who owns the carrier at any time, and the relay must not switch while the SMO is
  in charge.

## 5. What a first experiment (12a) would show
Same method as the other experiments: baseline, one change, measured again, with scripted PASS checks.

1. **Inventory and read (O1 CM read).** Mount the adapter in ODLUX. A NETCONF `get` of `ManagedElement/GNBDUFunction/
   NRCellDU` and `BWP` returns the running cell. PASS: arfcnDL 620040, ssbFrequency 621312, numberOfRBs 106,
   bSChannelBwDL 40, nRPCI and nRTAC as in `infra/ran/gnb.yaml`, and `o1 stats` agrees. Also `ncclient` from a script,
   so the check does not depend on the GUI.
2. **Carrier change from the SMO (O1 CM write, compared with Experiment 1).** Edit `bSChannelBwDL/UL` to 60
   (162 PRB). This is the only `bwconfig` value whose point A (620040) matches our baseline, so only the width and
   SSB change. Retune the UE to the new carrier, then measure capacity as in Experiment 1 and switch back to 40.
   Compare with a pod-restart switch: time to service and whether the gNB survives `stop_modem`/`start_modem` in rfsim.
   Hypothesis: around 134 Mbit/s at 162 PRB if the 0.83 Mbit/s per PRB of Experiment 1 holds.
3. **Fault (O1 FM, VES).** Scale the gNB deployment to 0 (or delete the pod). PASS: `internalConnectionLoss` arrives
   in the VES collector or Kafka within about 5 s and shows in ODLUX as active. After the gNB is back, the alarm
   clears. Also show that `o1 stop_modem` raises no alarm: a teaching point about what an alarm can and cannot see.
4. **Performance (O1 PM).** One 15-minute PM file over SFTP with `DRB.MeanActiveUeDl` = 1 and a `fileReady` VES
   notification, compared with the dashboard's UE count.

Step 2 needs a UE retune that the SMO cannot do (the UE is not an O1 managed element). Either the profile relay gets
an "SMO 60 MHz" profile that only retunes the UE, or the step is done in two moves, SMO first and then the UE.

## 6. Security
- Bench LAN only. NETCONF 1830, SFTP and the adapter's TLS port bind to 10.42.0.1. Every OAM endpoint binds to the
  SMO host's bench LAN address. No port forwarding to campus or the internet. Host firewall: allow 1830 only from the
  SMO host, and 443 only from REDLAB to the SMO.
- gNB telnet bound to 127.0.0.1:9091 with a `ran.sh check` gate. It has no authentication and can stop the modem.
- Credentials: the adapter image bakes in `netconf:netconf!`, its example VES credentials are `sample1`, and it ships
  TLS client and server keys in the repo. None of these may be used. Build the image with our own NETCONF user, mount
  `config.json` and the TLS material from k3s Secrets (as for `ue1-sim`), and generate our own CA and certificates.
  On the SMO, change the `.env` default passwords (Keycloak admin, ODLUX, MariaDB, Kafka) and keep them out of git.
- The OAM brings many images from several registries. Pin the M release tags and do not use `latest`.

## 7. Hardware needed
| Item | Minimum | Suggested |
|---|---|---|
| SMO host (O-RAN SC OAM) | 4 cores, 16 GB RAM, 50-100 GB SSD, Ubuntu 24.04 | 8 cores, 32 GB, 256 GB SSD (room for the Non-RT RIC and rApps later) |
| Network | one port on the bench LAN switch, fixed address (e.g. 10.42.0.3) | same |
| REDLAB | adapter pod only; no new hardware | measure its CPU and RAM in the first run |

## 8. Risks
| Risk | Effect | Mitigation |
|---|---|---|
| The adapter has no releases and its SMO flow targets an old OAM (before J) | NETCONF mount or VES schema may not match the M release | Start with a NETCONF-only check (`ncclient`, then ODLUX mount) before VES; pin the adapter commit (`08f208b2`); report issues upstream |
| `o1 config` is a stub at w40; `bwconfig` frequencies are hard-coded | The SMO cannot set our Experiment 1 profiles | Use `bwconfig 60` (same point A); or a small local patch to the `o1` module (out of scope here) |
| `stop_modem`/`start_modem` in rfsim untested by us | gNB hang or crash, UE lost | Run first when nothing else is scheduled; `ran.sh` restores the baseline |
| One telnet client at a time | The adapter blocks any other gNB telnet use | The adapter is the only gNB telnet client; a later dashboard view reads through NETCONF |
| Two controllers for the carrier (SMO and profile relay) | Inconsistent state; the relay restores a config the SMO did not expect | Ownership rule in section 4; the relay refuses to switch while the adapter reports a non-baseline carrier |
| SMO resource needs grow (Non-RT RIC, rApps) | 16 GB is not enough later | Size the SMO host for 32 GB from the start |
| Telnet or NETCONF exposed by mistake on host networking | Remote modem stop / reconfiguration | Bind checks in `ran.sh check` and a check script for the adapter |

## 9. Open questions
1. Which host runs the SMO: a new mini PC on the bench LAN or a VM on a lab server? Who provides it?
2. Do we accept a local patch to `telnetsrv_o1.c` so `o1 config` really writes the cell? That would allow our exact
   Experiment 1 profiles from the SMO, but means building our own gNB image instead of the pinned 2026.w40 one.
3. Does the adapter on `main` (2026-06) mount cleanly in the M release controller, and does its VES pass the M
   collector's schema validation? To be tested on the SMO host before anything touches REDLAB.
4. Is O1 for the UE side needed at all (the UE is not a managed element in O-RAN), or does the profile relay stay the
   UE's controller?
5. Next steps after 12a: the O-RAN SC Non-RT RIC (A1, rApps) on the same SMO host, linked to Experiment 12 (near-RT RIC,
   FlexRIC, E2). Nephio (O2) only once the bench has more than one cluster to deploy to.

## Proposed stages (each only with the user's OK)
| Stage | Where | Changes the bench? |
|---|---|---|
| S1 | SMO host: install OAM M with Compose; build the adapter image; test the adapter against its built-in telnet test server | No |
| S2 | REDLAB: read-only check that `libtelnetsrv_o1.so` is in the image | No |
| S3 | REDLAB: gNB with `--telnetsrv` on 127.0.0.1:9091 + `shrmod o1`; `ran.sh check` gate; `o1 stats` from the host | Yes (gNB restart) |
| S4 | REDLAB: adapter pod (host network, Secrets), NETCONF mount from the SMO; experiment steps 1, 3, 4 | Yes (new pod) |
| S5 | Experiment step 2 (carrier change from the SMO) with the UE retune | Yes |

## Sources
- OAI telnet O1 module at 2026.w40: [telneto1.md](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/common/utils/telnetsrv/DOC/telneto1.md),
  [telnetsrv_o1.c](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/common/utils/telnetsrv/telnetsrv_o1.c),
  [telnetusage.md](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/common/utils/telnetsrv/DOC/telnetusage.md) (listenaddr default 0.0.0.0, port 9090, `shrmod`),
  [Dockerfile.gNB.ubuntu](https://github.com/OPENAIRINTERFACE/openairinterface5g/blob/2026.w40/docker/Dockerfile.gNB.ubuntu) (copies `libtelnetsrv_o1.so`)
- OAI o1-adapter: [gitlab.eurecom.fr/oai/o1-adapter](https://gitlab.eurecom.fr/oai/o1-adapter) (README, `integration/README.md`, `src/telnet/telnet.c`, `src/netconf/netconf_data.c`, `dictionary/`, `docker/scripts/install-yangs.sh`; commit `08f208b2`, 2026-06-04);
  OAI merge request [!2466 "O1 Adapter"](https://gitlab.eurecom.fr/oai/openairinterface5g/-/merge_requests/2466);
  third-party guide [ngkore/OAI-O1-Adapter](https://github.com/ngkore/OAI-O1-Adapter)
- O-RAN SC OAM deployment: [docs.o-ran-sc.org OAM deployment](https://docs.o-ran-sc.org/projects/o-ran-sc-oam/en/latest/deployment.html),
  [OAM Deployment Guideline (wiki)](https://lf-o-ran-sc.atlassian.net/wiki/x/AwDZBw)
- O-RAN SC releases: [M Release (wiki)](https://lf-o-ran-sc.atlassian.net/wiki/spaces/REL/pages/317784066/M-Release),
  [OAM controller release notes](https://docs.o-ran-sc.org/projects/o-ran-sc-oam-oam-controller/en/latest/release-notes.html),
  [RSAC meeting notes 2026-03-03](https://lf-o-ran-sc.atlassian.net/wiki/spaces/RSAC/pages/808714242/2026-03-03+RSAC+Meeting+notes) (N release planning)
- 3GPP NRM YANG: [3GPP SA5 MnS Rel-18 yang-models](https://forge.3gpp.org/rep/sa5/MnS/-/tree/Rel-18/yang-models)
- Bench: `infra/ran/ran.yaml`, `infra/ran/ran.sh`, `infra/dash/profile.sh`, [EXP-01](EXP-01-bandwidth.md)
