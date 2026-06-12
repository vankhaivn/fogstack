#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"

set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/versions.env"
set +a

CLUSTER_NAME="${CLUSTER_NAME:-fogstack}"
REGISTRY_NAME="${REGISTRY_NAME:-fogstack-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
REGISTRY_INTERNAL_PORT="${REGISTRY_INTERNAL_PORT:-5000}"
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
CONTEXT="kind-${CLUSTER_NAME}"

log() {
  printf '[fogstack] %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

ensure_registry() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)"

  if [[ "${running}" == "true" ]]; then
    log "registry ${REGISTRY_NAME} already running"
    return 0
  fi

  if docker inspect "${REGISTRY_NAME}" >/dev/null 2>&1; then
    log "starting existing registry ${REGISTRY_NAME}"
    docker start "${REGISTRY_NAME}" >/dev/null
  else
    log "creating registry ${REGISTRY_NAME} from ${REGISTRY_IMAGE}"
    docker run -d \
      --restart=always \
      -p "127.0.0.1:${REGISTRY_PORT}:${REGISTRY_INTERNAL_PORT}" \
      --name "${REGISTRY_NAME}" \
      "${REGISTRY_IMAGE}" >/dev/null
  fi
}

ensure_cluster() {
  if kind get clusters | grep -qx "${CLUSTER_NAME}"; then
    log "kind cluster ${CLUSTER_NAME} already exists"
    return 0
  fi

  log "creating kind cluster ${CLUSTER_NAME}"
  kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${REPO_ROOT}/stack/kind-config.yaml" \
    --kubeconfig "${KUBECONFIG}"
}

ensure_registry_network() {
  if ! docker network inspect kind >/dev/null 2>&1; then
    printf 'docker network "kind" does not exist; create the kind cluster first\n' >&2
    exit 1
  fi

  if docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}" | grep -qv '^null$'; then
    log "registry ${REGISTRY_NAME} already connected to kind network"
  else
    log "connecting registry ${REGISTRY_NAME} to kind network"
    docker network connect kind "${REGISTRY_NAME}"
  fi
}

install_hosts_toml() {
  local node
  for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
    log "installing registry hosts.toml in ${node}"
    docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
    docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml" <<EOF
[host."http://${REGISTRY_NAME}:${REGISTRY_INTERNAL_PORT}"]
EOF
  done
}

apply_registry_configmap() {
  log "applying local-registry-hosting ConfigMap"
  kubectl --context "${CONTEXT}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

require_cmd docker
require_cmd kind
require_cmd kubectl

ensure_registry
ensure_cluster
ensure_registry_network
install_hosts_toml
apply_registry_configmap

kubectl --context "${CONTEXT}" wait --for=condition=Ready nodes --all --timeout=180s
log "cluster ${CLUSTER_NAME} is ready with local registry localhost:${REGISTRY_PORT}"
