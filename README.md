# CKAD-LF — local kind lab for CKAD practice

A disposable [kind](https://kind.sigs.k8s.io/) cluster on a laptop, for CKAD practice.

## Quick start

```bash
scripts/up.sh      # network + cluster + metrics-server + ingress-nginx
scripts/down.sh    # delete cluster and network
```

## Prerequisites

- A container runtime kind supports: Docker Desktop, OrbStack, Colima or Podman.
- kind, kubectl and envsubst: `brew install kind kubectl gettext` (envsubst ships with gettext).

Last tested 2026-09-15: kind v0.33.0, kubectl v1.37.0, podman 6.1.1, macOS arm64.

## Layout

```
lab.env                           every setting
ckad-cluster.template.yaml        kind cluster config structure, with ${VARIABLE} placeholders
ckad-cluster.yaml                 GENERATED kind cluster config (do not edit)
addons/
  ingress-nginx/                  Ingress controller: vendored upstream + kustomize patch
  metrics-server/                 kubectl top / HPA support: vendored upstream + kustomize patch
scripts/
  generate-kind-config.sh         lab.env + template -> ckad-cluster.yaml
  up.sh, down.sh                  create and delete the lab
```

## Settings

Every value lives in `lab.env`, commented; its header says how to apply a change.

Before bumping `NODE_IMAGE`, check which version the exam runs: the [CKAD page](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
states "The exam is based on Kubernetes vX.Y" and [cncf/curriculum](https://github.com/cncf/curriculum)
holds `CKAD_Curriculum_vX.Y.pdf`.

## Manual steps

Load the settings first (bash):

```bash
source lab.env
```

### 1. Container network `kind` with the node subnet

```bash
"$CONTAINER_ENGINE" network create -d bridge --subnet "$KIND_NETWORK_SUBNET" kind
```

kind reuses an existing network named `kind` as-is, so creating it first is how the node subnet is
chosen.

### 2. Create the cluster

Check the host ports are free first:
`lsof -nP -iTCP:"$INGRESS_HTTP_HOST_PORT" -sTCP:LISTEN` (no output = free).

```bash
kind create cluster --config ckad-cluster.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

### 3. metrics-server

```bash
kubectl apply -k addons/metrics-server
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
kubectl top nodes
```

### 4. Ingress controller (ingress-nginx)

```bash
kubectl apply -k addons/ingress-nginx
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

# The admission webhook refuses connections for a moment after the controller is Ready.
until kubectl create ingress webhook-probe --class=nginx --rule='/*=webhook-probe:80' \
    --dry-run=server -o name >/dev/null 2>&1; do sleep 1; done
```

## Teardown

```bash
kind delete cluster --name "$CLUSTER_NAME"
"$CONTAINER_ENGINE" network rm kind
```
