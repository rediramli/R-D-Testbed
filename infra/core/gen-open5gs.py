#!/usr/bin/env python3
"""Generate infra/core/open5gs.yaml: Open5GS 5G core on single-node k3s (core host 10.42.0.2).

Configs follow the Gradiant open5gs chart templates (written for 2.7.5; the 2.8.0 config files only differ in comments): NFs reach each other through the SCP,
the SCP and NSSF use the NRF. Testbed values: PLMN 001/70, TAC 1, SST 1, DNN fctoai, UE pool 10.45.0.0/16.
AMF and UPF use the host network so the gNB on the bench LAN reaches NGAP (SCTP 38412) and GTP-U (2152)
on 10.42.0.2, and ogstun (10.45.0.1) lives on the host as on the old testbed. No secrets here: subscribers
are added by open5gs.sh from a local file that is never committed.
Usage: python3 infra/core/gen-open5gs.py > infra/core/open5gs.yaml   (OPEN5GS_IMAGE=... to change the image)
"""
import json
import os
import yaml

NS = "open5gs"
IMAGE = os.environ.get("OPEN5GS_IMAGE", "docker.io/gradiant/open5gs:2.8.0")
HOST_IP = "10.42.0.2"
MCC, MNC, TAC, SST, DNN = "001", "70", 1, 1, "fctoai"
SUBNET, GW = "10.45.0.0/16", "10.45.0.1"
DB_URI = "mongodb://open5gs-mongodb/open5gs"
SCP = "http://open5gs-scp-sbi:7777"
NRF = "http://open5gs-nrf-sbi:7777"
PLMN = {"mcc": MCC, "mnc": MNC}


class Dumper(yaml.SafeDumper):
    """No anchors/aliases (the Open5GS config parser does not follow them); multi-line strings as | blocks."""
    def ignore_aliases(self, data):
        return True


Dumper.add_representer(str, lambda d, s: d.represent_scalar(
    "tag:yaml.org,2002:str", s, style="|" if "\n" in s else None))
POD_SBI = {"server": [{"dev": "eth0", "port": 7777}], "client": {"scp": [{"uri": SCP}]}}

configs = {
    "nrf": {"nrf": {"serving": [{"plmn_id": PLMN}], "sbi": {"server": [{"dev": "eth0", "port": 7777}]}}},
    "scp": {"scp": {"sbi": {"server": [{"dev": "eth0", "port": 7777}], "client": {"nrf": [{"uri": NRF}]}}}},
    "ausf": {"ausf": {"sbi": POD_SBI}},
    "udm": {"udm": {"sbi": POD_SBI}},
    "udr": {"udr": {"sbi": POD_SBI}},
    "pcf": {"pcf": {"sbi": POD_SBI}},
    "bsf": {"bsf": {"sbi": POD_SBI}},
    "nssf": {"nssf": {"sbi": {"server": [{"dev": "eth0", "port": 7777}],
                              "client": {"scp": [{"uri": SCP}],
                                         "nsi": [{"uri": NRF, "s_nssai": {"sst": SST}}]}}}},
    "smf": {"smf": {
        "sbi": POD_SBI,
        "pfcp": {"server": [{"dev": "eth0"}], "client": {"upf": [{"address": HOST_IP}]}},
        "gtpc": {"server": [{"dev": "eth0"}]},
        "gtpu": {"server": [{"dev": "eth0"}]},
        "session": [{"subnet": SUBNET, "gateway": GW, "dnn": DNN}],
        "dns": ["8.8.8.8", "8.8.4.4"],
        "mtu": 1400}},
    "amf": {"amf": {
        "sbi": {"server": [{"address": HOST_IP, "port": 7777}], "client": {"scp": [{"uri": SCP}]}},
        "ngap": {"server": [{"address": HOST_IP}]},
        "guami": [{"plmn_id": PLMN, "amf_id": {"region": 2, "set": 1}}],
        "tai": [{"plmn_id": PLMN, "tac": TAC}],
        "plmn_support": [{"plmn_id": PLMN, "s_nssai": [{"sst": SST}]}],
        "security": {"integrity_order": ["NIA2", "NIA1", "NIA0"], "ciphering_order": ["NEA0", "NEA1", "NEA2"]},
        "network_name": {"full": "FCT-Bench"},
        "amf_name": "open5gs-amf",
        "time": {"t3512": {"value": 540}}}},
    "upf": {"upf": {
        "pfcp": {"server": [{"address": HOST_IP}]},
        "gtpu": {"server": [{"address": HOST_IP}]},
        "session": [{"subnet": SUBNET, "gateway": GW, "dnn": DNN, "dev": "ogstun"}]}},
}
for c in configs.values():
    c["logger"] = {"level": "info"}

UPF_INIT = f"""set -e
# Idempotent: with hostNetwork, ogstun and the NAT rule stay on the host across pod restarts.
ip link show ogstun >/dev/null 2>&1 || ip tuntap add name ogstun mode tun
ip link set ogstun up
ip link set dev ogstun txqueuelen 4096
ip addr replace {GW}/16 dev ogstun
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s {SUBNET} ! -o ogstun -j MASQUERADE 2>/dev/null || \\
  iptables -t nat -A POSTROUTING -s {SUBNET} ! -o ogstun -j MASQUERADE
echo "ogstun ready: $(ip -4 -br addr show ogstun)"
"""

docs = [{"apiVersion": "v1", "kind": "Namespace", "metadata": {"name": NS}}]

def labels(name): return {"app.kubernetes.io/name": name, "app.kubernetes.io/part-of": "open5gs"}

# MongoDB (subscriber database), persistent volume from the k3s local-path provisioner
docs += [
    {"apiVersion": "v1", "kind": "PersistentVolumeClaim",
     "metadata": {"name": "open5gs-mongodb", "namespace": NS},
     "spec": {"accessModes": ["ReadWriteOnce"], "storageClassName": "local-path",
              "resources": {"requests": {"storage": "2Gi"}}}},
    {"apiVersion": "apps/v1", "kind": "Deployment",
     "metadata": {"name": "open5gs-mongodb", "namespace": NS, "labels": labels("mongodb")},
     "spec": {"replicas": 1, "strategy": {"type": "Recreate"},
              "selector": {"matchLabels": labels("mongodb")},
              "template": {"metadata": {"labels": labels("mongodb")},
                           "spec": {"containers": [{
                               "name": "mongodb", "image": "docker.io/library/mongo:6.0",
                               "args": ["--bind_ip_all"],
                               "ports": [{"name": "mongodb", "containerPort": 27017}],
                               "volumeMounts": [{"name": "data", "mountPath": "/data/db"}]}],
                               "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "open5gs-mongodb"}}]}}}},
    {"apiVersion": "v1", "kind": "Service",
     "metadata": {"name": "open5gs-mongodb", "namespace": NS},
     "spec": {"selector": labels("mongodb"), "ports": [{"name": "mongodb", "port": 27017}]}},
]

for nf in ["nrf", "scp", "ausf", "udm", "udr", "pcf", "bsf", "nssf", "smf", "amf", "upf"]:
    name = f"open5gs-{nf}"
    host = nf in ("amf", "upf")
    docs.append({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": NS},
                 "data": {f"{nf}.yaml": yaml.dump(configs[nf], Dumper=Dumper, sort_keys=False)}})
    c = {"name": nf, "image": IMAGE, "imagePullPolicy": "IfNotPresent",
         "command": [f"open5gs-{nf}d"], "args": ["-c", f"/opt/open5gs/etc/open5gs/{nf}.yaml"],
         "volumeMounts": [{"name": "config", "mountPath": f"/opt/open5gs/etc/open5gs/{nf}.yaml", "subPath": f"{nf}.yaml"}]}
    if nf in ("udr", "pcf"):
        c["env"] = [{"name": "DB_URI", "value": DB_URI}]
    if nf == "upf":
        # as in the Gradiant chart: root + privileged, otherwise TUNSETIFF fails with EPERM (image user is not root)
        c["securityContext"] = {"privileged": True, "runAsUser": 0, "runAsGroup": 0, "runAsNonRoot": False}
    spec = {"containers": [c], "volumes": [{"name": "config", "configMap": {"name": name}}]}
    if host:
        spec.update(hostNetwork=True, dnsPolicy="ClusterFirstWithHostNet")
    if nf == "upf":
        spec["initContainers"] = [{"name": "ogstun", "image": IMAGE, "command": ["/bin/bash", "-c", UPF_INIT],
                                   "securityContext": {"privileged": True, "runAsUser": 0, "runAsGroup": 0,
                                                       "runAsNonRoot": False}}]
    docs.append({"apiVersion": "apps/v1", "kind": "Deployment",
                 "metadata": {"name": name, "namespace": NS, "labels": labels(nf)},
                 "spec": {"replicas": 1, "strategy": {"type": "Recreate"},
                          "selector": {"matchLabels": labels(nf)},
                          "template": {"metadata": {"labels": labels(nf)}, "spec": spec}}})
    if not host:
        ports = [{"name": "sbi", "port": 7777, "protocol": "TCP"}]
        if nf == "smf":
            ports.append({"name": "pfcp", "port": 8805, "protocol": "UDP"})
        docs.append({"apiVersion": "v1", "kind": "Service",
                     "metadata": {"name": f"{name}-sbi", "namespace": NS},
                     "spec": {"selector": labels(nf), "ports": ports}})

print("# GENERATED by infra/core/gen-open5gs.py - edit the generator, not this file")
print(yaml.dump_all(docs, Dumper=Dumper, sort_keys=False, explicit_start=True, width=120), end="")
