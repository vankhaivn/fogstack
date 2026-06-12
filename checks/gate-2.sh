#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
export REPO_ROOT

# shellcheck disable=SC1091
source "${REPO_ROOT}/engine/lib/env-guard.sh"

export FOGSTACK_ENV_FILE="${REPO_ROOT}/.env.example"

FOG="${REPO_ROOT}/engine/fog"
EVIDENCE_DIR="${REPO_ROOT}/internal/evidence/phase-2"
HOST_LOG="${EVIDENCE_DIR}/host-isolation.log"
SHELLCHECK_LOG="${EVIDENCE_DIR}/shellcheck.log"
DOCTOR_LOG="${EVIDENCE_DIR}/doctor.log"
UP1_LOG="${EVIDENCE_DIR}/up1.log"
STATUS_LOG="${EVIDENCE_DIR}/status.log"
ENDPOINTS_LOG="${EVIDENCE_DIR}/endpoints.log"
E2E_LOG="${EVIDENCE_DIR}/e2e.log"
UP2_LOG="${EVIDENCE_DIR}/up2.log"
DOWN_LOG="${EVIDENCE_DIR}/down.log"
CLUSTER_NAME="fogstack"
EXIT_CODE=0

mkdir -p "${EVIDENCE_DIR}"

hash_file() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    printf 'MISSING'
    return 0
  fi

  if command -v md5 >/dev/null 2>&1; then
    md5 -q "${path}"
    return 0
  fi

  md5sum "${path}" | awk '{print $1}'
}

write_host_before() {
  {
    printf 'BEFORE_DATE %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for path in "${HOME}/.kube/config" "${HOME}/.aws/config" "${HOME}/.aws/credentials"; do
      printf 'BEFORE %s %s\n' "${path}" "$(hash_file "${path}")"
    done
  } > "${HOST_LOG}"
}

write_host_after() {
  local before
  local after
  local path
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

  if grep -Eq '^KUBECONFIG=.*/\.state/kubeconfig\.yaml$' "${ENDPOINTS_LOG}" 2>/dev/null; then
    after_lines+=("ENDPOINTS_KUBECONFIG repo-local")
  else
    after_lines+=("HOST_ISOLATION_FAIL endpoints KUBECONFIG is not repo-local")
    EXIT_CODE=1
  fi

  {
    printf 'AFTER_DATE %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "${after_lines[@]}"
  } >> "${HOST_LOG}"
}

on_exit() {
  local code=$?
  set +e
  if [[ "${code}" -ne 0 ]]; then
    EXIT_CODE="${code}"
    FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes >> "${DOWN_LOG}" 2>&1 || true
  fi
  write_host_after
  exit "${EXIT_CODE}"
}

trap on_exit EXIT

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

ensure_clean() {
  log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes
}

check_status_output() {
  local output="$1"
  printf '%s\n' "${output}" | awk -F'|' '
    NR == 1 { next }
    NF >= 4 {
      health=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", health)
      if (health != "healthy") {
        exit 1
      }
    }
  '
}

capture_status() {
  local output
  output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" status)"
  {
    printf '$ FOGSTACK_ENV_FILE=%q %q status\n' "${FOGSTACK_ENV_FILE}" "${FOG}"
    printf '%s\n' "${output}"
  } >> "${STATUS_LOG}"
  check_status_output "${output}"
}

capture_endpoints() {
  local output
  output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" endpoints)"
  {
    printf '$ FOGSTACK_ENV_FILE=%q %q endpoints\n' "${FOGSTACK_ENV_FILE}" "${FOG}"
    printf '%s\n' "${output}"
  } >> "${ENDPOINTS_LOG}"

  if printf '%s\n' "${output}" | grep -Ev '^[A-Z_][A-Z0-9_]*=[^[:space:]]+$' >/dev/null; then
    printf 'invalid endpoint format\n' >> "${ENDPOINTS_LOG}"
    return 1
  fi

  # shellcheck disable=SC2016
  env -i PATH="${PATH}" bash -c '
    set -Eeuo pipefail
    eval "$1"
    [[ "${AWS_ENDPOINT_URL}" == "http://localhost:4566" ]]
    [[ "${KUBECONFIG}" == */.state/kubeconfig.yaml ]]
    [[ "${KUBE_CONTEXT}" == "kind-fogstack" ]]
    [[ "${REGISTRY}" == "localhost:5001" ]]
    [[ "${POSTGRES_URL}" == postgresql://* ]]
  ' bash "${output}" >> "${ENDPOINTS_LOG}" 2>&1
}

wait_for_http() {
  local log_file="$1"
  local endpoint
  local container
  local port
  local body

  for _ in {1..60}; do
    endpoint="$(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get svc sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${endpoint}" ]]; then
      body="$(curl --max-time 2 -fsS "http://${endpoint}" 2>>"${log_file}" || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        printf '%s\nendpoint=http://%s\n' "${body}" "${endpoint}" >> "${log_file}"
        return 0
      fi
    fi

    if curl --max-time 2 -fsS http://localhost 2>/dev/null | tee -a "${log_file}" | grep -q 'fogstack-sample-ok'; then
      printf 'endpoint=http://localhost\n' >> "${log_file}"
      return 0
    fi

    for container in $(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}"); do
      port="$(docker port "${container}" 80/tcp 2>/dev/null | awk -F: '/0.0.0.0/ {print $NF; exit}')"
      [[ -n "${port}" ]] || continue
      body="$(curl --max-time 2 -fsS "http://localhost:${port}" 2>>"${log_file}" || true)"
      if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
        printf '%s\nendpoint=http://localhost:%s\n' "${body}" "${port}" >> "${log_file}"
        return 0
      fi
    done

    sleep 2
  done

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get svc sample-app -o wide >> "${log_file}" 2>&1 || true
  docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}" --format '{{.Names}} {{.Ports}}' >> "${log_file}" 2>&1 || true
  return 1
}

run_e2e() {
  local endpoints_output
  local image_name

  endpoints_output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" endpoints)"
  eval "${endpoints_output}"
  image_name="${REGISTRY}/sample-app:0.1.0"

  {
    printf 'evaluated endpoints from %s\n' "${FOG}"
    printf 'KUBECONFIG=%s\n' "${KUBECONFIG}"
    printf 'KUBE_CONTEXT=%s\n' "${KUBE_CONTEXT}"
    printf 'REGISTRY=%s\n' "${REGISTRY}"
  } >> "${E2E_LOG}"

  log_run "${E2E_LOG}" docker build -t "${image_name}" "${REPO_ROOT}/examples/sample-app"
  log_run "${E2E_LOG}" docker push "${image_name}"
  log_run "${E2E_LOG}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" init -input=false
  log_run "${E2E_LOG}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" apply -auto-approve -input=false
  log_run "${E2E_LOG}" kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" rollout status deployment/sample-app --timeout=180s
  log_run "${E2E_LOG}" helm --kubeconfig "${KUBECONFIG}" --kube-context "${KUBE_CONTEXT}" list -A
  wait_for_http "${E2E_LOG}"
}

check_no_duplicate_resources() {
  local registry_count
  local postgres_count
  registry_count="$(docker ps -a --format '{{.Names}}' | awk '$0 == "fogstack-registry" {count++} END {print count + 0}')"
  postgres_count="$(docker ps -a --format '{{.Names}}' | awk '$0 == "fogstack-postgres" {count++} END {print count + 0}')"
  [[ "${registry_count}" == "1" ]]
  [[ "${postgres_count}" == "1" ]]
}

check_down_without_volumes() {
  if docker ps -a --format '{{.Names}}' | grep -E '^fogstack[-_]' >> "${DOWN_LOG}" 2>&1; then
    printf 'fogstack containers remain after fog down\n' >> "${DOWN_LOG}"
    return 1
  fi

  if docker volume ls --format '{{.Name}}' | grep -E '^fogstack[-_]' >> "${DOWN_LOG}" 2>&1; then
    printf 'fogstack volume preserved after fog down\n' >> "${DOWN_LOG}"
    return 0
  fi

  printf 'expected a fogstack volume to remain after fog down without --volumes\n' >> "${DOWN_LOG}"
  return 1
}

check_clean_after_volumes() {
  if docker ps -a --format '{{.Names}}' | grep -E '^fogstack[-_]' >> "${DOWN_LOG}" 2>&1; then
    printf 'fogstack containers remain after fog down --volumes\n' >> "${DOWN_LOG}"
    return 1
  fi

  if docker volume ls --format '{{.Name}}' | grep -E '^fogstack[-_]' >> "${DOWN_LOG}" 2>&1; then
    printf 'fogstack volumes remain after fog down --volumes\n' >> "${DOWN_LOG}"
    return 1
  fi

  if docker network ls --format '{{.Name}}' | grep -E '^fogstack[-_]' >> "${DOWN_LOG}" 2>&1; then
    printf 'fogstack networks remain after fog down --volumes\n' >> "${DOWN_LOG}"
    return 1
  fi

  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    printf 'kind cluster remains after fog down --volumes\n' >> "${DOWN_LOG}"
    return 1
  fi
}

run_round() {
  local round="$1"
  local start
  local elapsed

  {
    printf '\n===== round %s =====\n' "${round}"
    date -u '+date_utc=%Y-%m-%dT%H:%M:%SZ'
  } | tee -a "${DOCTOR_LOG}" "${UP1_LOG}" "${STATUS_LOG}" "${ENDPOINTS_LOG}" "${E2E_LOG}" "${UP2_LOG}" "${DOWN_LOG}" >/dev/null

  ensure_clean

  log_run "${DOCTOR_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" doctor

  start="$(date +%s)"
  log_run "${UP1_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" up
  elapsed="$(($(date +%s) - start))"
  if [[ "${elapsed}" -gt 480 ]]; then
    printf 'fog up exceeded 480 seconds: %s\n' "${elapsed}" >> "${UP1_LOG}"
    return 1
  fi

  capture_status
  capture_endpoints
  run_e2e

  log_run "${UP2_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" up
  grep -Eiq 'already' "${UP2_LOG}"
  check_no_duplicate_resources

  log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down
  check_down_without_volumes
  log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes
  check_clean_after_volumes
  log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down
}

: > "${SHELLCHECK_LOG}"
: > "${DOCTOR_LOG}"
: > "${UP1_LOG}"
: > "${STATUS_LOG}"
: > "${ENDPOINTS_LOG}"
: > "${E2E_LOG}"
: > "${UP2_LOG}"
: > "${DOWN_LOG}"

write_host_before

log_run "${SHELLCHECK_LOG}" shellcheck "${FOG}" "${REPO_ROOT}"/engine/lib/*.sh "${REPO_ROOT}"/stack/scripts/*.sh "${REPO_ROOT}/checks/gate-2.sh"
run_round 1
run_round 2

printf 'GATE-2 PASS\n'
