# OAI nrUE, bench testbed (REDLAB), rfsim only. Based on OAI ci-scripts/conf_files/nrue.uicc.yaml (2026.w40).
# TEMPLATE: __IMSI__/__KI__/__OPC__ are filled at pod start from the Kubernetes Secret ue1-sim
# (made from ~/testbed-secrets/ue1.env, never committed). DNN and slice match the core subscriber.
uicc0:
  imsi: "__IMSI__"
  key: "__KI__"
  opc: "__OPC__"
  pdu_sessions:
    - dnn: fctoai
      nssai_sst: 1
thread-pool: "-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1"
rfsimulator:
  - serveraddr: "127.0.0.1"
