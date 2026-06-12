#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"

PID_FILE="${FOGSTACK_CPK_PID_FILE:-${REPO_ROOT}/.state/cloud-provider-kind.pid}"
CONTAINER_NAME="fogstack-cloud-provider-kind"

if [[ -f "${PID_FILE}" ]]; then
  pid="$(cat "${PID_FILE}")"
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true
    for _ in {1..20}; do
      kill -0 "${pid}" >/dev/null 2>&1 || break
      sleep 0.5
    done
    kill -9 "${pid}" >/dev/null 2>&1 || true
  fi
  rm -f "${PID_FILE}"
fi

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
