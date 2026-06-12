#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE_DIR="${REPO_ROOT}/internal/evidence/phase-1"
HOST_LOG="${EVIDENCE_DIR}/host-isolation.log"
CLUSTER_NAME="fogstack"
CONTEXT="kind-${CLUSTER_NAME}"
IMAGE_NAME="localhost:5001/sample-app:0.1.0"
EXIT_CODE=0

mkdir -p "${EVIDENCE_DIR}"

hash_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    md5 -q "${path}"
  else
    printf 'MISSING'
  fi
}

host_context() {
  env -u KUBECONFIG kubectl config current-context 2>/dev/null || printf 'NONE'
}

write_host_before() {
  {
    printf 'BEFORE_DATE %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for path in "${HOME}/.kube/config" "${HOME}/.aws/config" "${HOME}/.aws/credentials"; do
      printf 'BEFORE %s %s\n' "${path}" "$(hash_file "${path}")"
    done
    printf 'BEFORE_CONTEXT %s\n' "$(host_context)"
  } > "${HOST_LOG}"
}

write_host_after() {
  local before after path before_context after_context
  local after_lines=()

  for path in "${HOME}/.kube/config" "${HOME}/.aws/config" "${HOME}/.aws/credentials"; do
    before="$(awk -v p="${path}" '$1 == "BEFORE" && $2 == p {print $3}' "${HOST_LOG}")"
    after="$(hash_file "${path}")"
    after_lines+=("AFTER ${path} ${after}")
    if [[ "${before}" != "${after}" ]]; then
      after_lines+=("HOST_ISOLATION_FAIL ${path} changed")
      EXIT_CODE=1
    fi
  done

  before_context="$(awk '$1 == "BEFORE_CONTEXT" {print $2}' "${HOST_LOG}")"
  after_context="$(host_context)"
  after_lines+=("AFTER_CONTEXT ${after_context}")
  if [[ "${before_context}" != "${after_context}" ]]; then
    after_lines+=("HOST_ISOLATION_FAIL host context changed from ${before_context} to ${after_context}")
    EXIT_CODE=1
  fi

  if [[ -f "${REPO_ROOT}/.state/kubeconfig.yaml" ]] && grep -q 'kind-fogstack' "${REPO_ROOT}/.state/kubeconfig.yaml"; then
    after_lines+=("STATE_KUBECONFIG kind-fogstack present")
  else
    after_lines+=("HOST_ISOLATION_FAIL .state/kubeconfig.yaml missing kind-fogstack")
    EXIT_CODE=1
  fi

  {
    printf 'AFTER_DATE %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "${after_lines[@]}"
  } >> "${HOST_LOG}"
}

write_state_kubeconfig_evidence() {
  if [[ -f "${REPO_ROOT}/.state/kubeconfig.yaml" ]] && grep -q 'kind-fogstack' "${REPO_ROOT}/.state/kubeconfig.yaml"; then
    printf 'STATE_KUBECONFIG_BEFORE_TEARDOWN kind-fogstack present\n' >> "${HOST_LOG}"
  else
    printf 'STATE_KUBECONFIG_BEFORE_TEARDOWN kind-fogstack missing\n' >> "${HOST_LOG}"
    return 1
  fi
}

on_exit() {
  local code=$?
  set +e
  if [[ "${code}" -ne 0 ]]; then
    EXIT_CODE="${code}"
    teardown failure >/dev/null 2>&1 || true
  fi
  write_host_after
  exit "${EXIT_CODE}"
}

trap on_exit EXIT

write_host_before

export REPO_ROOT
# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/versions.env"
set +a

log_run() {
  local log_file="$1"
  shift
  {
    printf '$'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } >> "${log_file}" 2>&1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'missing required command: %s\n' "$1" >&2
    exit 1
  }
}

check_versions() {
  local log_file="${EVIDENCE_DIR}/versions.log"
  : > "${log_file}"
  for key in \
    KIND_NODE_IMAGE \
    NGINX_IMAGE \
    POSTGRES_IMAGE \
    REGISTRY_IMAGE \
    CLOUD_PROVIDER_KIND_VERSION \
    CLOUD_PROVIDER_KIND_IMAGE \
    TF_PROVIDER_KIND_VERSION \
    TF_PROVIDER_KUBERNETES_VERSION \
    TF_PROVIDER_HELM_VERSION; do
    if ! grep -Eq "^${key}=.+" "${REPO_ROOT}/versions.env"; then
      printf 'missing version pin: %s\n' "${key}" | tee -a "${log_file}" >&2
      exit 1
    fi
  done

  if grep -Eq '(^|:)latest($|[[:space:]])' "${REPO_ROOT}/versions.env"; then
    printf 'versions.env must not retain latest tags\n' | tee -a "${log_file}" >&2
    exit 1
  fi

  grep -E '^(KIND_NODE_IMAGE|NGINX_IMAGE|POSTGRES_IMAGE|REGISTRY_IMAGE|CLOUD_PROVIDER_KIND_VERSION|CLOUD_PROVIDER_KIND_IMAGE|TF_PROVIDER_[A-Z_]+)=' "${REPO_ROOT}/versions.env" >> "${log_file}"
}

teardown() {
  local reason="${1:-normal}"
  local log_file="${EVIDENCE_DIR}/teardown.log"
  local lb_container
  local kubeconfig_backup=""
  {
    printf 'teardown_reason=%s\n' "${reason}"
    date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  } >> "${log_file}"

  terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" destroy -auto-approve -input=false >> "${log_file}" 2>&1 || true
  "${REPO_ROOT}/stack/scripts/stop-lb-provider.sh" >> "${log_file}" 2>&1 || true
  for lb_container in $(docker ps -aq --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}"); do
    docker rm -f "${lb_container}" >> "${log_file}" 2>&1 || true
  done

  if [[ "${reason}" == "final" && -f "${KUBECONFIG}" ]]; then
    kubeconfig_backup="${EVIDENCE_DIR}/kubeconfig-before-final-delete.yaml"
    cp "${KUBECONFIG}" "${kubeconfig_backup}"
  fi

  kind delete cluster --name "${CLUSTER_NAME}" >> "${log_file}" 2>&1 || true

  if [[ -n "${kubeconfig_backup}" && -f "${kubeconfig_backup}" ]]; then
    cp "${kubeconfig_backup}" "${KUBECONFIG}"
    chmod 600 "${KUBECONFIG}"
    printf 'restored project-local kubeconfig after final kind delete\n' >> "${log_file}"
  fi

  docker compose --env-file "${REPO_ROOT}/.env.example" -f "${REPO_ROOT}/stack/compose.yaml" down -v --remove-orphans >> "${log_file}" 2>&1 || true
  docker rm -f fogstack-registry >> "${log_file}" 2>&1 || true

  if docker ps -a --format '{{.Names}}' | grep -E '^fogstack' >> "${log_file}" 2>&1; then
    printf 'fogstack containers remain\n' >> "${log_file}"
    return 1
  fi

  if docker volume ls --format '{{.Name}}' | grep -E '^fogstack' >> "${log_file}" 2>&1; then
    printf 'fogstack volumes remain\n' >> "${log_file}"
    return 1
  fi

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    printf 'kind cluster remains: %s\n' "${CLUSTER_NAME}" >> "${log_file}"
    return 1
  fi
}

wait_for_http() {
  local log_file="$1"
  local endpoint container port
  local body

  for _ in {1..60}; do
    endpoint="$(kubectl --context "${CONTEXT}" get svc sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${endpoint}" ]]; then
      body="$(curl --max-time 2 -fsS "http://${endpoint}" 2>>"${log_file}" || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        printf '%s\n' "${body}" >> "${log_file}"
        printf '\nendpoint=http://%s\n' "${endpoint}" >> "${log_file}"
        return 0
      fi
    fi

    if curl --max-time 2 -fsS http://localhost 2>/dev/null | tee "${log_file}" | grep -q 'fogstack-sample-ok'; then
      printf '\nendpoint=http://localhost\n' >> "${log_file}"
      return 0
    fi

    for container in $(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}"); do
      port="$(docker port "${container}" 80/tcp 2>/dev/null | awk -F: '/0.0.0.0/ {print $NF; exit}')"
      [[ -n "${port}" ]] || continue
      body="$(curl --max-time 2 -fsS "http://localhost:${port}" 2>>"${log_file}" || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        printf '%s\n' "${body}" >> "${log_file}"
        printf '\nendpoint=http://localhost:%s\n' "${port}" >> "${log_file}"
        return 0
      fi
    done

    sleep 2
  done

  kubectl --context "${CONTEXT}" get svc sample-app -o wide >> "${log_file}" 2>&1 || true
  docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}" --format '{{.Names}} {{.Ports}}' >> "${log_file}" 2>&1 || true
  return 1
}

run_round() {
  local round="$1"
  local nodes_log="${EVIDENCE_DIR}/nodes.log"
  local registry_log="${EVIDENCE_DIR}/registry.log"
  local psql_log="${EVIDENCE_DIR}/psql.log"
  local helm_log="${EVIDENCE_DIR}/helm.log"
  local curl_log="${EVIDENCE_DIR}/curl.log"

  {
    printf '\n===== round %s =====\n' "${round}"
    date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  } | tee -a "${nodes_log}" "${registry_log}" "${psql_log}" "${helm_log}" "${curl_log}" >/dev/null

  teardown "pre-round-${round}" || true

  log_run "${nodes_log}" "${REPO_ROOT}/stack/scripts/create-cluster.sh"
  log_run "${nodes_log}" kubectl --context "${CONTEXT}" get nodes -o wide
  local ready_count total_count
  total_count="$(kubectl --context "${CONTEXT}" get nodes --no-headers | wc -l | tr -d ' ')"
  ready_count="$(kubectl --context "${CONTEXT}" get nodes --no-headers | awk '$2 ~ /Ready/ {count++} END {print count + 0}')"
  [[ "${total_count}" == "3" && "${ready_count}" == "3" ]]

  log_run "${psql_log}" docker compose --env-file "${REPO_ROOT}/.env.example" -f "${REPO_ROOT}/stack/compose.yaml" up -d --wait
  log_run "${psql_log}" docker run --rm -e PGPASSWORD=test "${POSTGRES_IMAGE}" psql "host=host.docker.internal port=5432 user=fogstack dbname=appdb" -c "SELECT 1;"
  grep -q '1 row' "${psql_log}"

  log_run "${registry_log}" docker build -t "${IMAGE_NAME}" "${REPO_ROOT}/examples/sample-app"
  log_run "${registry_log}" docker push "${IMAGE_NAME}"

  log_run "${helm_log}" "${REPO_ROOT}/stack/scripts/start-lb-provider.sh"
  log_run "${helm_log}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" init -input=false
  log_run "${helm_log}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" apply -auto-approve -input=false
  log_run "${helm_log}" kubectl --context "${CONTEXT}" rollout status deployment/sample-app --timeout=180s
  log_run "${helm_log}" helm --kubeconfig "${KUBECONFIG}" --kube-context "${CONTEXT}" list -A
  grep -q 'sample-app' "${helm_log}"
  grep -q 'deployed' "${helm_log}"

  log_run "${registry_log}" kubectl --context "${CONTEXT}" get pods -l app.kubernetes.io/name=sample-app -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
  grep -q "${IMAGE_NAME}" "${registry_log}"
  log_run "${registry_log}" kubectl --context "${CONTEXT}" describe pods -l app.kubernetes.io/name=sample-app

  : > "${curl_log}"
  wait_for_http "${curl_log}"
}

require_cmd docker
require_cmd kind
require_cmd kubectl
require_cmd terraform
require_cmd helm
require_cmd curl

check_versions
run_round 1
teardown "between-rounds"
run_round 2
write_state_kubeconfig_evidence
teardown "final"

printf 'GATE-1 PASS\n'
