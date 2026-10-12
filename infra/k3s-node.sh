#!/usr/bin/env bash
# Single-node k3s for a bench testbed host.  PROFILE=core (P3 Tiny, 10.42.0.2) or PROFILE=ran (REDLAB, 10.42.0.1).
# The bench LAN is 10.42.0.0/24, which collides with the k3s defaults (pods 10.42.0.0/16), so each host gets its own
# non-overlapping ranges (also clear of Docker's 172.17-172.19 bridges on REDLAB):
#   core: pods 10.244.0.0/16, services 10.96.0.0/16,  DNS 10.96.0.10
#   ran:  pods 10.248.0.0/16, services 10.100.0.0/16, DNS 10.100.0.10
# Traefik and the service load balancer are disabled. SCTP is loaded (NGAP). The login user can run kubectl.
# On apply, the host's default route, tailscale0 and docker state are recorded and compared afterwards.
# Run:  core: scp infra/k3s-node.sh tiny:/tmp/ && ssh -t tiny 'sudo PROFILE=core MODE=preview bash /tmp/k3s-node.sh'
#       ran (on REDLAB):  sudo PROFILE=ran MODE=preview bash infra/k3s-node.sh
#   MODE=preview  show what would change (default, changes nothing)
#   MODE=apply    load SCTP, install k3s (pinned version), kubeconfig for the login user, then check
#   MODE=kubeconfig  (existing install) make /etc/rancher/k3s/k3s.yaml readable by the login user's group, restart k3s, check
#   MODE=check    tests only
set -u
MODE=${MODE:-preview}
K3S_VERSION=${K3S_VERSION:-v1.31.4+k3s1}
PROFILE=${PROFILE:-}
case "$PROFILE" in
  core) NODE_IP=${NODE_IP:-10.42.0.2}; POD_CIDR=10.244.0.0/16; SVC_CIDR=10.96.0.0/16;  DNS_IP=10.96.0.10 ;;
  ran)  NODE_IP=${NODE_IP:-10.42.0.1}; POD_CIDR=10.248.0.0/16; SVC_CIDR=10.100.0.0/16; DNS_IP=10.100.0.10 ;;
  *) echo "set PROFILE=core or PROFILE=ran"; exit 1 ;;
esac
SNAP=/var/lib/k3s-node-before
IFACE=${IFACE:-$(ip -4 -o addr | awk -v ip="$NODE_IP" '$4 ~ "^"ip"/" {print $2; exit}')}
USER_NAME=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
ARGS="--node-ip $NODE_IP --flannel-iface $IFACE --cluster-cidr $POD_CIDR --service-cidr $SVC_CIDR --cluster-dns $DNS_IP --disable traefik --disable servicelb"
# kubeconfig readable by the login user's group: k3s's kubectl reads /etc/rancher/k3s/k3s.yaml when KUBECONFIG is unset
KCFG="write-kubeconfig-mode: \"0640\"\nwrite-kubeconfig-group: $USER_NAME"
# always the k3s client: a different kubectl in PATH (e.g. the snap, v1.35) is out of the supported version skew
KC="k3s kubectl"
F=0; ok(){ echo "  PASS  $1"; }; bad(){ echo "  FAIL  $1"; F=$((F+1)); }

pre(){
  echo "== Preconditions"
  [ "$(id -u)" = 0 ] && ok "running as root (sudo)" || { bad "run with sudo"; exit 1; }
  [ -n "$IFACE" ] && ok "LAN interface $IFACE has $NODE_IP" || { bad "no interface with $NODE_IP"; exit 1; }
  modinfo sctp >/dev/null 2>&1 && ok "SCTP kernel module available" || bad "SCTP module missing (apt install linux-modules-extra-\$(uname -r))"
  curl -sfI -m 10 https://get.k3s.io >/dev/null && ok "internet: get.k3s.io reachable" || bad "cannot reach get.k3s.io"
  curl -sfIL -m 15 -o /dev/null "https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}/k3s" && ok "k3s $K3S_VERSION release exists" || bad "k3s $K3S_VERSION not downloadable (set K3S_VERSION=...)"
  for p in 6443 10250; do ss -Htln "( sport = :$p )" | grep -q . && bad "port $p already in use" || ok "port $p free"; done
  for c in $POD_CIDR $SVC_CIDR; do p=$(echo $c | cut -d. -f1-2).
    { ip -4 route; ip -4 -o addr; } | grep -q " $p\|^$p" && bad "$c overlaps an existing route/address" || ok "$c does not overlap this host's routes"; done
  command -v docker >/dev/null && echo "  note  docker present ($(systemctl is-active docker 2>/dev/null)); k3s uses its own containerd"
  ip link show tailscale0 >/dev/null 2>&1 && echo "  note  tailscale0 present; checked again after install"
}

check(){
  echo "== Checks"
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  # right after start the node, the CoreDNS deployment, the podCIDR and the default service account appear one by one
  for i in $(seq 1 90); do
    $KC get nodes 2>/dev/null | grep -q " Ready " && $KC -n kube-system get deploy coredns >/dev/null 2>&1 \
      && [ -n "$($KC get node -o jsonpath='{.items[0].spec.podCIDR}' 2>/dev/null)" ] \
      && $KC get serviceaccount default >/dev/null 2>&1 && break
    sleep 2; done
  $KC get nodes -o wide 2>/dev/null | grep -q " Ready " && ok "node Ready" || bad "node not Ready"
  $KC -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 && ok "CoreDNS running" || bad "CoreDNS not running"
  pc=$($KC get node -o jsonpath='{.items[0].spec.podCIDR}')
  case "$pc" in $(echo $POD_CIDR | cut -d. -f1-2).*) ok "pod CIDR $pc (does not overlap the 10.42.0.0/24 LAN)";; *) bad "pod CIDR '$pc'";; esac
  ip route | grep -q "^10.42.0.0/24 dev $IFACE" && ok "LAN route 10.42.0.0/24 still on $IFACE" || bad "LAN route changed: $(ip route | grep '^10.42.0.0')"
  # retry inside the pod: right after install CoreDNS can need a few seconds before it answers
  out=$($KC run k3s-check --rm -i --restart=Never --image=busybox:1.36 --command -- \
        sh -c 'for i in 1 2 3 4 5 6; do nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && { echo DNS_OK; break; }; sleep 2; done
               for i in 1 2 3; do wget -q -T 5 -O /dev/null http://example.com && { echo NET_OK; break; }; sleep 2; done' 2>/dev/null)
  echo "$out" | grep -q DNS_OK && ok "cluster DNS from a pod" || bad "cluster DNS from a pod"
  echo "$out" | grep -q NET_OK && ok "internet from a pod" || bad "internet from a pod"
  lsmod | grep -q '^sctp' && ok "SCTP loaded" || bad "SCTP not loaded"
  su - "$USER_NAME" -c 'k3s kubectl get nodes >/dev/null 2>&1' && ok "user $USER_NAME can run 'k3s kubectl' without sudo" || bad "user $USER_NAME cannot run 'k3s kubectl'"
  if [ -f $SNAP ]; then
    . $SNAP
    [ "$(ip -4 route show default | head -1)" = "$DEF" ] && ok "default route unchanged ($DEF)" || bad "default route changed: now '$(ip -4 route show default | head -1)', was '$DEF'"
    [ "$TS" = no ] || { ip -br link show tailscale0 2>/dev/null | grep -qE "UP|UNKNOWN" && ok "tailscale0 still up" || bad "tailscale0 not up"; }
    [ "$DOCKER" != active ] || { [ "$(systemctl is-active docker)" = active ] && ok "docker still active" || bad "docker not active"; }
  fi
  echo "RESULT: $([ $F = 0 ] && echo PASS || echo "FAIL ($F)")"
}

case "$MODE" in
preview)
  pre
  echo "== Would do"
  echo "  load sctp now and at boot (/etc/modules-load.d/sctp.conf)"
  echo "  profile $PROFILE: install k3s $K3S_VERSION with: $ARGS"
  echo "  /etc/rancher/k3s/config.yaml: kubeconfig mode 0640, group $USER_NAME (so $USER_NAME can run kubectl)"
  echo "  undo: /usr/local/bin/k3s-uninstall.sh (removes k3s and everything in it)" ;;
apply)
  pre; [ $F = 0 ] || { echo "STOP: preconditions failed"; exit 1; }
  { echo "DEF='$(ip -4 route show default | head -1)'"; ip link show tailscale0 >/dev/null 2>&1 && echo TS=yes || echo TS=no
    echo "DOCKER=$(systemctl is-active docker 2>/dev/null | head -1)"; } > $SNAP
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
