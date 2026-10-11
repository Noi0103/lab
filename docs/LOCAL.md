# Local test cluster

Prod reconciles `master`, so a bad merge breaks the lab. Every change is
verified on a throwaway local cluster first, then diffed against prod, and only
then merged.

## Setup (once)

Tools come from the mac config (`home/lab.nix`): `limactl`, `kubectl`, `flux`,
`kustomize`, `kubeconform`, `sops`, plus the operator age key in
`~/.config/sops/age/keys.txt` (decrypts the same secrets prod uses).

For amd64-only images (e.g. `mokuro-bunko`), install Rosetta *before* the VM is
created: `softwareupdate --install-rosetta --agree-to-license`.

```sh
local/cluster.sh up        # VM + k3s + flux, then syncs the working tree (~10 min first time)
```

## Workflow

1. **Branch** — work on a feature branch / worktree, never on `master`.
2. **Static checks** — `local/cluster.sh check`: the CI checks
   (`kustomize build | kubeconform` per stage), an eval of every NixOS host, and
   `nix flake check`.
3. **Upgrade path** — `local/cluster.sh sync master` puts the local cluster in
   prod's current state first, so the next step tests the transition and not
   just a fresh install.
4. **Apply locally** — `local/cluster.sh sync`: pushes `cluster/` from the
   working tree (uncommitted changes included) and waits until every Flux
   Kustomization has applied that revision and every HelmRelease, Deployment,
   StatefulSet and DaemonSet is healthy. Non-zero exit with a report otherwise.
   Poke around with `local/cluster.sh kubectl|flux|k9s ...`.
5. **Diff against prod** — `local/cluster.sh diff`: read-only server-side dry
   run of the working tree against prod. It shows exactly what will change once
   merged.
6. **PR** — push the branch and open a PR; CI repeats the static checks.
7. **Merge and watch** — after merging, watch `flux get ks` / `flux get hr -A`
   on prod. Roll back with `git revert` + merge, never by editing the cluster.

`local/cluster.sh stop` keeps the VM for next time; `destroy` deletes it.

## How it maps to prod

| | prod | local |
|---|---|---|
| k3s | `services.k3s.package` from the flake | same version (read from the flake), same flags, embedded etcd |
| Nodes | 5 | 1, named `nix-optiplex2` (jellyfin's nodeSelector) |
| Flux | `fluxVersion` in `nix/modules/flux.nix` | same install.yaml, sha256 verified |
| Source | GitRepository `master` | OCIRepository from an in-cluster registry, pushed by `sync` |
| Stages | `nix/config/manifests/flux-sync.yaml` | same file, patched by `local/flux/` |
| `cluster-settings` | generated in `flux.nix` | same, but `NFS_HOST` = VM, `EXTERNAL_DOMAIN` = `lab.test` |
| NFS | `nix-optiplex1:/tank` | NFS server in the VM, same exports and NFS versions |
| Secrets | `sops-age` from `nix/secrets/sops-age.enc` | same secret |

## What is different on purpose

Everything that would touch something shared with prod is patched out in
`local/flux/patches/` (the only place for such overrides):

- **Tailscale**: operator, its OAuth secret, the ProxyGroup and `traefik-public`
  are removed; they would join the real tailnet.
- **cert-manager**: ClusterIssuers are self-signed and the Cloudflare token is
  removed, so no ACME requests or DNS-01 records.
- **gluetun**: scaled to 0 and its secret removed; a second peer with prod's
  Mullvad WireGuard key breaks prod's tunnel.

If you add something that talks to an external account with prod credentials,
add an override there in the same change.

## Not covered

- **NixOS host changes** are only evaluated (`check`), not booted. Deploy them
  with `nix/scripts/rebuild.sh <host>` one host at a time, the non-bootstrap
  hosts first.
- **MetalLB / public exposure**: the VM is behind NAT, so LoadBalancer IPs are
  assigned but unreachable; the edge relay path cannot be tested.
- Multi-node behaviour (scheduling across nodes, etcd quorum).
