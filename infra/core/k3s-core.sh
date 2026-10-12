#!/usr/bin/env bash
# Stage 1a of the new testbed: single-node k3s on the core host (P3 Tiny, 10.42.0.2).
# The bench LAN is 10.42.0.0/24, which collides with the k3s defaults (pods 10.42.0.0/16), so the
# cluster uses pods 10.244.0.0/16, services 10.96.0.0/16, DNS 10.96.0.10. Traefik and the service load
# balancer are disabled (not needed; they would take host ports). SCTP is loaded for NGAP.
# Run from REDLAB:   scp infra/core/k3s-core.sh tiny:/tmp/ && ssh -t tiny 'sudo MODE=preview bash /tmp/k3s-core.sh'
#   MODE=preview  show what would change (default, changes nothing)
#   MODE=apply    load SCTP, install k3s (pinned version), give the login user a kubeconfig, then check
#   MODE=kubeconfig  (existing install) make /etc/rancher/k3s/k3s.yaml readable by the login user's group, restart k3s, check
#   MODE=check    tests only: node Ready, CoreDNS up, pod CIDR not overlapping the LAN, DNS and internet from a pod
set -u
MODE=${MODE:-preview}
K3S_VERSION=${K3S_VERSION:-v1.31.4+k3s1}
NODE_IP=${NODE_IP:-10.42.0.2}
IFACE=${IFACE:-$(ip -4 -o addr | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')}
USER_NAME=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
ARGS="--node-ip $NODE_IP --flannel-iface $IFACE --cluster-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/16 --cluster-dns 10.96.0.10 --disable traefik --disable servicelb"
# kubeconfig readable by the login user's group: k3s's kubectl reads /etc/rancher/k3s/k3s.yaml when KUBECONFIG is unset
KCFG="write-kubeconfig-mode: \"0640\"\nwrite-kubeconfig-group: $USER_NAME"
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  [ -n "$IFACE" ] && ok "LAN interface $IFACE has $NODE_IP" || { bad "no interface with $NODE_IP"; exit 1; }
  modinfo sctp >/dev/null 2>&1 && ok "SCTP kernel module available" || bad "SCTP module missing (apt install linux-modules-extra-\$(uname -r))"
  curl -sfI -m 10 https://get.k3s.io >/dev/null && ok "internet: get.k3s.io reachable" || bad "cannot reach get.k3s.io"
  curl -sfIL -m 15 -o /dev/null "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s" && ok "k3s $K3S_VERSION release exists" || bad "k3s $K3S_VERSION not downloadable (set K3S_VERSION=...)"
  for p in 6443 10250; do ss -Htln "( sport = :$p )" | grep -q . && bad "port $p already in use" || ok "port $p free"; done
  command -v docker >/dev/null && echo "  note  docker present (k3s uses its own containerd; no conflict expected)"
}

check(){
  echo "== Checks"
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  for i in $(seq 1 60); do kubectl get nodes 2>/dev/null | grep -q " Ready " && break; sleep 2; done
  kubectl get nodes -o wide 2>/dev/null | grep -q " Ready " && ok "node Ready" || bad "node not Ready"
  kubectl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 && ok "CoreDNS running" || bad "CoreDNS not running"
  pc=$(kubectl get node -o jsonpath='{.items[0].spec.podCIDR}')
  case "$pc" in 10.244.*) ok "pod CIDR $pc (does not overlap the 10.42.0.0/24 LAN)";; *) bad "pod CIDR '$pc'";; esac
  ip route | grep -q "^10.42.0.0/24 dev $IFACE" && ok "LAN route 10.42.0.0/24 still on $IFACE" || bad "LAN route changed: $(ip route | grep '^10.42.0.0')"
  # retry inside the pod: right after install CoreDNS can need a few seconds before it answers
  out=$(kubectl run k3s-check --rm -i --restart=Never --image=busybox:1.36 --command -- \
        sh -c 'for i in 1 2 3 4 5 6; do nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && { echo DNS_OK; break; }; sleep 2; done
               for i in 1 2 3; do wget -q -T 5 -O /dev/null http://example.com && { echo NET_OK; break; }; sleep 2; done' 2>/dev/null)
  echo "$out" | grep -q DNS_OK && ok "cluster DNS from a pod" || bad "cluster DNS from a pod"
  echo "$out" | grep -q NET_OK && ok "internet from a pod" || bad "internet from a pod"
  lsmod | grep -q '^sctp' && ok "SCTP loaded" || bad "SCTP not loaded"
  su - "$USER_NAME" -c 'kubectl get nodes >/dev/null 2>&1' && ok "user $USER_NAME can run kubectl" || bad "user $USER_NAME cannot run kubectl"
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  load sctp now and at boot (/etc/modules-load.d/sctp.conf)"
  echo "  install k3s $K3S_VERSION with: $ARGS"
  echo "  /etc/rancher/k3s/config.yaml: kubeconfig mode 0640, group $USER_NAME (so $USER_NAME can run kubectl)"
  echo "  undo: /usr/local/bin/k3s-uninstall.sh (removes k3s and everything in it)" ;;
apply)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  modprobe sctp && echo sctp > /etc/modules-load.d/sctp.conf
  install -d /etc/rancher/k3s && printf "$KCFG\n" > /etc/rancher/k3s/config.yaml
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server $ARGS || { echo "STOP: k3s install failed"; exit 1; }
  F=0; check ;;
kubeconfig)
  [ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
  install -d /etc/rancher/k3s && printf "$KCFG\n" > /etc/rancher/k3s/config.yaml
  echo "== /etc/rancher/k3s/config.yaml"; cat /etc/rancher/k3s/config.yaml
  systemctl restart k3s && echo "k3s restarted"; sleep 5
  ls -l /etc/rancher/k3s/k3s.yaml
  check ;;
check) check ;;
*) echo "MODE must be preview, apply, kubeconfig or check"; exit 1 ;;
esac
