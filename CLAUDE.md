# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Homelab running on mostly second-hand hardware. Two halves live in this repo:

- `nix/` — NixOS flake defining every host (k3s nodes, NFS server, public VPS edge relay).
- `cluster/` — Kubernetes manifests reconciled by Flux from the `master` branch of `github.com/nsc99/lab`. Merging to `master` deploys.

## Commits

- Do **not** add `Co-Authored-By` trailers (or any other AI attribution) to commits or PRs.
- Conventional commits with a scope, e.g. `feat(nix): ...`, `fix(cluster): ...`, `chore(deps): ...`.

## Commands

All Nix commands run from `nix/` (the flake lives there).

```sh
cd nix
nix develop                                 # dev shell: nixfmt, nil, nixd + installs pre-commit hooks
nix flake check                             # runs pre-commit checks (nixfmt, deadnix, gitleaks)
nix build .#nixosConfigurations.<host>.config.system.build.toplevel   # evaluate/build a host locally
./scripts/rebuild.sh <host>                 # deploy: builds and switches on operator@<host>.lab over SSH
```

Merging to `master` deploys to prod. Verify every change on the local test cluster first; see `docs/LOCAL.md`:

```sh
local/cluster.sh up            # once: lima VM with prod's k3s + flux
local/cluster.sh check         # CI checks + eval of all hosts + flake check
local/cluster.sh sync master   # start from prod's current state
local/cluster.sh sync          # apply working tree, wait until healthy (exit 1 + report if not)
local/cluster.sh diff          # read-only diff of the working tree against prod
local/cluster.sh kubectl ...   # inspect / poke the local cluster
```

## Working on this repo (for Claude)

- Never mutate the prod cluster. Against prod only read-only commands (`get`, `describe`, `logs`, `flux get`, `local/cluster.sh diff`). Mutating `kubectl`/`helm`/`flux` commands are denied in `.claude/settings.json`; go through `local/cluster.sh`, which only ever uses the local kubeconfig.
- Work on a feature branch or worktree, never on `master`.
- A cluster change is done when `check` passes, `sync master` then `sync` exits 0, and `diff` shows only the intended changes. Report the diff in the PR.
- Local-only overrides live in `local/flux/patches/` and nowhere else. A new component that uses prod credentials against an external service (tailnet, VPN, ACME/DNS) needs an override there.
- NixOS changes can only be evaluated locally. Deploying hosts (`rebuild.sh`) and pushing/merging are left to the user.

## NixOS architecture

- `nix/cluster.nix` is the single source of truth for host IPs, the NFS host, the k3s bootstrap server, ingress IP and domains. It is passed to every module as the `cluster` specialArg.
- `flake.nix` builds each host with `mkHost "<name>"`, which imports `hosts/<name>/` plus sops-nix and disko. Adding a host means: a `hosts/<name>/` dir, an entry in `nixosConfigurations`, an IP in `cluster.nix`, and its age key in `.sops.yaml`.
- Hosts are composed purely by importing modules from `nix/modules/`. Roles: `k3s-server.nix` / `k3s-agent.nix`; exactly one server sets `lab.k3s.clusterInit = true` (must match `cluster.serverHost`, currently `nix-letsnote1`), the others join it.
- `modules/flux.nix` (only on the bootstrap server) bootstraps Flux by dropping manifests into k3s's auto-deploy dir: the sops age key secret, the Flux install manifest, `config/manifests/flux-sync.yaml`, and a generated `cluster-settings` ConfigMap derived from `cluster.nix`. Bumping Flux means updating `fluxVersion` and its `sha256` there.
- Disk layouts are declared with disko in `nix/disko/` (`tank.nix` = ZFS mirror on the NFS host).

## Cluster (Flux) architecture

Three Flux Kustomizations defined in `nix/config/manifests/flux-sync.yaml`, applied in order via `dependsOn`:

1. `cluster/infra/controllers` — HelmRepository + HelmRelease per controller (cert-manager, metallb, csi-driver-nfs, tailscale operator, kube-prometheus-stack, cloudnative-pg).
2. `cluster/infra/configs` — CRs/config that need those controllers (ClusterIssuers, IP pools, StorageClass, traefik HelmChartConfig, tailscale ProxyGroup, CNPG Postgres cluster).
3. `cluster/apps` — workloads.

Each directory has a `kustomization.yaml`; a new component must be added to its parent's `resources` list or Flux will ignore it.

Conventions:
- **Variable substitution**: `infra-configs` and `apps` use `postBuild.substituteFrom` on the `cluster-settings` ConfigMap, so manifests use `${NFS_HOST}`, `${INGRESS_IP}`, `${EXTERNAL_DOMAIN}`. New variables must be added in `nix/modules/flux.nix` (and `cluster.nix`). Literal `${...}` meant for the target (e.g. CSI `subDir`) must be escaped as `$${...}`. `infra-controllers` does *not* get substitution.
- **Helm apps**: `repository.yaml` (HelmRepository) + `release.yaml` (HelmRelease) in the app's namespace. Plain apps use deployment/service/ingress/pvc files.
- **Ingress**: traefik (k3s built-in, servicelb disabled; LoadBalancer IP from MetalLB). TLS via cert-manager annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` with hosts `<name>.${EXTERNAL_DOMAIN}`.
- **Public exposure**: only routes that add the `public` entrypoint (`traefik.ingress.kubernetes.io/router.entrypoints: websecure,public`) are reachable from the internet. Path: VPS `nix-netcup-chiller` (HAProxy SNI passthrough in `modules/edge-relay.nix`) → Tailscale → `traefik-public` service → traefik `public` entrypoint (PROXY protocol). Everything else is LAN/tailnet only.
- **Storage**: dynamic PVCs via StorageClass `nfs-tank` (NFS on `/tank/k8s`); pre-existing data (e.g. `/tank/media`) is mounted with static PV/PVC pairs using `claimRef`/`volumeName`.
- ServiceMonitors need label `release: observability` to be scraped.
- **PostgreSQL**: one shared CNPG `Cluster` `postgres` in `cluster/infra/configs/postgres/` (2 instances on local-path, nix-optiplex1/2). Apps connect to `postgres-rw.postgres.svc.cluster.local:5432`; a new app gets a role in `managed.roles` (basic-auth Secret `postgres-<app>` in ns `postgres`, copy the password into the app's namespace) plus `Database` CRs. CronJob `postgres-backup` writes nightly `pg_dump -Fc` per DB to PVC `postgres-backups` (nfs-tank, 14 days); add new DBs to its script.

## Secrets (SOPS + age)

- Rules in `.sops.yaml`. Host secrets live in `nix/secrets/` and are encrypted per-host to that host's age key (derived from its SSH host key) plus the `operator` key; consumed via `sops.secrets.*` in modules.
- Kubernetes secrets: any YAML under `cluster/` encrypts only `data`/`stringData` with the operator key. Write the Secret in plaintext, then `sops -e -i cluster/path/to/secret.yaml` before committing (see `docs/SOPS.md`). Never commit an unencrypted secret; gitleaks runs as a pre-commit hook.
- Flux decrypts using the `sops-age` secret, which `nix/secrets/sops-age.enc` provisions on server nodes.

## CI

`.github/workflows/ci.yaml` runs on GitHub-hosted runners on pushes to `master` and on PRs. Jobs: `nix flake check`, and `kustomize build | kubeconform` for each Flux stage, using tools pinned by `nix/flake.lock`.

## Dependency updates

Renovate (`renovate.json`) manages Helm charts, images, flake inputs and anything annotated with a `# renovate: datasource=... depName=...` comment on the line above a version. Patch/digest and nix lock updates automerge; nixpkgs channel bumps, majors, and home-assistant chart bumps need manual review.

## Shared brain

Multi-agent knowledge shared across `~/repos`; rules in `~/repos/brain/RULES.md`.

@~/repos/brain/RULES.md
@~/repos/brain/INDEX.md
