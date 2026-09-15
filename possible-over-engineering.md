# Possible over-engineering

Notes for a future decision, not a plan. Nothing here has been acted on.

Written 2026-09-15 against commit `d2ba5b1`, reading the whole repo. Line counts and file names
below describe that commit; re-read the files before acting on any of it.

## Why the lab is shaped this way

The lab replicates the Linux Foundation CKAD training environment, which runs on GCE, using local
Docker instead, to avoid paying for GCE. A second goal is being able to run every step by hand
rather than only through a script.

That rationale changes the verdict on some items below: fidelity to the training environment is a
real requirement, and a simplification that breaks fidelity is not a simplification. Each item is
marked with whether the LF-parity goal defends it.

## 1. The config templating layer — PARTLY ACTED ON 2026-09-15

Files: `ckad-cluster.template.yaml`, `lab.env`, `scripts/generate-kind-config.sh`, and the generated
`ckad-cluster.yaml`, which is itself committed.

Four files and a generator with a `--check` drift mode produce one static kind config. Six variables
are substituted. `CLUSTER_NAME`, `POD_SUBNET`, `SERVICE_SUBNET` and the two Ingress host ports are
values that do not change. `NODE_IMAGE` changes at most once per Kubernetes minor release, and
changing it means editing one line with or without the generator.

The template, the values and the output all live in git, so the single source of truth is three
sources that must agree. The `--check` mode in `scripts/generate-kind-config.sh` and the port-drift
WARNING in `scripts/check.sh` exist only to detect them disagreeing: both are complexity whose only
job is managing complexity introduced upstream of them.

Decided: `lab.env` stays as the one place holding every value, and one substitution pass is
acceptable; the logic wrapped around it was not. `scripts/generate-kind-config.sh` went from 51
lines to 18, losing the `--check` drift mode, the required-variable loop, the unfilled-placeholder
scan and the diff output. `scripts/up.sh` now regenerates the config before creating the cluster,
so the drift those checks looked for can no longer exist. The regenerated config was confirmed
byte-identical to the previous one apart from its header comment.

LF parity: does not defend this. The generator is a local convenience, not a property of the
training environment.

Counter-argument: the "run things manually" goal is mildly served by having values in one `lab.env`
rather than scattered through a YAML file.

## 2. Two worker nodes

Defined in `ckad-cluster.template.yaml`.

The CKAD curriculum covers Pods, Deployments, Services, ConfigMaps and Secrets, probes, Jobs and
CronJobs, and a basic understanding of NetworkPolicies. It does not test placing workloads on
particular nodes. Three node containers cost memory and cluster startup time for capability the
exam does not exercise.

The workers are also the sole cause of the ingress scheduling problem: with no worker present, the
controller cannot be scheduled away from the node the host ports reach. The `nodeSelector` patch in
`addons/ingress-nginx/kustomization.yaml` and the "Scheduling patch" note in `README.md` both exist
to handle a situation only the workers create. The README note says as much in its last sentence.

Possible cut: a single control-plane node. Keep the `nodeSelector` patch regardless, since it costs
nothing and keeps the node count free to change back.

LF parity: this is the item most likely to be defended by it. If the training environment is
multi-node, matching it is the point of the lab. Check what the LF environment actually provides
before cutting.

## 3. The dedicated Docker network with a pinned subnet

`KIND_NETWORK_SUBNET` in `lab.env`, the network creation block in `scripts/up.sh`, the network
removal in `scripts/down.sh`, and the node-address section of `scripts/check.sh`.

`scripts/up.sh` creates a bridge network with a pinned subnet, copies the MTU from Docker's default
bridge, and validates the subnet when the network already exists. Letting kind create its own
network would delete all of it.

LF parity: **defends this, and settles it.** The pinned subnet matches the training environment's
VPC subnet, which is the stated reason it exists. Keep it. This item is closed.

## 4. Cleanup machinery in scripts/check.sh — SUPERSEDED 2026-09-15

Roughly 35 of that script's 79 lines are namespace cleanup: `delete_test_namespaces` with a
180-second poll loop, an EXIT trap, a cleanup pass before the checks, a cleanup pass after them, and
exit-status juggling between the two.

What it guards against is a test namespace stuck Terminating. The recovery for that in a disposable
lab is `scripts/down.sh` followed by `scripts/up.sh`.

Overtaken by events: `scripts/check.sh` and `checks/` were deleted outright. The reasoning was that
the checks track the scripts, so changing a script means changing its check, and that maintenance
weight buys little once `scripts/up.sh` already waits for every component it installs. The one thing
the checks tested that nothing else does is host traffic reaching a pod through the port mapping;
the manual commands for that are gone from `README.md` too. Recover either from git history if the
lab ever needs a regression test again.

LF parity: does not defend this.

## 5. README.md restating scripts/up.sh — ACTED ON 2026-09-15

`scripts/up.sh` states the duplication in its own header comment: it runs the same steps as
`README.md`, in the same order. One procedure, two homes, and only one of them can drift.

Resolved the other way round, because running things by hand is a goal of the lab: the manual steps
in `README.md` are the reference, and the header of `scripts/up.sh` now points at them instead of
claiming to run the same steps in the same order.

LF parity: partially defends this. Written-out manual steps serve the goal of running things by
hand, which a script does not. If the steps stay, they are the home and the script's header should
point at them, rather than both claiming to be the reference.

## 6. The whole NetworkPolicy enforcement harness, not just its Calico fallback

Files: `checks/netpol/01-workloads.yaml`, `checks/netpol/02-deny-all.yaml`, the NetworkPolicy
section of `scripts/check.sh`, and the NetworkPolicy section of `README.md`.

Decided 2026-09-15: this is a one-off question about kind, not a recurring health check.

The question the harness answers is whether kindnet enforces NetworkPolicy at all. Older kindnet
versions accepted a NetworkPolicy object and silently ignored it, which matters because the CKAD
curriculum asks for a basic understanding of NetworkPolicies: against a non-enforcing CNI, a wrong
policy and a correct policy are indistinguishable, because traffic flows either way.

That question has exactly one answer per node image, and `NODE_IMAGE` in `lab.env` is pinned by
`@sha256` digest, so the CNI is frozen until that digest is bumped. Re-running the check on every
`scripts/check.sh` invocation re-derives an answer that cannot have changed.

`README.md` already asserts that kindnet enforces NetworkPolicy, in the add-ons section, with no
source. That sentence is the right home for the outcome.

Plan: run the check once, record the result in that existing `README.md` sentence together with the
node image digest it was verified against and the date, then delete both files under
`checks/netpol/`, the NetworkPolicy section of `scripts/check.sh`, and the NetworkPolicy section of
`README.md` including its Calico fallback paragraph.

Re-run condition: bumping `NODE_IMAGE`. Recovering the harness at that point is a `git show` away.

Knock-on effect: with `netpol-check` gone, `TEST_NAMESPACES` in `scripts/check.sh` holds a single
namespace, which further weakens the case for the cleanup machinery described in item 4.

LF parity: does not defend the harness. Whether kindnet enforces policy is a property of kind, not
of the training environment.

## What is not over-engineered

- Both kustomize patches. The `nodeSelector` patch in `addons/ingress-nginx/kustomization.yaml` and
  the `--kubelet-insecure-tls` patch in `addons/metrics-server/kustomization.yaml` each fix real
  breakage, are small, and carry comments explaining why.

- The vendored upstream manifests under `addons/*/upstream/`. Pinned and usable offline; fetching
  them at apply time would be worse in every way.

- `shell/ckad.bashrc` and `shell/vimrc`. The highest value per line in the repo, and directly
  useful during the exam.

- The three checks in `scripts/check.sh`, as opposed to its cleanup scaffolding.

- The admission-webhook probe loop in `scripts/up.sh`. It converts a real, documented race into a
  wait.

## Addendum: this machine runs podman, not Docker

Verified 2026-09-15 on the machine holding this clone, and **resolved the same day**: the scripts
now call `CONTAINER_ENGINE` from `lab.env`, and the cluster has been created and checked on podman.
This was a correctness problem, not an over-engineering one. It did not change the verdict on
item 3.

Findings, kept because they explain why the fix looks the way it does:

- There is no `docker` binary installed. `which -a docker` finds nothing. `podman` 6.1.1 is the
  only container engine, with a running `podman-machine-default` VM on the applehv backend.

- `KIND_EXPERIMENTAL_PROVIDER=podman` and `DOCKER_HOST` pointing at the podman socket are both
  already exported in the environment, so `kind` itself uses podman.

- `scripts/up.sh`, `scripts/down.sh` and `scripts/check.sh` all invoke `docker`. `scripts/up.sh`
  fails at step 1/4 and `scripts/check.sh` fails when it looks up the mapped host port.

- `podman network create -o com.docker.network.bridge.enable_ip_masquerade=true` is rejected:
  "unsupported bridge network option". Podman masquerades by default, so the option is not needed.

- Podman has no network named `bridge`; its default network is named `podman`. The MTU lookup in
  `scripts/up.sh` reads `docker network inspect bridge`, which finds nothing under podman. The
  existing guard degrades to an empty MTU rather than failing.

- `podman network create --subnet` and `-o mtu=` both work, so the pinned subnet from item 3
  survives in podman-native form.

Settled by running the lab rather than by reasoning about it, on 2026-09-15:

- kind's `extraPortMappings` do reach macOS through the podman machine VM. The Ingress smoke check
  in `scripts/check.sh` fetched the nginx welcome page over the mapped host port.

- Podman needed no further setup for kind beyond the `KIND_EXPERIMENTAL_PROVIDER` already exported
  in the shell environment. The cluster came up first try.

- Node IPs landed inside the pinned subnet, so the training-environment parity of item 3 survives
  the move to podman.

Several concerns raised while investigating turned out to cost nothing: the MTU of the bridge
network, IP masquerading, and whether the host port mappings would survive the VM. They are recorded
here as settled so that a future reader does not re-open them.
