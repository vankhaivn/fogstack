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

EVIDENCE_DIR="${FOGSTACK_CPK_EVIDENCE_DIR:-${REPO_ROOT}/internal/evidence/phase-1}"
PID_FILE="${FOGSTACK_CPK_PID_FILE:-${REPO_ROOT}/.state/cloud-provider-kind.pid}"
LOG_FILE="${FOGSTACK_CPK_LOG_FILE:-${EVIDENCE_DIR}/cloud-provider-kind.log}"
CONTAINER_NAME="fogstack-cloud-provider-kind"

mkdir -p "${EVIDENCE_DIR}"

if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
  printf 'cloud-provider-kind already running with pid %s\n' "$(cat "${PID_FILE}")"
  exit 0
fi

rm -f "${PID_FILE}"

if docker ps --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
  printf 'cloud-provider-kind container already running: %s\n' "${CONTAINER_NAME}"
  exit 0
fi

if command -v cloud-provider-kind >/dev/null 2>&1; then
  printf 'starting cloud-provider-kind binary\n' | tee "${LOG_FILE}"
  nohup cloud-provider-kind \
    --enable-lb-port-mapping \
    --logs-dir "${EVIDENCE_DIR}/cloud-provider-kind-logs" \
    >>"${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  sleep 3

  if kill -0 "$(cat "${PID_FILE}")" >/dev/null 2>&1; then
    printf 'cloud-provider-kind binary started with pid %s\n' "$(cat "${PID_FILE}")" | tee -a "${LOG_FILE}"
    exit 0
  fi

  printf 'cloud-provider-kind binary exited; falling back to container mode\n' | tee -a "${LOG_FILE}"
  rm -f "${PID_FILE}"
fi

printf 'starting cloud-provider-kind container %s\n' "${CLOUD_PROVIDER_KIND_IMAGE}" | tee -a "${LOG_FILE}"
docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker run -d \
  --name "${CONTAINER_NAME}" \
  --restart=unless-stopped \
  --network kind \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "${CLOUD_PROVIDER_KIND_IMAGE}" \
  --enable-lb-port-mapping \
  >>"${LOG_FILE}" 2>&1
