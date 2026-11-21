# OAI nrUE (2026.w43, see ocudu-cell.yaml) for the OCUDU cell (Experiment 16), ZMQ radio. Based on infra/ran/nr-ue.yaml.tpl (no rfsim,
# no channel model: ZMQ has none). Radio, carrier and capabilities are set on the command line (ocudu-cell.yaml).
# TEMPLATE: __IMSI__/__KI__/__OPC__ are filled at pod start from the Kubernetes Secret ue2-sim
# (made from ~/testbed-secrets/ue2.env on tiny, never committed). DNN and slice match the core subscriber.
uicc0:
  imsi: "__IMSI__"
  key: "__KI__"
  opc: "__OPC__"
  pdu_sessions:
    - dnn: fctoai
      nssai_sst: 1
thread-pool: "-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1"
