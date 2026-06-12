#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EVIDENCE_DIR="${REPO_ROOT}/internal/evidence/phase-0"
HOST_LOG="${EVIDENCE_DIR}/host-isolation.log"

failures=()

fail() {
  failures+=("$1")
}

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    fail "missing file: ${path#${REPO_ROOT}/}"
  fi
}

require_grep() {
  local pattern="$1"
  local path="$2"
  local message="$3"
  if ! grep -Eq "${pattern}" "${path}" 2>/dev/null; then
    fail "${message}"
  fi
}

hash_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    md5 -q "${path}"
  else
    printf "MISSING"
  fi
}

check_notes() {
  local note
  for note in "${REPO_ROOT}/internal/evaluation/NOTES-floci.md" "${REPO_ROOT}/internal/evaluation/NOTES-ministack.md"; do
    require_file "${note}"
    if [[ -f "${note}" ]]; then
      local section_count
      section_count="$(grep -Ec '^## [1-5]\.' "${note}")"
      [[ "${section_count}" == "5" ]] || fail "${note#${REPO_ROOT}/} must contain five numbered fact sections"
    fi
  done
}

check_scorecard() {
  local scorecard="${REPO_ROOT}/internal/evaluation/SCORECARD.md"
  require_file "${scorecard}"
  [[ -f "${scorecard}" ]] || return 0

  local row
  for row in \
    "01-core: apply \\+ verify by AWS CLI" \
    "02-rds:.*real DB" \
    "03-eks:.*node Ready" \
    "Error quality / DX" \
    "Start time \\+ idle RAM" \
    "Docs \\+ release cadence \\+ community"; do
    require_grep "${row}" "${scorecard}" "scorecard missing row matching: ${row}"
  done

  require_grep 'Chosen emulator: \*\*Floci\*\*' "${scorecard}" "scorecard must record chosen emulator"
}

check_evidence_count() {
  if [[ ! -d "${EVIDENCE_DIR}" ]]; then
    fail "missing evidence directory: internal/evidence/phase-0"
    return 0
  fi

  local count
  count="$(find "${EVIDENCE_DIR}" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  [[ "${count}" -ge 8 ]] || fail "expected at least 8 evidence logs, found ${count}"
}

check_adr_and_versions() {
  local decisions="${REPO_ROOT}/internal/DECISIONS.md"
  local versions="${REPO_ROOT}/versions.env"
  require_file "${decisions}"
  require_file "${versions}"

  if [[ -f "${decisions}" ]]; then
    require_grep '^## ADR-[0-9]+: Chọn emulator' "${decisions}" "DECISIONS.md missing emulator-selection ADR"
    require_grep 'floci/floci:1\.5\.24' "${decisions}" "emulator ADR missing pinned Floci image"
  fi

  if [[ -f "${versions}" ]]; then
    require_grep '^EMULATOR_IMAGE=[^:[:space:]]+/[^:[:space:]]+:[^:[:space:]]+$' "${versions}" "versions.env missing concrete EMULATOR_IMAGE pin"
    if grep -Eq '^EMULATOR_IMAGE=.*:latest($|[[:space:]])' "${versions}"; then
      fail "versions.env must not pin EMULATOR_IMAGE to latest"
    fi
  fi
}

check_chosen_core_evidence() {
  local emulator="floci"
  if [[ -f "${REPO_ROOT}/versions.env" ]]; then
    emulator="$(awk -F= '$1 == "EMULATOR" {print $2}' "${REPO_ROOT}/versions.env" | tail -1)"
    [[ -n "${emulator}" ]] || emulator="floci"
  fi

  local verify="${EVIDENCE_DIR}/${emulator}-01-verify.log"
  require_file "${verify}"
  [[ -f "${verify}" ]] || return 0

  require_grep 'fogstack-phase0-core' "${verify}" "chosen emulator core verify missing bucket or queue name"
  require_grep 'hello-fogstack' "${verify}" "chosen emulator core verify missing S3 object content"
  require_grep 'fogstack-phase0-lambda-role' "${verify}" "chosen emulator core verify missing IAM role"
  require_grep 'QueueUrls' "${verify}" "chosen emulator core verify missing SQS list output"
}

check_cleanup() {
  local containers
  containers="$(docker ps -a --format '{{.Names}}' | grep -E '^(fogstack-eval-|ministack-eks-|floci-)' || true)"
  if [[ -n "${containers}" ]]; then
    fail "test containers still present: ${containers//$'\n'/, }"
  fi

  if lsof -nP -iTCP:4566 -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port 4566 is still busy"
  fi
}

check_host_isolation() {
  require_file "${HOST_LOG}"
  [[ -f "${HOST_LOG}" ]] || return 0

  {
    printf 'host-isolation after captured at %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for path in "${HOME}/.aws/config" "${HOME}/.aws/credentials" "${HOME}/.kube/config"; do
      local before after
      before="$(awk -v p="${path}" '$1 == "BEFORE" && $2 == p {value=$3} END {print value}' "${HOST_LOG}")"
      after="$(hash_file "${path}")"
      printf 'AFTER %s %s\n' "${path}" "${after}"
      if [[ -z "${before}" ]]; then
        fail "host-isolation log missing BEFORE hash for ${path}"
      elif [[ "${before}" != "${after}" ]]; then
        fail "host-isolation hash changed for ${path}"
      fi
    done
  } >> "${HOST_LOG}"
}

check_notes
check_scorecard
check_evidence_count
check_adr_and_versions
check_chosen_core_evidence
check_cleanup
check_host_isolation

if ((${#failures[@]} > 0)); then
  printf 'GATE-0 FAIL\n' >&2
  for failure in "${failures[@]}"; do
    printf -- '- %s\n' "${failure}" >&2
  done
  exit 1
fi

printf 'GATE-0 PASS\n'
