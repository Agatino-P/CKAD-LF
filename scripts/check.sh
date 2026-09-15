#!/usr/bin/env bash
# Verifies the lab: node subnet, metrics, Ingress end to end, NetworkPolicy enforcement.
# Applies the manifests under checks/ into the test namespaces below, and on exit (pass or fail)
# deletes those namespaces and waits until they are gone. Nothing else in the cluster is touched.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lab.env

TEST_NAMESPACES=(ingress-smoke netpol-check)
CLEANUP_TIMEOUT_SECONDS=180

k() { kubectl --context "kind-${CLUSTER_NAME}" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Deletes the test namespaces and waits until none of them exists. Returns non-zero on timeout.
delete_test_namespaces() {
  k delete namespace "${TEST_NAMESPACES[@]}" --ignore-not-found --wait=false >/dev/null
  for _ in $(seq 1 "$CLEANUP_TIMEOUT_SECONDS"); do
    [[ -z "$(k get namespace "${TEST_NAMESPACES[@]}" --ignore-not-found -o name)" ]] && return 0
    sleep 1
  done
  echo "still present after ${CLEANUP_TIMEOUT_SECONDS} s:" >&2
  k get namespace "${TEST_NAMESPACES[@]}" --ignore-not-found >&2
  return 1
}

on_exit() {
  local status=$?
  echo
  echo "==> cleanup: deleting ${TEST_NAMESPACES[*]}"
  if delete_test_namespaces; then
    echo "test namespaces removed"
  else
    echo "FAIL: cleanup did not finish" >&2
    status=1
  fi
  [[ "$status" == 0 ]] && echo "All checks passed."
  exit "$status"
}

echo "==> removing test namespaces left by an earlier run"
delete_test_namespaces || fail "could not remove test namespaces from an earlier run"
trap on_exit EXIT

echo "==> node addresses (expected inside ${KIND_NETWORK_SUBNET})"
k get nodes -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address'

echo "==> metrics"
k top nodes || fail "kubectl top nodes"

# Host port that Docker maps to the control-plane node's port 80 (extraPortMappings in ckad-cluster.yaml).
http_port=$(docker port "${CLUSTER_NAME}-control-plane" 80/tcp | sed -n '1s/.*://p')
[[ -n "$http_port" ]] || fail "no host port mapped to ${CLUSTER_NAME}-control-plane:80"
if [[ "$http_port" != "$INGRESS_HTTP_HOST_PORT" ]]; then
  echo "WARNING: the cluster maps host port ${http_port}, lab.env says ${INGRESS_HTTP_HOST_PORT};" \
       "recreate the cluster (scripts/down.sh, scripts/up.sh) to apply lab.env" >&2
fi
ingress_url="http://localhost:${http_port}/"

echo "==> Ingress via ${ingress_url}"
k apply -f checks/ingress-smoke.yaml
k -n ingress-smoke rollout status deployment/echo --timeout=120s
for _ in $(seq 1 60); do
  curl -fsS -o /dev/null "$ingress_url" 2>/dev/null && ingress_ok=1 && break
  sleep 1
done
[[ "${ingress_ok:-}" == 1 ]] || fail "${ingress_url} did not return 2xx within 60 s"
curl -s "$ingress_url" | grep -o '<title>.*</title>'

echo "==> NetworkPolicy enforcement"
k apply -f checks/netpol/01-workloads.yaml
k -n netpol-check wait --for=condition=Ready pod/web pod/client --timeout=120s
k -n netpol-check exec client -- wget -qO- -T 3 http://web >/dev/null || fail "web unreachable before any policy"
echo "before deny-all: reachable"
k apply -f checks/netpol/02-deny-all.yaml
if k -n netpol-check exec client -- wget -qO- -T 3 http://web >/dev/null 2>&1; then
  fail "web still reachable after deny-all: the CNI does not enforce NetworkPolicy"
fi
echo "after deny-all: blocked"
