#!/usr/bin/env bash
# Local test cluster for cluster/ (and nix/config/manifests) changes.
# See docs/LOCAL.md for the workflow; `local/cluster.sh help` for commands.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VM=lab-local
STATE="$ROOT/local/.state"
REGISTRY=127.0.0.1:5050
TIMEOUT=${LOCAL_TIMEOUT:-900}

# Prod is only ever read (diff); everything else goes to the local kubeconfig.
# Pinned to the sops-managed prod kubeconfig, not the current context.
PROD_KUBECONFIG=${LAB_PROD_KUBECONFIG:-$HOME/.kube/lab}
# Where the lab-local context is registered for kubecm/kubectx.
KUBECM_CONFIG=${KUBECM_CONFIG:-$HOME/.kube/config}
export KUBECONFIG="$STATE/kubeconfig"

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  local t missing=()
  for t in "$@"; do command -v "$t" >/dev/null || missing+=("$t"); done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (see docs/LOCAL.md)"
}

nix_eval() { nix eval --raw "$ROOT/nix#nixosConfigurations.$1"; }

vm_status() { limactl list --format '{{.Status}}' "$VM" 2>/dev/null || true; }

require_cluster() {
  [[ $(vm_status) == Running && -s $KUBECONFIG ]] || die "local cluster is not running, run: local/cluster.sh up"
}

cmd_up() {
  need limactl kubectl flux sops jq curl shasum nix
  mkdir -p "$STATE"

  case $(vm_status) in
    Running) ;;
    "")
      local k3s_version args=()
      k3s_version=$(nix_eval nix-letsnote1.config.services.k3s.package.version)
      log "creating VM $VM (k3s v$k3s_version, as in prod)"
      if [[ -e /Library/Apple/usr/libexec/oah/libRosettaRuntime ]]; then
        args+=(--set '.vmOpts.vz.rosetta.enabled=true | .vmOpts.vz.rosetta.binfmt=true')
      else
        log "Rosetta not installed: amd64-only images (mokuro-bunko) will not start."
        log "Install with: softwareupdate --install-rosetta --agree-to-license"
      fi
      limactl start --tty=false --name "$VM" \
        --param k3sVersion="v$k3s_version" "${args[@]}" "$ROOT/local/lima.yaml"
      ;;
    *)
      log "starting VM $VM"
      limactl start --tty=false "$VM"
      ;;
  esac

  (umask 077 && sed 's/: default$/: lab-local/' \
    "$(limactl list --format '{{.Dir}}' "$VM")/copied-from-guest/kubeconfig.yaml" >"$KUBECONFIG")
  chmod 600 "$KUBECONFIG"
  register_context
  kubectl wait --for=condition=Ready node --all --timeout=300s >/dev/null

  bootstrap
  cmd_sync "$@"
}

# Replaces the lab-local context in $KUBECM_CONFIG (certs change on recreate).
register_context() {
  local tmp
  unregister_context
  tmp=$(mktemp "$KUBECM_CONFIG.XXXXXX")
  KUBECONFIG="$KUBECM_CONFIG:$KUBECONFIG" kubectl config view --flatten >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$KUBECM_CONFIG"
  log "context lab-local registered in $KUBECM_CONFIG (kubecm switch lab-local)"
}

unregister_context() {
  local k
  [[ -f $KUBECM_CONFIG ]] || return 0
  if [[ $(KUBECONFIG=$KUBECM_CONFIG kubectl config current-context 2>/dev/null) == lab-local ]]; then
    KUBECONFIG=$KUBECM_CONFIG kubectl config unset current-context >/dev/null
  fi
  for k in context cluster user; do
    KUBECONFIG=$KUBECM_CONFIG kubectl config "delete-$k" lab-local >/dev/null 2>&1 || true
  done
}

# Same pieces nix/modules/flux.nix drops into k3s's manifests dir on prod.
bootstrap() {
  local flux_nix="$ROOT/nix/modules/flux.nix" version sha manifest
  version=$(sed -n 's/^ *fluxVersion = "\(.*\)";/\1/p' "$flux_nix")
  sha=$(sed -n 's/^ *sha256 = "sha256:\([0-9a-f]*\)";/\1/p' "$flux_nix")
  manifest="$STATE/flux-install-$version.yaml"
  if [[ ! -s $manifest ]]; then
    curl -fsSL -o "$manifest.tmp" "https://github.com/fluxcd/flux2/releases/download/v$version/install.yaml"
    echo "$sha  $manifest.tmp" | shasum -a 256 -c --quiet || die "flux install.yaml does not match flux.nix sha256"
    mv "$manifest.tmp" "$manifest"
  fi
  log "installing flux v$version"
  kubectl apply --server-side --force-conflicts -f "$manifest" >/dev/null
  kubectl -n flux-system wait --for=condition=Available deployment --all --timeout=300s >/dev/null

  log "applying sops-age secret and cluster-settings"
  sops -d --input-type binary --output-type binary "$ROOT/nix/secrets/sops-age.enc" | kubectl apply -f - >/dev/null

  # Prod's cluster-settings, with the values that must point at local things.
  local node_ip
  node_ip=$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
  nix_eval 'nix-letsnote1.config.services.k3s.manifests."04-cluster-settings.yaml".source.text' |
    jq --arg nfs "$node_ip" '.data.NFS_HOST = $nfs | .data.EXTERNAL_DOMAIN = "lab.test"' |
    kubectl apply -f - >/dev/null

  apply_flux_sync

  log "waiting for local registry"
  local deadline=$((SECONDS + 300))
  until curl -fsS -m 3 "http://$REGISTRY/v2/" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || die "registry not reachable at $REGISTRY"
    sleep 3
  done
}

# Flux stages + local patches (local/flux); re-applied on every sync so
# changes to the patches take effect without recreating the VM.
apply_flux_sync() {
  kubectl kustomize --load-restrictor=LoadRestrictionsNone "$ROOT/local/flux" | kubectl apply -f - >/dev/null
}

cmd_sync() {
  need flux kubectl jq git rsync
  require_cluster
  local ref=${1:-} src revision
  src=$(mktemp -d)
  trap 'rm -rf "$src"' RETURN

  if [[ -n $ref ]]; then
    git -C "$ROOT" archive "$ref" cluster | tar -x -C "$src"
    revision="$ref@sha1:$(git -C "$ROOT" rev-parse "$ref^{commit}")"
  else
    rsync -a --exclude .DS_Store "$ROOT/cluster" "$src/"
    revision="$(git -C "$ROOT" branch --show-current)@sha1:$(git -C "$ROOT" rev-parse HEAD)"
    [[ -z $(git -C "$ROOT" status --porcelain -- cluster) ]] || log "syncing uncommitted changes in cluster/"
  fi

  apply_flux_sync
  log "pushing ${ref:-working tree} to local registry"
  flux push artifact "oci://$REGISTRY/lab:local" --insecure-registry --path "$src" \
    --source "$(git -C "$ROOT" config --get remote.origin.url)" --revision "$revision" >/dev/null
  flux reconcile source oci lab >/dev/null

  wait_healthy
}

# Prints one line per object that is not (yet) healthy.
unhealthy() {
  local rev
  rev=$(kubectl -n flux-system get ocirepository lab -o jsonpath='{.status.artifact.revision}')
  kubectl get kustomizations.kustomize.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io,deployments,statefulsets,daemonsets,jobs \
    -A -o json | jq -r --arg rev "$rev" '
    def cond(t): (.status.conditions // []) | map(select(.type == t)) | first // {};
    def current: (.status.observedGeneration // -1) == .metadata.generation;
    .items[]
    | "\(.kind) \(.metadata.namespace)/\(.metadata.name)" as $id
    | if .kind == "Kustomization" then
        select((current and cond("Ready").status == "True" and .status.lastAppliedRevision == $rev) | not)
        | "\($id): \(cond("Ready").message // "pending")"
      elif .kind == "HelmRelease" then
        select((current and cond("Ready").status == "True") | not)
        | "\($id): \(cond("Ready").message // "pending")"
      elif .kind == "Deployment" then
        select((current and (.status.updatedReplicas // 0) == .spec.replicas
                and (.status.availableReplicas // 0) == .spec.replicas) | not)
        | "\($id): \(.status.availableReplicas // 0)/\(.spec.replicas) available"
      elif .kind == "StatefulSet" then
        select((current and (.status.readyReplicas // 0) == .spec.replicas
                and .status.currentRevision == .status.updateRevision) | not)
        | "\($id): \(.status.readyReplicas // 0)/\(.spec.replicas) ready"
      elif .kind == "DaemonSet" then
        select((current and .status.updatedNumberScheduled == .status.desiredNumberScheduled
                and (.status.numberAvailable // 0) == .status.desiredNumberScheduled) | not)
        | "\($id): \(.status.numberAvailable // 0)/\(.status.desiredNumberScheduled) available"
      else
        select(cond("Failed").status == "True") | "\($id): \(cond("Failed").message)"
      end'
}

wait_healthy() {
  log "waiting for flux and workloads (timeout ${TIMEOUT}s)"
  local deadline=$((SECONDS + TIMEOUT)) bad=""
  while ((SECONDS < deadline)); do
    bad=$(unhealthy)
    [[ -z $bad ]] && break
    # A failed health check otherwise waits for retryInterval.
    kubectl -n flux-system annotate --overwrite kustomizations.kustomize.toolkit.fluxcd.io --all \
      reconcile.fluxcd.io/requestedAt="$(date +%s)" >/dev/null
    sleep 15
  done
  report "$bad"
}

report() {
  local bad=$1
  flux get kustomizations
  echo
  flux get helmreleases -A
  if [[ -n $bad ]]; then
    echo
    log "not healthy:"
    echo "$bad"
    echo
    log "pods not running:"
    kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null || true
    kubectl get pods -A -o json | jq -r '.items[]
      | select(.status.phase == "Running" and any(.status.containerStatuses[]?; .ready | not))
      | "\(.metadata.namespace)/\(.metadata.name): containers not ready"'
    echo
    log "recent warning events:"
    kubectl get events -A --field-selector=type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -20
    return 1
  fi
  log "local cluster is healthy"
}

cmd_status() {
  need flux kubectl jq
  require_cluster
  report "$(unhealthy)"
}

# Same checks as CI, plus evaluating every NixOS host.
cmd_check() {
  need kustomize kubeconform nix
  local dir host
  for dir in cluster/infra/controllers cluster/infra/configs cluster/apps; do
    log "kubeconform $dir"
    kustomize build "$ROOT/$dir" | kubeconform -summary -ignore-missing-schemas \
      -schema-location default \
      -schema-location "https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"
  done
  for host in $(nix eval --json "$ROOT/nix#nixosConfigurations" --apply builtins.attrNames | jq -r '.[]'); do
    log "evaluating $host"
    nix_eval "$host.config.system.build.toplevel.drvPath" >/dev/null
  done
  log "nix flake check"
  (cd "$ROOT/nix" && nix flake check)
}

# Read-only server-side dry run of the working tree against prod.
cmd_diff() {
  need flux kubectl
  local server
  server=$(KUBECONFIG=$PROD_KUBECONFIG kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  [[ $server != *127.0.0.1* ]] || die "$PROD_KUBECONFIG points at the local cluster ($server)"
  log "diffing against $server ($PROD_KUBECONFIG)"
  local ks rc=0
  for ks in infra-controllers:cluster/infra/controllers infra-configs:cluster/infra/configs apps:cluster/apps; do
    log "${ks%%:*}"
    flux diff kustomization "${ks%%:*}" --path "$ROOT/${ks#*:}" --kubeconfig "$PROD_KUBECONFIG" --progress-bar=false || rc=$?
  done
  # flux diff exits 1 when there are changes; only >1 is an error.
  ((rc <= 1))
}

usage() {
  cat <<'EOF'
usage: local/cluster.sh <command> [args]

  up [ref]      create/start the VM, bootstrap flux, then sync
  sync [ref]    push cluster/ (working tree, or git ref) and wait until healthy
  status        flux + workload health of the local cluster
  check         CI checks (kustomize | kubeconform), nix eval of all hosts, flake check
  diff          read-only diff of the working tree against prod
  kubectl ...   kubectl against the local cluster
  flux ...      flux against the local cluster
  k9s           k9s against the local cluster
  shell         shell into the VM
  stop          stop the VM (state is kept)
  destroy       delete the VM
EOF
}

cmd=${1:-help}
shift || true
case $cmd in
  up | sync | status | check | diff) "cmd_$cmd" "$@" ;;
  kubectl | flux | k9s) require_cluster; exec "$cmd" "$@" ;;
  shell) exec limactl shell "$VM" "$@" ;;
  stop) limactl stop "$VM" ;;
  destroy) limactl delete --force "$VM"; rm -f "$KUBECONFIG"; unregister_context ;;
  help | -h | --help) usage ;;
  *) usage >&2; exit 1 ;;
esac
