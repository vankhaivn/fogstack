#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"

set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/versions.env"
set +a

FOG="${REPO_ROOT}/engine/fog"
PROFILE="${FOGSTACK_SMOKE_PROFILE:-minimal}"
FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE:-${REPO_ROOT}/.env.example}"
export FOGSTACK_ENV_FILE
POSTGRES_USER="${POSTGRES_USER:-fogstack}"

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
  wait_for_service_http "default" "sample-app" "/" "fogstack-sample-ok"
}

candidate_service_urls() {
  local namespace="$1"
  local service="$2"
  local endpoint
  local container
  local port

  endpoint="$(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" \
    -n "${namespace}" get svc "${service}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${endpoint}" ]]; then
    printf 'http://%s\n' "${endpoint}"
  fi

  for container in $(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.cluster=fogstack"); do
    port="$(docker port "${container}" 80/tcp 2>/dev/null | awk -F: '/0.0.0.0|127.0.0.1/ {print $NF; exit}')"
    [[ -n "${port}" ]] || continue
    printf 'http://localhost:%s\n' "${port}"
  done
}

WAIT_HTTP_URL=""
wait_for_service_http() {
  local namespace="$1"
  local service="$2"
  local path="$3"
  local pattern="$4"
  local endpoint
  local body

  for _ in {1..60}; do
    while IFS= read -r endpoint; do
      [[ -n "${endpoint}" ]] || continue
      body="$(curl --max-time 2 -fsS "${endpoint}${path}" 2>/dev/null || true)"
      if printf '%s\n' "${body}" | grep -q "${pattern}"; then
        WAIT_HTTP_URL="${endpoint}"
        return 0
      fi
    done < <(candidate_service_urls "${namespace}" "${service}")

    sleep 2
  done

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" -n "${namespace}" get svc "${service}" -o wide >&2 || true
  docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=fogstack" --format '{{.Names}} {{.Ports}}' >&2 || true
  return 1
}

check_postgres() {
  local result
  result="$(docker exec fogstack-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT 1"' 2>/dev/null | tr -d '[:space:]')"
  [[ "${result}" == "1" ]]
}

check_redis() {
  local result
  result="$(docker exec fogstack-redis redis-cli ping 2>/dev/null | tr -d '[:space:]')"
  [[ "${result}" == "PONG" ]]
}

wait_for_pod_succeeded() {
  local name="$1"
  local phase

  for _ in {1..120}; do
    phase="$(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get pod "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "${phase}" in
      Succeeded) return 0 ;;
      Failed) return 1 ;;
    esac
    sleep 1
  done

  return 1
}

run_netcheck_pod() {
  local name="$1"
  local image="$2"
  shift 2

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" delete pod "${name}" --ignore-not-found >/dev/null
  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" run "${name}" \
    --image="${image}" \
    --restart=Never \
    --command -- "$@" >/dev/null

  if ! wait_for_pod_succeeded "${name}"; then
    kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" describe pod "${name}" >&2 || true
    kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" logs "${name}" >&2 || true
    kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" delete pod "${name}" --ignore-not-found >/dev/null
    return 1
  fi

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" logs "${name}"
  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" delete pod "${name}" --ignore-not-found >/dev/null
}

check_incluster_datastores() {
  local postgres_output
  local redis_output

  postgres_output="$(run_netcheck_pod fogstack-postgres-netcheck "${POSTGRES_IMAGE}" pg_isready -h fogstack-postgres -p 5432 -U "${POSTGRES_USER}")"
  printf '%s\n' "${postgres_output}" | grep -q 'accepting connections'

  redis_output="$(run_netcheck_pod fogstack-redis-netcheck "${REDIS_IMAGE}" redis-cli -h fogstack-redis -p 6379 ping)"
  printf '%s\n' "${redis_output}" | grep -q PONG
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

deploy_full_tour() {
  local endpoints_output
  local image_name

  endpoints_output="$("${FOG}" endpoints --profile full)"
  eval "${endpoints_output}"
  image_name="${REGISTRY}/full-tour:${FULL_TOUR_IMAGE_TAG}"

  docker build -q \
    --build-arg "GO_BUILDER_IMAGE=${GO_BUILDER_IMAGE}" \
    -t "${image_name}" \
    "${REPO_ROOT}/examples/full-tour/app" >/dev/null
  docker push "${image_name}" >/dev/null
  helm upgrade --install full-tour "${REPO_ROOT}/examples/full-tour/chart" \
    --kubeconfig "${KUBECONFIG}" \
    --kube-context "${KUBE_CONTEXT}" \
    --namespace fogstack \
    --create-namespace \
    --set "image.repository=${REGISTRY}/full-tour" \
    --set "image.tag=${FULL_TOUR_IMAGE_TAG}" \
    --wait \
    --timeout 240s >/dev/null
}

check_full_tour() {
  local create_body
  local list_body

  wait_for_service_http "fogstack" "full-tour" "/healthz" '"ok":true'

  create_body="$(curl --max-time 5 -fsS -X POST "${WAIT_HTTP_URL}/notes" \
    -H 'content-type: application/json' \
    -d '{"title":"fogstack smoke","body":"Postgres Redis S3 OpenSearch"}')"
  printf '%s\n' "${create_body}" | grep -q 'fogstack smoke'

  list_body="$(curl --max-time 5 -fsS "${WAIT_HTTP_URL}/notes?q=smoke")"
  printf '%s\n' "${list_body}" | grep -q 'fogstack smoke'
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

log "checking Redis"
check_redis

log "deploying sample app"
deploy_sample_app

log "checking sample app"
wait_for_http

if [[ "${PROFILE}" == "full" ]]; then
  log "checking in-cluster datastore reachability"
  check_incluster_datastores

  log "checking AWS API endpoint"
  aws --endpoint-url "${AWS_ENDPOINT_URL}" s3 ls >/dev/null

  log "deploying full-tour app"
  deploy_full_tour

  log "checking full-tour app"
  check_full_tour
fi

log "smoke check passed"
