#!/usr/bin/env bash
# Stage 1b of the new testbed: Open5GS 5G core on the core host's k3s (P3 Tiny, 10.42.0.2).
# Run from REDLAB (repo root):
#   scp infra/core/open5gs.yaml infra/core/open5gs.sh tiny:/tmp/ && ssh -t tiny 'sudo MODE=preview bash /tmp/open5gs.sh'
#   MODE=preview     show what would change (default, changes nothing)
#   MODE=apply       apply /tmp/open5gs.yaml, wait for every NF, add the test subscriber, then check
#   MODE=subscriber  (re)write the test subscriber from the local secrets file
#   MODE=check       tests only
#   MODE=remove      delete the namespace (subscriber DB included), ogstun and the NAT rule; needs CONFIRM=yes
# The test SIM (IMSI, K, OPc) lives only in /home/<user>/testbed-secrets/ue1.env (mode 600). It is created with
# random K/OPc on first use and is never printed, committed or copied into the manifest.
set -u
MODE=${MODE:-preview}
NS=open5gs; HOST_IP=10.42.0.2; DNN=fctoai; IMSI_DEFAULT=001700000000001
YAML=${YAML:-/tmp/open5gs.yaml}
USER_NAME=${SUDO_USER:-root}; UHOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
SECRETS=$UHOME/testbed-secrets/ue1.env
NFS="nrf scp ausf udm udr pcf bsf nssf smf amf upf"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }
k(){ kubectl -n $NS "$@"; }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  kubectl get nodes 2>/dev/null | grep -q " Ready " && ok "k3s node Ready" || bad "k3s not ready (stage 1a)"
  [ -f "$YAML" ] && ok "manifest $YAML ($(sha256sum "$YAML" | cut -c1-16))" || bad "no $YAML"
  ip -4 -o addr | grep -q " $HOST_IP/" && ok "host has $HOST_IP" || bad "host has no $HOST_IP"
  lsmod | grep -q '^sctp' && ok "SCTP loaded" || bad "SCTP not loaded"
  for img in $(grep -oE 'image: [^ ]+' "$YAML" 2>/dev/null | awk '{print $2}' | sort -u) docker.io/gradiant/open5gs-dbctl:0.10.3 docker.io/curlimages/curl:8.10.1; do
    k3s crictl pull "$img" >/dev/null 2>&1 && ok "image available: $img" || bad "image NOT available: $img"
  done
  for p in 38412/S 2152/u 8805/u 7777/t; do port=${p%/*}; fl=${p#*/}
    ss -Hln$fl "( sport = :$port )" | grep -q . && bad "host port $port in use" || ok "host port $port free"; done
}

subscriber(){
  echo "== Test subscriber"
  if [ ! -f "$SECRETS" ]; then
    install -d -m 700 -o "$USER_NAME" -g "$USER_NAME" "$(dirname "$SECRETS")"
    ( umask 077; printf 'IMSI=%s\nKI=%s\nOPC=%s\n' "$IMSI_DEFAULT" "$(openssl rand -hex 16)" "$(openssl rand -hex 16)" > "$SECRETS" )
    chown "$USER_NAME:$USER_NAME" "$SECRETS"; echo "  created $SECRETS (random K/OPc, mode 600, not shown)"
  else echo "  using $SECRETS (not shown)"; fi
  k create secret generic ue1-sim --from-env-file="$SECRETS" --dry-run=client -o yaml | k apply -f - >/dev/null
  k delete job add-ue1 --ignore-not-found >/dev/null
  cat <<YAML | k apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: {name: add-ue1, namespace: $NS}
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: dbctl
        image: docker.io/gradiant/open5gs-dbctl:0.10.3
        env: [{name: DB_URI, value: "mongodb://open5gs-mongodb/open5gs"}]
        envFrom: [{secretRef: {name: ue1-sim}}]
        command: ["bash", "-c", "open5gs-dbctl remove \"\$IMSI\" >/dev/null 2>&1; open5gs-dbctl add_ue_with_apn \"\$IMSI\" \"\$KI\" \"\$OPC\" $DNN >/dev/null && echo added"]
YAML
  k wait --for=condition=complete job/add-ue1 --timeout=180s >/dev/null 2>&1 && echo "  subscriber written" || echo "  subscriber job did not complete: $(k logs job/add-ue1 2>&1 | tail -2)"
}

check(){
  echo "== Checks"
  for nf in mongodb $NFS; do
    k rollout status deploy/open5gs-$nf --timeout=10s >/dev/null 2>&1 && ok "open5gs-$nf running" || bad "open5gs-$nf not running ($(k get pod -l app.kubernetes.io/name=$nf --no-headers 2>/dev/null | awk '{print $3}'))"
  done
  q=$(kubectl run nrf-query -n $NS --rm -i --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c '
      for t in AMF SMF AUSF UDM UDR PCF BSF NSSF SCP; do
        n=$(curl -s --http2-prior-knowledge -m 5 "http://open5gs-nrf-sbi:7777/nnrf-nfm/v1/nf-instances?nf-type=$t" | grep -o "nf-instances/[0-9a-f-]*" | sort -u | wc -l)
        echo "NRF $t $n"; done' 2>/dev/null)
  for t in AMF SMF AUSF UDM UDR PCF BSF NSSF SCP; do
    n=$(echo "$q" | awk -v t=$t '$1=="NRF" && $2==t {print $3}')
    [ "${n:-0}" = 1 ] && ok "NRF: $t registered once" || bad "NRF: $t registered ${n:-0} times (want 1)"
  done
  ss -HlnS "( sport = :38412 )" | grep -q "$HOST_IP:38412" && ok "AMF NGAP listening on $HOST_IP:38412 (SCTP)" || bad "AMF NGAP not on $HOST_IP:38412"
  ss -Hlnu "( sport = :2152 )" | grep -q "$HOST_IP:2152" && ok "UPF GTP-U on $HOST_IP:2152" || bad "UPF GTP-U not on $HOST_IP:2152"
  ip -4 -br addr show ogstun 2>/dev/null | grep -q "10.45.0.1/16" && ok "ogstun 10.45.0.1/16 on the host" || bad "ogstun missing"
  iptables -t nat -S POSTROUTING | grep -q -- "-s 10.45.0.0/16 ! -o ogstun -j MASQUERADE" && ok "NAT for 10.45.0.0/16 in host iptables" || bad "NAT rule not in host iptables"
  k logs deploy/open5gs-smf 2>/dev/null | grep -q "PFCP associated" && ok "SMF-UPF PFCP associated" || bad "no PFCP association in SMF log"
  c=$(k exec deploy/open5gs-mongodb -- mongosh --quiet open5gs --eval \
      "const s=db.subscribers.findOne({imsi:'$(grep ^IMSI= "$SECRETS" 2>/dev/null | cut -d= -f2)'},{_id:0,'slice.sst':1,'slice.session.name':1}); print(s ? s.slice[0].sst+' '+s.slice[0].session[0].name : 'none')" 2>/dev/null)
  [ "$c" = "1 $DNN" ] && ok "subscriber in DB with SST 1, DNN $DNN (keys not shown)" || bad "subscriber in DB: '$c' (want '1 $DNN')"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  Open5GS image: $(grep -oE 'gradiant/open5gs:[0-9.]+' "$YAML" | sort -u)"
  echo "  kubectl apply -f $YAML: namespace $NS, MongoDB (2Gi local-path volume), $NFS"
  echo "  AMF and UPF on the host network: NGAP $HOST_IP:38412, GTP-U/PFCP $HOST_IP:2152/8805, ogstun 10.45.0.1/16, NAT 10.45.0.0/16"
  echo "  test subscriber from $SECRETS (created with random K/OPc if missing; never shown)"
  echo "  undo: MODE=remove CONFIRM=yes" ;;
apply)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  kubectl apply -f "$YAML"
  echo "== Waiting for the NFs (first run pulls images, can take a few minutes)"
  for nf in mongodb $NFS; do k rollout status deploy/open5gs-$nf --timeout=300s; done
  subscriber; sleep 5; F=0; check ;;
subscriber) subscriber; F=0; check ;;
check) check ;;
remove)
  [ "${CONFIRM:-}" = yes ] || { echo "This deletes namespace $NS (subscriber DB included), ogstun and the NAT rule. Re-run with CONFIRM=yes"; exit 1; }
  kubectl delete ns $NS --wait=true
  ip link del ogstun 2>/dev/null && echo "ogstun removed"
  iptables -t nat -D POSTROUTING -s 10.45.0.0/16 ! -o ogstun -j MASQUERADE 2>/dev/null && echo "NAT rule removed"
  echo "kept: $SECRETS" ;;
*) echo "MODE must be preview, apply, subscriber, check or remove"; exit 1 ;;
esac
