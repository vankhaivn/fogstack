#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"

FOG="${REPO_ROOT}/engine/fog"
PROFILE="${FOGSTACK_SMOKE_PROFILE:-minimal}"
FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE:-${REPO_ROOT}/.env.example}"
export FOGSTACK_ENV_FILE

log() {
  printf '[fogstack-smoke] %s\n' "$*"
}

cleanup() {
  local code=$?
  if [[ "${FOGSTACK_SMOKE_KEEP:-0}" != "1" ]]; then
    log "stopping local stack"
    "${FOG}" down --volumes >/dev/null 2>&1 || true
  fi
  exit "${code}"
}

trap cleanup EXIT

wait_for_http() {
  local endpoint
  local container
  local port
  local body

  for _ in {1..60}; do
    endpoint="$(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get svc sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${endpoint}" ]]; then
      body="$(curl --max-time 2 -fsS "http://${endpoint}" 2>/dev/null || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        return 0
      fi
    fi

    if curl --max-time 2 -fsS http://localhost 2>/dev/null | grep -q 'fogstack-sample-ok'; then
      return 0
    fi

    for container in $(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.cluster=fogstack"); do
      port="$(docker port "${container}" 80/tcp 2>/dev/null | awk -F: '/0.0.0.0/ {print $NF; exit}')"
      [[ -n "${port}" ]] || continue
      body="$(curl --max-time 2 -fsS "http://localhost:${port}" 2>/dev/null || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        return 0
      fi
    done

    sleep 2
  done

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get svc sample-app -o wide >&2 || true
  docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=fogstack" --format '{{.Names}} {{.Ports}}' >&2 || true
  return 1
}

check_postgres() {
  local result
  result="$(docker exec fogstack-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1"' 2>/dev/null | tr -d '[:space:]')"
  [[ "${result}" == "1" ]]
}

deploy_sample_app() {
  local endpoints_output
  local image_name

  endpoints_output="$("${FOG}" endpoints --profile "${PROFILE}")"
  eval "${endpoints_output}"
  image_name="${REGISTRY}/sample-app:0.1.0"

  docker build -q -t "${image_name}" "${REPO_ROOT}/examples/sample-app" >/dev/null
  docker push "${image_name}" >/dev/null
  helm upgrade --install sample-app "${REPO_ROOT}/examples/sample-app/chart" \
    --kubeconfig "${KUBECONFIG}" \
    --kube-context "${KUBE_CONTEXT}" \
    --set "image.repository=${REGISTRY}/sample-app" \
    --set image.tag=0.1.0 \
    --wait \
    --timeout 180s >/dev/null
}

log "checking host and local settings"
"${FOG}" doctor --profile "${PROFILE}"

log "starting ${PROFILE} profile"
"${FOG}" up --profile "${PROFILE}" >/dev/null
eval "$("${FOG}" endpoints --profile "${PROFILE}")"

log "checking Kubernetes nodes"
kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get nodes >/dev/null

log "checking Postgres"
check_postgres

log "deploying sample app"
deploy_sample_app

log "checking sample app"
wait_for_http

if [[ "${PROFILE}" == "full" ]]; then
  log "checking AWS API endpoint"
  aws --endpoint-url "${AWS_ENDPOINT_URL}" s3 ls >/dev/null
fi

log "smoke check passed"
