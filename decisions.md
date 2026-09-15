# Decisions behind the shape of this lab

Why things are the way they are. What was changed is in `git log`; this file holds only the
reasoning that would otherwise be lost.

## The goal

The lab replicates the Linux Foundation CKAD training environment, which runs on GCE, using local
containers, to avoid paying for GCE. A second goal is running every step by hand rather than only
through a script.

Fidelity to the training environment therefore outranks smallness: a simplification that breaks
parity is not a simplification.

## Settled

- **`lab.env` holds every value, `ckad-cluster.template.yaml` holds structure.** One substitution
  pass, no drift checking: `scripts/up.sh` regenerates the config before creating the cluster, so
  the generated file cannot disagree with its inputs.

- **One control-plane node and one worker.** Matches the two-VM LFD259 lab. A worker has to exist
  for the `nodeSelector` patch in `addons/ingress-nginx/kustomization.yaml` to be doing anything,
  so a control-plane-only cluster was rejected.

- **`KIND_NETWORK_SUBNET` is pinned** because it matches the training environment's VPC subnet.
  This is the one address range in the lab chosen deliberately; kind's own defaults are left alone.

- **`README.md` is the reference procedure**, not `scripts/up.sh`. Running steps by hand is a goal,
  so the script's header points at the README rather than both claiming to be the source.

- **No automated checks.** A check tracks the script it checks, and `scripts/up.sh` already waits
  for every component it installs. `git show 79fd614^` recovers the deleted harness.

## Re-run condition

Bumping `NODE_IMAGE` re-opens one question: whether that image's kindnet enforces NetworkPolicy.
Older kindnet accepted a NetworkPolicy object and silently ignored it, which matters because a
wrong policy and a correct policy are indistinguishable against a non-enforcing CNI. The answer is
fixed per image, and `NODE_IMAGE` is pinned by `@sha256` digest. `git show 21e4eeb^` recovers the
test that answers it.

## Deliberately kept

- Both kustomize patches. Each fixes real breakage and carries a comment saying which.
- The vendored upstream manifests under `addons/*/upstream/`. Pinned and usable offline.
- The admission-webhook probe loop in `scripts/up.sh`. Converts a documented race into a wait.

## Podman

This machine has no `docker` binary; `kind` runs on podman via `KIND_EXPERIMENTAL_PROVIDER`, and the
scripts follow it through `CONTAINER_ENGINE` in `lab.env`. Three podman differences shape that code:

- `-o com.docker.network.bridge.enable_ip_masquerade=true` is rejected as an unsupported bridge
  option. Podman masquerades by default, so it is not needed.
- Podman's default network is named `podman`, not `bridge`, so an MTU lookup against `bridge` finds
  nothing.
- `--subnet` and `-o mtu=` both work, so the pinned subnet survives.

Settled by running the lab, not by reasoning: the host port mappings reach macOS through the podman
machine VM, and node IPs land inside the pinned subnet.
