#!/usr/bin/env bash
# Deletes the kind cluster (node containers + kubeconfig entries) and the container network "kind".
# Everything deleted here is recreated by scripts/up.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./lab.env

KIND_NETWORK=kind

# Removes the kubeconfig entries and the node containers with their volumes; not the network.
kind delete cluster --name "$CLUSTER_NAME"

if "$CONTAINER_ENGINE" network inspect "$KIND_NETWORK" >/dev/null 2>&1; then
  # All kind clusters share this network. The engine refuses (and leaves the network in place)
  # while any container, such as another kind cluster's node, is still attached.
  "$CONTAINER_ENGINE" network rm "$KIND_NETWORK"
fi
