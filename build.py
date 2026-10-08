#!/usr/bin/env python3
"""Build fct-dash-install.sh: one file that deploys the capture service on
FCT0173 and the dashboard on FCT0172. Run from REDLAB."""
files = {n: open(n).read() for n in ("app.py", "index.html", "fct-dash.yaml", "capture.py", "n2-capture.yaml", "ran-control.yaml", "iperf-server.yaml")}
for body in files.values():
    assert "FILEEOF" not in body

def embed(name):
    return f"cat > \"$TMP/{name}\" <<'FILEEOF'\n{files[name]}FILEEOF\n"

ran_remote = r'''set -e
cd ~/fct-dash
echo "== RAN 1. Port 8091 must be free (or already ours)"
if ss -ltnp 2>/dev/null | grep -q ":8091 " && ! kubectl -n fct-dash get deploy n2-capture >/dev/null 2>&1; then
  echo "STOP: port 8091 on FCT0173 is used by something else"; ss -ltnp | grep ":8091 "; exit 1
fi
echo "== RAN 2. Capture code and Deployment"
kubectl -n fct-dash create configmap n2-capture-app --from-file=capture.py --dry-run=client -o yaml | kubectl apply -f -
HASH=$(sha256sum capture.py | cut -c1-12)
sed "s/CODE_HASH/$HASH/" n2-capture.yaml | kubectl apply -f -
kubectl -n fct-dash rollout status deploy/n2-capture --timeout=240s
sleep 3
echo -n "Capture health: "; curl -s localhost:8091/healthz; echo
echo "== RAN 3. Controller account (scale only) and speed-test clients"
kubectl apply -f ran-control.yaml
kubectl auth can-i patch deployments/oai-gnb --subresource=scale -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may scale oai-gnb: /'
kubectl auth can-i create pods -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may create pods (must be no): /'
kubectl auth can-i patch deployments/ocudu-gnb --subresource=scale -n default --as=system:serviceaccount:fct-dash:fct-dash-controller | sed 's/^/  may scale anything else (must be no): /' 
git init -q 2>/dev/null || true
git add -A && git -c user.name="Redi" -c user.email="redi@fct-lab" commit -qm "n2-capture $HASH" || true
'''

core_remote = r'''set -e
cd ~/fct-dash
echo "== CORE 1. Secret for the RAN cluster API (read-only token)"
KC=$HOME/.kube/ran-reader.kubeconfig
umask 077; mkdir -p .ran
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.clusters[0].cluster.server}' > .ran/server
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > .ran/ca.crt
kubectl config view --kubeconfig $KC --raw -o jsonpath='{.users[0].user.token}' > .ran/token
kubectl -n fct-dash create secret generic fct-dash-ran --from-file=.ran/server --from-file=.ran/token --from-file=.ran/ca.crt --dry-run=client -o yaml | kubectl apply -f -
rm -rf .ran
echo "== CORE 1b. Speed-test servers on the UPF host"
kubectl apply -f iperf-server.yaml
echo "== CORE 2. Dashboard code and Deployment (NodePort 30880)"
kubectl -n fct-dash create configmap fct-dash-app --from-file=app.py --from-file=index.html --dry-run=client -o yaml | kubectl apply -f -
HASH=$(cat app.py index.html | sha256sum | cut -c1-12)
sed "s/CODE_HASH/$HASH/" fct-dash.yaml | kubectl apply -f -
kubectl -n fct-dash rollout restart deploy/fct-dash >/dev/null
kubectl -n fct-dash rollout status deploy/fct-dash --timeout=180s
printf '.ran/\n' > .gitignore
git init -q 2>/dev/null || true
git add -A && git -c user.name="Redi" -c user.email="redi@fct-lab" commit -qm "fct-dash $HASH: D2-D6 + Uu events" || true
echo "== CORE 3. Self-test"
sleep 4
curl -s localhost:30880/api/state | python3 -c "import json,sys; d=json.load(sys.stdin); print('state errors:', d['errors'] or 'none', '| pods:', len(d['pods']))"
curl -s "localhost:30880/api/flow?after=0" | python3 -c "import json,sys; d=json.load(sys.stdin); print('flow:', d.get('error') or ('capture running=%s, messages=%d' % (d['status']['running'], len(d['messages']))))"
'''

script = f'''#!/usr/bin/env bash
# FCT 5G testbed dashboard installer v0.7.3 (D2-D6, Uu events, message flow oldest first, iperf3 watchdog v2).
# Run on REDLAB:  bash fct-dash-install.sh
set -euo pipefail
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ran" "$TMP/core"

{embed("capture.py")}{embed("n2-capture.yaml")}{embed("ran-control.yaml")}{embed("app.py")}{embed("index.html")}{embed("fct-dash.yaml")}{embed("iperf-server.yaml")}
mv "$TMP/capture.py" "$TMP/n2-capture.yaml" "$TMP/ran-control.yaml" "$TMP/ran/"
mv "$TMP/app.py" "$TMP/index.html" "$TMP/fct-dash.yaml" "$TMP/iperf-server.yaml" "$TMP/core/"

echo "### RAN side: FCT0173"
tar -C "$TMP/ran" -cz . | ssh fct0173 'mkdir -p ~/fct-dash && tar -C ~/fct-dash -xz'
ssh fct0173 'bash -s' <<'REMOTEEOF'
{ran_remote}REMOTEEOF

echo "### Controller token: RAN -> core secret"
sleep 2
ssh fct0173 "kubectl -n fct-dash get secret fct-dash-controller-token -o jsonpath='{{.data.token}}' | base64 -d" | \
  ssh fct0172 'umask 077; cat > /tmp/ctl-token && kubectl -n fct-dash create secret generic fct-dash-ctl --from-file=token=/tmp/ctl-token --dry-run=client -o yaml | kubectl apply -f - && rm -f /tmp/ctl-token'
if ! ssh fct0172 'kubectl -n fct-dash get secret fct-dash-admin >/dev/null 2>&1' || [ "${{RESET_ADMIN:-0}}" = 1 ]; then
  read -r -s -p "Choose the dashboard admin password: " PW; echo
  [ -n "$PW" ] || {{ echo "Empty password, stopping"; exit 1; }}
  printf '%s' "$PW" | ssh fct0172 'umask 077; cat > /tmp/adm && kubectl -n fct-dash create secret generic fct-dash-admin --from-file=password=/tmp/adm --dry-run=client -o yaml | kubectl apply -f - && rm -f /tmp/adm'
  unset PW
fi

echo "### Core side: FCT0172"
tar -C "$TMP/core" -cz . | ssh fct0172 'mkdir -p ~/fct-dash && tar -C ~/fct-dash -xz'
ssh fct0172 'bash -s' <<'REMOTEEOF'
{core_remote}REMOTEEOF
echo
echo "Open from REDLAB: http://10.0.129.2:30880"
'''
open("fct-dash-install.sh", "w").write(script)
print("built", len(script.splitlines()), "lines")
