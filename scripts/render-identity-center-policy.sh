#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deployment_dir="${repo_root}/.deployment"
output_file="${1:-${deployment_dir}/identity-center-operator-policy.json}"

install -d -m 0700 "${deployment_dir}"

tofu -chdir="${repo_root}/infra" output -raw identity_center_operator_policy_json |
  jq --sort-keys . >"${output_file}"

chmod 0600 "${output_file}"

printf 'Rendered NixAwsBuildOperator policy: %s\n' "${output_file}"
