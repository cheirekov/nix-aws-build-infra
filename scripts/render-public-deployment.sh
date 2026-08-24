#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deployment_dir="${repo_root}/.deployment"
tfvars_file="${deployment_dir}/terraform.tfvars.json"
output_file="${1:-}"

if [[ ! -f "${tfvars_file}" ]]; then
  printf 'Missing %s; initialize and apply the deployment first.\n' "${tfvars_file}" >&2
  exit 1
fi

cache_url="$(tofu -chdir="${repo_root}/infra" output -raw cache_url)"
ci_key="$(tr -d '\r\n' <"${deployment_dir}/cache-public-key.txt")"
local_key="$(tr -d '\r\n' <"${deployment_dir}/cache-local-public-key.txt")"
rendered="$(jq -S \
  --arg cache_url "${cache_url}" \
  --arg ci_key "${ci_key}" \
  --arg local_key "${local_key}" \
  '. + {cache_url:$cache_url,cache_public_keys:[$ci_key,$local_key]}' \
  "${tfvars_file}")"

if [[ -n "${output_file}" ]]; then
  output_dir="$(dirname "${output_file}")"
  install -d -m 0755 "${output_dir}"
  temporary="${output_file}.tmp"
  printf '%s\n' "${rendered}" >"${temporary}"
  chmod 0644 "${temporary}"
  mv "${temporary}" "${output_file}"
  printf 'Rendered public deployment metadata: %s\n' "${output_file}"
else
  printf '%s\n' "${rendered}"
fi
