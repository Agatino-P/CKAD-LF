# CKAD-LF — local kind lab for CKAD practice

A disposable Kubernetes cluster on a laptop, built with [kind](https://kind.sigs.k8s.io/) (Kubernetes
in Docker), for Certified Kubernetes Application Developer (CKAD) practice. No cloud account needed.
Clusters are cheap to destroy and recreate, which is the point.

## Quick start

```bash
scripts/up.sh      # network + cluster + metrics-server + ingress-nginx
scripts/check.sh   # node subnet, metrics, Ingress end to end, NetworkPolicy enforcement
scripts/down.sh    # delete cluster and network
```

Every setting lives in `lab.env`. The scripts run exactly the steps documented below.

## Prerequisites

- A container runtime kind supports: Docker Desktop, OrbStack, Colima or Podman.
- kind, kubectl and envsubst: `brew install kind kubectl gettext` (envsubst ships with gettext).

Last tested 2026-09-15 with kind v0.33.0, kubectl v1.37.0 and podman 6.1.1 on macOS (arm64),
creating the cluster and passing `scripts/check.sh`.

The scripts call whichever engine kind uses, resolved once as `CONTAINER_ENGINE` in `lab.env`, so
they work on podman without a `docker` binary installed.

## Layout

```
lab.env                           every setting: the single place to change values
ckad-cluster.template.yaml        kind cluster config structure, with ${VARIABLE} placeholders
ckad-cluster.yaml                 GENERATED kind cluster config (do not edit)
addons/
  ingress-nginx/                  Ingress controller: vendored upstream + kustomize patch
  metrics-server/                 kubectl top / HPA support: vendored upstream + kustomize patch
checks/
  ingress-smoke.yaml              Ingress end-to-end check
  netpol/                         NetworkPolicy enforcement check (two steps)
scripts/
  generate-kind-config.sh         lab.env + template -> ckad-cluster.yaml (--check: verify only)
  up.sh, check.sh, down.sh        create, verify, delete the lab
shell/                            bash shortcuts and vim settings for exam speed
```

Upstream manifests under `addons/*/upstream/` are unmodified copies; every change lives in the
`kustomization.yaml` next to them, with the reason.

## Settings

All values live in `lab.env`, each with a comment explaining the choice.

| Variable | Controls |
|---|---|
| `CLUSTER_NAME` | kind cluster name; kubectl context `kind-<CLUSTER_NAME>` |
| `KIND_NETWORK_SUBNET` | subnet of the Docker network `kind`, i.e. the node IPs |
| `NODE_IMAGE` | image of every node, i.e. the Kubernetes version |
| `POD_SUBNET`, `SERVICE_SUBNET` | pod and Service IP ranges |
| `INGRESS_HTTP_HOST_PORT`, `INGRESS_HTTPS_HOST_PORT` | host ports leading to the Ingress controller (control-plane ports 80/443) |

Changing a value:

```bash
vim lab.env
scripts/generate-kind-config.sh     # regenerates ckad-cluster.yaml
scripts/down.sh && scripts/up.sh    # every value only takes effect at creation
```

Why a generated file: kind reads its config file literally and does not expand variables, so
`scripts/generate-kind-config.sh` fills `ckad-cluster.template.yaml` with the values from `lab.env`
and writes `ckad-cluster.yaml`. The generated file is committed, so `kind create cluster --config
ckad-cluster.yaml` works without the script. `scripts/up.sh` runs `generate-kind-config.sh --check`
first and stops if `ckad-cluster.yaml` does not match `lab.env`.

### Kubernetes version

`NODE_IMAGE` is pinned to the Kubernetes minor version the CKAD exam runs.

- On 2026-09-14 the exam was on **v1.35**, although upstream had already released v1.36 and v1.37.
- Check before an exam: the [CKAD page](https://training.linuxfoundation.org/certification/certified-kubernetes-application-developer-ckad/)
  states "The exam is based on Kubernetes vX.Y", and the [cncf/curriculum](https://github.com/cncf/curriculum)
  repo holds `CKAD_Curriculum_vX.Y.pdf`.
- To change version, take the `kindest/node` image **with its `@sha256` digest** from the release
  notes of the installed kind version (`kind version`). kind's release notes say a bare tag is not
  guaranteed to match the release.
- kind has no cluster-wide image field, so the template repeats `${NODE_IMAGE}` on every node.
- `kind create cluster --image <image>` overrides the image on every node, handy for a one-off try.

kubectl works against API servers one minor version older or newer than kubectl itself.

## Manual steps

The commands below read the settings from the shell, so load them first (bash):

```bash
source lab.env
```

## 1. Docker network `kind` with the node subnet

```bash
MTU=$(docker network inspect bridge --format '{{index .Options "com.docker.network.driver.mtu"}}')
docker network create -d bridge \
  -o com.docker.network.bridge.enable_ip_masquerade=true \
  -o com.docker.network.driver.mtu="$MTU" \
  --subnet "$KIND_NETWORK_SUBNET" \
  kind
```

(If `MTU` comes back empty, drop the `mtu` option line.)

How kind picks node networking:

- kind attaches every node of every cluster to the Docker network named `kind`. If the network
  does not exist, kind creates it with a subnet Docker picks; if it exists, kind uses it as-is. So
  creating the network before the cluster is how the node subnet is chosen.
- The options above are the ones kind itself uses when creating the network (bridge driver, IP
  masquerade, MTU of Docker's default bridge network), plus the subnet. kind also adds an IPv6
  subnet; that only matters for `ipFamily: ipv6` or `dual` clusters, and this cluster is IPv4.
- If `kind` already exists with a different subnet, delete every kind cluster using it
  (`kind get clusters`) and `docker network rm kind` first; `scripts/up.sh` stops with that message.
- Docker assigns node IPs from the subnet; kind has no per-node IP setting. Nodes start in
  parallel, so which node gets which address varies between clusters.
- On Docker Desktop, node IPs are not reachable from the Mac; traffic enters through the port
  mappings in the kind config.
- The subnet must not overlap other Docker networks (`docker network create` refuses with a pool
  overlap error) or the pod and Service ranges.

## 2. Create the cluster

```bash
kind create cluster --config ckad-cluster.yaml
kubectl wait --for=condition=Ready nodes --all --timeout=180s
```

`ckad-cluster.yaml` (generated from the template) defines:

- the cluster name `CLUSTER_NAME`; `--name` or an exported `KIND_CLUSTER_NAME` would override it;
- one control-plane node and two worker nodes, all on `NODE_IMAGE`;
- label `ingress-ready=true` on the control-plane node, plus host ports `INGRESS_HTTP_HOST_PORT` → 80
  and `INGRESS_HTTPS_HOST_PORT` → 443 into the control-plane container, so an Ingress controller
  running there answers on `http://localhost:$INGRESS_HTTP_HOST_PORT`;
- pod range `POD_SUBNET` and Service range `SERVICE_SUBNET`.

About the host ports:

- High ports avoid clashing with web servers and dev tools already bound to 80/443. Good choices are
  unassigned in the [IANA port registry](https://www.iana.org/assignments/service-names-port-numbers/)
  and outside the Kubernetes NodePort range (30000–32767) and the macOS ephemeral port range
  (49152–65535).
- Check a port is free before creating the cluster:
  `lsof -nP -iTCP:"$INGRESS_HTTP_HOST_PORT" -sTCP:LISTEN` (no output = free).
- Docker binds the ports on all host interfaces (`0.0.0.0`), so the host's LAN address answers too.
  Adding `listenAddress: "127.0.0.1"` to each mapping in the template restricts them to loopback.
- `scripts/check.sh` reads the port the running cluster actually maps from Docker, and warns when it
  differs from `lab.env` (a cluster created before the value changed).

Included by kind without extra setup: the kindnet CNI (enforces NetworkPolicy; see checks) and the
`standard` StorageClass (Rancher local-path provisioner), so PVC exercises work immediately.

## 3. metrics-server

```bash
kubectl apply -k addons/metrics-server
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=180s
kubectl top nodes
```

The kustomization adds `--kubelet-insecure-tls`; without the flag metrics-server fails TLS
verification against kind's kubelets.

## 4. Ingress controller (ingress-nginx)

```bash
kubectl apply -k addons/ingress-nginx
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s

# Wait until the admission webhook accepts requests (see "Webhook refused" below).
until kubectl create ingress webhook-probe --class=nginx --rule='/*=webhook-probe:80' \
    --dry-run=server -o name >/dev/null 2>&1; do sleep 1; done
```

Notes:

- **Retired project.** ingress-nginx was archived in March 2026; `controller-v1.15.1` is its last
  release and receives no fixes. The CKAD curriculum tests Ingress *objects* ("Use Ingress rules to
  expose applications"), which any controller serves. Actively maintained alternative:
  [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind), which implements
  Ingress, Gateway API and LoadBalancer, but on macOS must run as a separate `sudo` process and
  exposes services on ephemeral localhost ports.
- **Scheduling patch.** Host traffic reaches the cluster in two hops that must meet on the same
  node. Hop 1 is Docker: `extraPortMappings` in `ckad-cluster.yaml` publishes
  `$INGRESS_HTTP_HOST_PORT`/`$INGRESS_HTTPS_HOST_PORT` to ports 80/443 of the *control-plane
  container only*. Hop 2 is the controller pod, which listens with `hostPort: 80/443` on *whichever
  node it is scheduled on*; no Service is involved. Upstream's kind manifest selects only
  `kubernetes.io/os=linux` and merely *tolerates* the control-plane taint, so with worker nodes
  present the scheduler may place the controller on a worker. Docker then forwards the request to the
  control-plane container, where nothing listens on port 80, and
  `curl http://localhost:$INGRESS_HTTP_HOST_PORT` gets "Empty reply from server" even though the pod
  is Running and Ready. The kustomization adds `nodeSelector: ingress-ready=true`, the label the kind
  config puts on the control-plane node, so both hops land on the same container. On a single-node
  cluster the problem cannot occur.
- **Webhook refused.** Creating an Ingress within a second or two of the controller becoming Ready
  can fail with `failed calling webhook "validate.nginx.ingress.kubernetes.io" ... connection
  refused`. The same error is returned whenever the admission Service has no ready endpoint; the
  exact cause of the post-Ready window was not proven. The dry-run loop above waits it out.
- **Service stays `<pending>`.** `ingress-nginx-controller` is a LoadBalancer Service and kind has no
  cloud provider, so `EXTERNAL-IP` stays `<pending>`. Harmless: traffic arrives through the host
  port on the control-plane node.
- **A new Ingress takes a few seconds.** After an Ingress is created the controller reloads nginx
  (about 3 s in testing); until then the Ingress URL answers 404. The `ADDRESS` column fills in later
  still (about 25 s), so it is not a readiness signal.

## 5. Checks

`scripts/check.sh` runs all of these and exits non-zero on the first failure. The script works only
in the namespaces `ingress-smoke` and `netpol-check`: it deletes both before starting (leftovers of an
earlier run), and on exit, pass or fail, deletes both again and waits until they are gone (up to
180 s; a cleanup that does not finish also makes the script exit non-zero). Running it on a cluster
in use is safe as long as nothing else lives in those two namespaces.

### Node subnet

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address'
docker network inspect kind --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}'   # expect KIND_NETWORK_SUBNET
```

### Ingress

```bash
kubectl apply -f checks/ingress-smoke.yaml
kubectl -n ingress-smoke rollout status deployment/echo --timeout=120s
until curl -fsS -o /dev/null "http://localhost:$INGRESS_HTTP_HOST_PORT/"; do sleep 1; done
curl -s "http://localhost:$INGRESS_HTTP_HOST_PORT/" | grep '<title>'   # <title>Welcome to nginx!</title>
kubectl delete namespace ingress-smoke
```

### NetworkPolicy enforcement

Older kindnet versions did not enforce NetworkPolicy, so verify before trusting policy exercises.

```bash
kubectl apply -f checks/netpol/01-workloads.yaml
kubectl -n netpol-check wait --for=condition=Ready pod/web pod/client --timeout=120s
kubectl -n netpol-check exec client -- wget -qO- -T 3 http://web    # expect: nginx HTML

kubectl apply -f checks/netpol/02-deny-all.yaml
kubectl -n netpol-check exec client -- wget -qO- -T 3 http://web    # expect: fails after ~3 s

kubectl delete namespace netpol-check
```

If the second `wget` still returns HTML, the CNI is not enforcing policies: add
`disableDefaultCNI: true` under `networking` in `ckad-cluster.template.yaml`, regenerate, recreate the
cluster and install Calico.

## Teardown

```bash
kind delete cluster --name "$CLUSTER_NAME"
docker network rm kind
```

`kind delete cluster` removes the `kind-<CLUSTER_NAME>` kubeconfig entries and the node containers
with their volumes, but not the network. The network `kind` is shared by all kind clusters;
`docker network rm` refuses while any container is still attached. Everything removed is recreated
by the steps above.

## Exam-speed shell

The exam terminal is bash with vim.

```bash
source shell/ckad.bashrc      # alias k, completion for k, $do and $now shortcuts
vim -u shell/vimrc pod.yaml   # 2-space YAML indentation, line numbers
```

To make the settings permanent, copy the lines from `shell/ckad.bashrc` into `~/.bashrc` and from
`shell/vimrc` into `~/.vimrc`.
