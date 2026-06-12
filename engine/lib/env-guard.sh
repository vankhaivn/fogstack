#!/usr/bin/env bash
# Source this before fogstack commands that may touch AWS or Kubernetes clients.

if [[ -z "${REPO_ROOT:-}" ]]; then
  if command -v git >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  if [[ -z "${REPO_ROOT:-}" ]]; then
    _fogstack_guard_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    REPO_ROOT="${_fogstack_guard_dir}"
    unset _fogstack_guard_dir
  fi
fi

export REPO_ROOT

install -d -m 700 "${REPO_ROOT}/.state"
: > "${REPO_ROOT}/.state/aws-config"
: > "${REPO_ROOT}/.state/aws-credentials"
: >> "${REPO_ROOT}/.state/kubeconfig.yaml"
chmod 600 "${REPO_ROOT}/.state/aws-config" "${REPO_ROOT}/.state/aws-credentials" "${REPO_ROOT}/.state/kubeconfig.yaml"

export KUBECONFIG="${REPO_ROOT}/.state/kubeconfig.yaml"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="us-east-1"
export AWS_CONFIG_FILE="${REPO_ROOT}/.state/aws-config"
export AWS_SHARED_CREDENTIALS_FILE="${REPO_ROOT}/.state/aws-credentials"
export AWS_EC2_METADATA_DISABLED="true"
export AWS_PAGER=""

unset AWS_PROFILE AWS_SESSION_TOKEN AWS_ROLE_ARN
