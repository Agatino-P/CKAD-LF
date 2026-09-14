#!/usr/bin/env bash
# Creates the dedicated Docker network, the kind cluster and the add-ons, waiting until each is usable.
# Runs the same steps as README.md, in the same order. Safe to re-run: existing pieces are reused.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lab.env

# kind attaches nodes to the Docker network named "kind" and reuses that network as-is if it exists.
KIND_NETWORK=kind

k() { kubectl --context "kind-${CLUSTER_NAME}" "$@"; }

echo "==> 0/4 ckad-cluster.yaml matches lab.env"
scripts/generate-kind-config.sh --check

echo "==> 1/4 Docker network ${KIND_NETWORK} (${KIND_NETWORK_SUBNET})"
if docker network inspect "$KIND_NETWORK" >/dev/null 2>&1; then
  actual=$(docker network inspect "$KIND_NETWORK" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}')
  case " $actual " in
    *" ${KIND_NETWORK_SUBNET} "*) echo "exists with the expected subnet" ;;
    *) echo "network ${KIND_NETWORK} exists with subnet(s) '${actual}', expected ${KIND_NETWORK_SUBNET}." >&2
       echo "Delete every kind cluster using it (kind get clusters), then: docker network rm ${KIND_NETWORK}" >&2
       exit 1 ;;
  esac
else
  # Same options kind uses when it creates its own network: bridge driver, IP masquerade,
  # and the MTU of Docker's default bridge network.
  mtu=$(docker network inspect bridge --format '{{index .Options "com.docker.network.driver.mtu"}}' 2>/dev/null || true)
  [[ "$mtu" =~ ^[0-9]+$ ]] || mtu=""
  docker network create -d bridge \
    -o com.docker.network.bridge.enable_ip_masquerade=true \
    ${mtu:+-o com.docker.network.driver.mtu=${mtu}} \
    --subnet "$KIND_NETWORK_SUBNET" \
    "$KIND_NETWORK"
fi

echo "==> 2/4 kind cluster ${CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "exists"
else
  # The cluster name comes from ckad-cluster.yaml (name: CLUSTER_NAME).
  kind create cluster --config ckad-cluster.yaml
fi
kubectl config use-context "kind-${CLUSTER_NAME}"
k wait --for=condition=Ready nodes --all --timeout=180s

echo "==> 3/4 metrics-server"
k apply -k addons/metrics-server
k -n kube-system rollout status deployment/metrics-server --timeout=180s
k wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s

echo "==> 4/4 ingress-nginx"
k apply -k addons/ingress-nginx
k -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s
# The admission webhook can refuse connections for a moment after the controller is Ready;
# a server-side dry-run Ingress exercises the real request path.
for _ in $(seq 1 60); do
  if k create ingress webhook-probe --class=nginx --rule='/*=webhook-probe:80' \
       --dry-run=server -o name >/dev/null 2>&1; then
    webhook_ok=1; break
  fi
  sleep 1
done
[[ "${webhook_ok:-}" == 1 ]] || { echo "ingress-nginx admission webhook not accepting requests after 60 s" >&2; exit 1; }

echo
k get nodes -o wide
echo
echo "Ready. Context: kind-${CLUSTER_NAME}. Verify with scripts/check.sh"
