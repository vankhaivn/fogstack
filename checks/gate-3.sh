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

export FOGSTACK_ENV_FILE="${REPO_ROOT}/.env.example"

FOG="${REPO_ROOT}/engine/fog"
EVIDENCE_DIR="${REPO_ROOT}/internal/evidence/phase-3"
HOST_LOG="${EVIDENCE_DIR}/host-isolation.log"
SHELLCHECK_LOG="${EVIDENCE_DIR}/shellcheck.log"
DOCTOR_LOG="${EVIDENCE_DIR}/doctor.log"
UP_LOG="${EVIDENCE_DIR}/up-full.log"
STATUS_LOG="${EVIDENCE_DIR}/status.log"
ENDPOINTS_LOG="${EVIDENCE_DIR}/endpoints.log"
HOST_AWS_LOG="${EVIDENCE_DIR}/host-aws.log"
TF_LOG="${EVIDENCE_DIR}/tf-override.log"
LAYER2_LOG="${EVIDENCE_DIR}/layer2.log"
INCLUSTER_LOG="${EVIDENCE_DIR}/incluster-aws.log"
GATEWAY_LOG="${EVIDENCE_DIR}/gateway.log"
OPENSEARCH_LOG="${EVIDENCE_DIR}/opensearch.log"
RAM_LOG="${EVIDENCE_DIR}/ram.log"
ADR_LOG="${EVIDENCE_DIR}/adr-versions.log"
MINIMAL_LOG="${EVIDENCE_DIR}/minimal-regression.log"
DOWN_LOG="${EVIDENCE_DIR}/down.log"
CLUSTER_NAME="fogstack"
HOST_BUCKET="fogstack-host-phase3"
TF_BUCKET="fogstack-tf-phase3-$(date +%s)"
INCLUSTER_BUCKET="fogstack-incluster-phase3"
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
OPENSEARCH_URL="${OPENSEARCH_URL:-http://localhost:9200}"
DASHBOARDS_URL="${DASHBOARDS_URL:-http://localhost:5601}"
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
    env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes >> "${DOWN_LOG}" 2>&1
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

clear_logs() {
  : > "${SHELLCHECK_LOG}"
  : > "${DOCTOR_LOG}"
  : > "${UP_LOG}"
  : > "${STATUS_LOG}"
  : > "${ENDPOINTS_LOG}"
  : > "${HOST_AWS_LOG}"
  : > "${TF_LOG}"
  : > "${LAYER2_LOG}"
  : > "${INCLUSTER_LOG}"
  : > "${GATEWAY_LOG}"
  : > "${OPENSEARCH_LOG}"
  : > "${RAM_LOG}"
  : > "${ADR_LOG}"
  : > "${MINIMAL_LOG}"
  : > "${DOWN_LOG}"
}

ensure_clean() {
  log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes
}

check_status_output() {
  local output="$1"
  printf '%s\n' "${output}" | awk -F'|' '
    NR == 1 { next }
    NF >= 4 {
      component=$1
      health=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", component)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", health)
      seen[component]=1
      if (health != "healthy") {
        exit 1
      }
    }
    END {
      required = "kind registry postgres emulator opensearch dashboards"
      split(required, names, " ")
      for (i in names) {
        if (!seen[names[i]]) {
          exit 1
        }
      }
    }
  '
}

capture_full_status() {
  local output
  output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" status --profile full)"
  {
    printf '$ FOGSTACK_ENV_FILE=%q %q status --profile full\n' "${FOGSTACK_ENV_FILE}" "${FOG}"
    printf '%s\n' "${output}"
  } >> "${STATUS_LOG}"
  check_status_output "${output}"
}

capture_full_endpoints() {
  local output
  output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" endpoints --profile full)"
  {
    printf '$ FOGSTACK_ENV_FILE=%q %q endpoints --profile full\n' "${FOGSTACK_ENV_FILE}" "${FOG}"
    printf '%s\n' "${output}"
  } >> "${ENDPOINTS_LOG}"

  if printf '%s\n' "${output}" | grep -Ev '^[A-Z_][A-Z0-9_]*=[^[:space:]]+$' >/dev/null; then
    printf 'invalid full endpoint format\n' >> "${ENDPOINTS_LOG}"
    return 1
  fi

  # shellcheck disable=SC2016
  env -i PATH="${PATH}" bash -c '
    set -Eeuo pipefail
    eval "$1"
    [[ "${AWS_ENDPOINT_URL}" == "http://localhost:4566" ]]
    [[ "${OPENSEARCH_URL}" == "http://localhost:9200" ]]
    [[ "${DASHBOARDS_URL}" == "http://localhost:5601" ]]
    [[ "${KUBECONFIG}" == */.state/kubeconfig.yaml ]]
    [[ "${KUBE_CONTEXT}" == "kind-fogstack" ]]
    [[ "${REGISTRY}" == "localhost:5001" ]]
    [[ "${POSTGRES_URL}" == postgresql://* ]]
  ' bash "${output}" >> "${ENDPOINTS_LOG}" 2>&1
}

assert_minimal_endpoints() {
  local output
  output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" endpoints --profile minimal)"
  {
    printf '$ FOGSTACK_ENV_FILE=%q %q endpoints --profile minimal\n' "${FOGSTACK_ENV_FILE}" "${FOG}"
    printf '%s\n' "${output}"
  } >> "${MINIMAL_LOG}"

  if printf '%s\n' "${output}" | grep -Eq '^(AWS_ENDPOINT_URL|OPENSEARCH_URL|DASHBOARDS_URL)='; then
    printf 'minimal endpoints advertised full-profile endpoint\n' >> "${MINIMAL_LOG}"
    return 1
  fi

  # shellcheck disable=SC2016
  env -i PATH="${PATH}" bash -c '
    set -Eeuo pipefail
    eval "$1"
    [[ "${KUBECONFIG}" == */.state/kubeconfig.yaml ]]
    [[ "${KUBE_CONTEXT}" == "kind-fogstack" ]]
    [[ "${REGISTRY}" == "localhost:5001" ]]
    [[ "${POSTGRES_URL}" == postgresql://* ]]
  ' bash "${output}" >> "${MINIMAL_LOG}" 2>&1
}

run_full_up() {
  local start
  local elapsed

  log_run "${DOCTOR_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" doctor --profile full

  start="$(date +%s)"
  log_run "${UP_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" up --profile full
  elapsed="$(($(date +%s) - start))"
  printf 'elapsed_seconds=%s\n' "${elapsed}" >> "${UP_LOG}"
  [[ "${elapsed}" -le 600 ]]
}

run_host_aws() {
  # shellcheck disable=SC2016
  log_run "${HOST_AWS_LOG}" bash -c 'aws --endpoint-url "$1" s3 mb "s3://$2" || true' bash "${AWS_ENDPOINT_URL}" "${HOST_BUCKET}"
  log_run "${HOST_AWS_LOG}" aws --endpoint-url "${AWS_ENDPOINT_URL}" s3 ls
  grep -q "${HOST_BUCKET}" "${HOST_AWS_LOG}"
}

run_tf_override() {
  local tf_dir
  tf_dir="$(mktemp -d "${EVIDENCE_DIR}/tf-XXXXXX")"
  log_run "${TF_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" tf-init "${tf_dir}"
  cat > "${tf_dir}/main.tf" <<EOF_TF
resource "aws_s3_bucket" "gate3" {
  bucket        = "${TF_BUCKET}"
  force_destroy = true
}
EOF_TF
  log_run "${TF_LOG}" terraform -chdir="${tf_dir}" init -input=false
  log_run "${TF_LOG}" terraform -chdir="${tf_dir}" apply -auto-approve -input=false
  log_run "${TF_LOG}" aws --endpoint-url "${AWS_ENDPOINT_URL}" s3 ls
  grep -q "${TF_BUCKET}" "${TF_LOG}"
}

run_layer2() {
  local endpoints_output
  local image_name

  endpoints_output="$(FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" endpoints --profile full)"
  eval "${endpoints_output}"
  image_name="${REGISTRY}/sample-app:0.1.0"

  {
    printf 'evaluated full endpoints\n'
    printf 'KUBECONFIG=%s\n' "${KUBECONFIG}"
    printf 'KUBE_CONTEXT=%s\n' "${KUBE_CONTEXT}"
    printf 'REGISTRY=%s\n' "${REGISTRY}"
  } >> "${LAYER2_LOG}"

  log_run "${LAYER2_LOG}" docker build -t "${image_name}" "${REPO_ROOT}/examples/sample-app"
  log_run "${LAYER2_LOG}" docker push "${image_name}"
  log_run "${LAYER2_LOG}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" init -input=false
  log_run "${LAYER2_LOG}" terraform -chdir="${REPO_ROOT}/terraform/layer2-apps" apply -auto-approve -input=false
  log_run "${LAYER2_LOG}" kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" rollout status deployment/sample-app --timeout=180s
  log_run "${LAYER2_LOG}" helm --kubeconfig "${KUBECONFIG}" --kube-context "${KUBE_CONTEXT}" list -A
}

check_incluster_aws() {
  log_run "${INCLUSTER_LOG}" kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" -n fogstack get job fogstack-aws-cli-incluster -o wide
  log_run "${INCLUSTER_LOG}" kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" -n fogstack logs job/fogstack-aws-cli-incluster
  log_run "${INCLUSTER_LOG}" aws --endpoint-url "${AWS_ENDPOINT_URL}" s3 ls
  grep -q "${INCLUSTER_BUCKET}" "${INCLUSTER_LOG}"
}

curl_gateway_candidate() {
  local url="$1"
  local body
  body="$(curl --max-time 3 -fsS -H 'Host: sample.fogstack.test' "${url}" 2>>"${GATEWAY_LOG}" || true)"
  if printf '%s\n' "${body}" | grep -q 'fogstack-sample-ok'; then
    printf '%s\nendpoint=%s\n' "${body}" "${url}" >> "${GATEWAY_LOG}"
    return 0
  fi
  return 1
}

wait_for_gateway() {
  local address
  local container
  local port

  for _ in {1..90}; do
    while IFS= read -r address; do
      [[ -n "${address}" ]] || continue
      if curl_gateway_candidate "http://${address}"; then
        return 0
      fi
    done < <(kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get gateway sample-gateway -o jsonpath='{range .status.addresses[*]}{.value}{"\n"}{end}' 2>/dev/null || true)

    if curl_gateway_candidate "http://localhost"; then
      return 0
    fi

    while IFS= read -r container; do
      [[ -n "${container}" ]] || continue
      port="$(docker port "${container}" 80/tcp 2>/dev/null | awk -F: '/0.0.0.0|127.0.0.1/ {print $NF; exit}')"
      [[ -n "${port}" ]] || continue
      if curl_gateway_candidate "http://localhost:${port}"; then
        return 0
      fi
    done < <(docker ps -q --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}")

    sleep 2
  done

  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" get gateway,httproute,svc -A -o wide >> "${GATEWAY_LOG}" 2>&1 || true
  docker ps --filter "label=io.x-k8s.cloud-provider-kind.cluster=${CLUSTER_NAME}" --format '{{.Names}} {{.Ports}}' >> "${GATEWAY_LOG}" 2>&1 || true
  return 1
}

check_opensearch_logs() {
  local dashboards_code
  local indices
  log_run "${OPENSEARCH_LOG}" curl -fsS "${OPENSEARCH_URL}/_cluster/health?wait_for_status=yellow&timeout=5s"
  dashboards_code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "${DASHBOARDS_URL}/api/status" 2>>"${OPENSEARCH_LOG}" || true)"
  printf 'dashboards_http_code=%s\n' "${dashboards_code}" >> "${OPENSEARCH_LOG}"
  [[ "${dashboards_code}" =~ ^[0-9]{3}$ && "${dashboards_code}" != "000" ]]

  for _ in {1..120}; do
    indices="$(curl -fsS "${OPENSEARCH_URL}/_cat/indices/kind-logs-*?h=index,docs.count" 2>>"${OPENSEARCH_LOG}" || true)"
    if printf '%s\n' "${indices}" | awk '$2 + 0 > 0 {found=1} END {exit found ? 0 : 1}'; then
      printf '%s\n' "${indices}" >> "${OPENSEARCH_LOG}"
      return 0
    fi
    sleep 2
  done

  curl -fsS "${OPENSEARCH_URL}/_cat/indices?v" >> "${OPENSEARCH_LOG}" 2>&1 || true
  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" -n fogstack get pods -o wide >> "${OPENSEARCH_LOG}" 2>&1 || true
  kubectl --kubeconfig "${KUBECONFIG}" --context "${KUBE_CONTEXT}" -n fogstack logs -l app.kubernetes.io/name=fluent-bit --tail=80 >> "${OPENSEARCH_LOG}" 2>&1 || true
  return 1
}

check_ram_budget() {
  local containers=()
  local total_mib

  while IFS= read -r container; do
    [[ -n "${container}" ]] || continue
    containers+=("${container}")
  done < <(docker ps --format '{{.Names}}' | grep -E '^fogstack' || true)

  ((${#containers[@]} > 0)) || return 1
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' "${containers[@]}" > "${RAM_LOG}"
  total_mib="$(awk '
    function to_mib(raw, value, unit) {
      value = raw
      unit = raw
      gsub(/[A-Za-z]+/, "", value)
      gsub(/[0-9.]+/, "", unit)
      if (unit == "KiB") return value / 1024
      if (unit == "MiB") return value
      if (unit == "GiB") return value * 1024
      if (unit == "B") return value / 1048576
      return value
    }
    {sum += to_mib($2)}
    END {printf "%.0f", sum}
  ' "${RAM_LOG}")"
  printf 'total_mib=%s\nlimit_mib=6144\n' "${total_mib}" >> "${RAM_LOG}"
  [[ "${total_mib}" -le 6144 ]]
}

check_adr_versions() {
  {
    grep -E 'ADR-014|ADR-015' "${REPO_ROOT}/internal/DECISIONS.md"
    grep -E '^(OPENSEARCH_IMAGE|OPENSEARCH_DASHBOARDS_IMAGE|ENVOY_GATEWAY_CHART_VERSION|FLUENT_BIT_CHART_VERSION|FLUENT_BIT_IMAGE|AWS_CLI_IMAGE|AWS_CLI_VERSION|TF_PROVIDER_AWS_VERSION)=' "${REPO_ROOT}/versions.env"
    grep -E 'envoy_gateway_chart_version|fluent_bit_chart_version|fluent_bit_image_tag|aws_cli_image' "${REPO_ROOT}/terraform/layer2-apps/main.tf"
  } > "${ADR_LOG}"

  grep -q 'ADR-014' "${ADR_LOG}"
  grep -q 'ADR-015' "${ADR_LOG}"
  grep -q 'opensearchproject/opensearch:3.3.0' "${ADR_LOG}"
  grep -q 'v1.5.1' "${ADR_LOG}"
  grep -q '0.57.7' "${ADR_LOG}"
  grep -q 'amazon/aws-cli:2.34.20' "${ADR_LOG}"
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

run_minimal_regression() {
  log_run "${MINIMAL_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" up --profile minimal
  log_run "${MINIMAL_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" status --profile minimal
  assert_minimal_endpoints
}

clear_logs
write_host_before

log_run "${SHELLCHECK_LOG}" shellcheck "${FOG}" "${REPO_ROOT}"/engine/lib/*.sh "${REPO_ROOT}"/stack/scripts/*.sh "${REPO_ROOT}/checks/gate-3.sh"
ensure_clean
run_full_up
capture_full_status
capture_full_endpoints
run_host_aws
run_tf_override
run_layer2
check_incluster_aws
wait_for_gateway
check_opensearch_logs
check_ram_budget
check_adr_versions
log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes
check_clean_after_volumes
run_minimal_regression
log_run "${DOWN_LOG}" env FOGSTACK_ENV_FILE="${FOGSTACK_ENV_FILE}" "${FOG}" down --volumes
check_clean_after_volumes

printf 'GATE-3 PASS\n'
