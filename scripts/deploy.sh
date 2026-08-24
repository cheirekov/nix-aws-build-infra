#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deployment_dir="${repo_root}/.deployment"
tfvars_file="${deployment_dir}/terraform.tfvars.json"
plan_file="${deployment_dir}/infra.tfplan"
mode="${1:-}"
infra_profile="${NIX_AWS_INFRA_PROFILE:-}"
public_key_file="${deployment_dir}/cache-public-key.txt"
private_key_file="${repo_root}/.secrets/cache-private-key"
local_public_key_file="${deployment_dir}/cache-local-public-key.txt"
local_private_key_file="${repo_root}/.secrets/cache-local-private-key"

usage() {
  cat <<'EOF'
Usage: deploy.sh plan | apply | build-amis

  plan        Create an inspectable OpenTofu plan; makes no infrastructure changes.
  apply       Apply exactly the saved plan and upload signing keys.
  build-amis  Build and publish both x86_64 and aarch64 AMIs; incurs EC2 cost.

Set NIX_AWS_INFRA_PROFILE to an approved Identity Center infrastructure-admin
profile. Run init-deployment.sh and bootstrap-state.sh first.
EOF
}

case "${mode}" in
  plan | apply | build-amis) ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [[ -z "${infra_profile}" ]]; then
  printf 'Set NIX_AWS_INFRA_PROFILE to an approved Identity Center infrastructure-admin profile.\n' >&2
  exit 2
fi
if [[ ! -f "${tfvars_file}" ]]; then
  printf 'Missing %s; run scripts/init-deployment.sh first.\n' "${tfvars_file}" >&2
  exit 1
fi
if [[ ! -f "${repo_root}/infra/backend.hcl" ]]; then
  printf 'Missing infra/backend.hcl; run scripts/bootstrap-state.sh first.\n' >&2
  exit 1
fi
for key_file in "${public_key_file}" "${local_public_key_file}"; do
  if [[ ! -s "${key_file}" ]]; then
    printf 'Missing signing public key: %s\n' "${key_file}" >&2
    exit 1
  fi
done

export AWS_PROFILE="${infra_profile}"
aws_region="$(jq -er .aws_region "${tfvars_file}")"
project_name="$(jq -er .project_name "${tfvars_file}")"
cache_public_key="$(tr -d '\r\n' <"${public_key_file}")"
local_cache_public_key="$(tr -d '\r\n' <"${local_public_key_file}")"

for command in aws jq tofu; do
  command -v "${command}" >/dev/null || {
    printf 'Missing command %s; run inside nix develop.\n' "${command}" >&2
    exit 1
  }
done

tofu -chdir="${repo_root}/infra" init -backend-config=backend.hcl

if [[ "${mode}" == "plan" ]]; then
  tofu -chdir="${repo_root}/infra" plan \
    -var-file="${tfvars_file}" \
    -var "cache_public_key=${cache_public_key}" \
    -var "local_cache_public_key=${local_cache_public_key}" \
    -out="${plan_file}"
  printf 'Saved reviewed-plan candidate: %s\n' "${plan_file}"
  printf 'Inspect with: tofu -chdir=infra show %q\n' "${plan_file}"
  exit 0
fi

if [[ "${mode}" == "apply" ]]; then
  if [[ ! -f "${plan_file}" ]]; then
    printf 'Missing saved plan %s; run deploy.sh plan first.\n' "${plan_file}" >&2
    exit 1
  fi
  tofu -chdir="${repo_root}/infra" apply "${plan_file}"

  secret_arn="$(tofu -chdir="${repo_root}/infra" output -raw cache_signing_secret_arn)"
  if [[ -s "${private_key_file}" ]]; then
    aws secretsmanager put-secret-value \
      --region "${aws_region}" \
      --secret-id "${secret_arn}" \
      --secret-string "file://${private_key_file}" >/dev/null
  elif ! aws secretsmanager get-secret-value \
    --region "${aws_region}" \
    --secret-id "${secret_arn}" \
    --query VersionId \
    --output text >/dev/null; then
    printf 'No local CI signing key and no current key in Secrets Manager.\n' >&2
    exit 1
  fi

  local_secret_arn="$(tofu -chdir="${repo_root}/infra" output -raw cache_local_signing_secret_arn)"
  if [[ -s "${local_private_key_file}" ]]; then
    aws secretsmanager put-secret-value \
      --region "${aws_region}" \
      --secret-id "${local_secret_arn}" \
      --secret-string "file://${local_private_key_file}" >/dev/null
  elif ! aws secretsmanager get-secret-value \
    --region "${aws_region}" \
    --secret-id "${local_secret_arn}" \
    --query VersionId \
    --output text >/dev/null; then
    printf 'No local publisher key and no current key in Secrets Manager.\n' >&2
    exit 1
  fi

  aws secretsmanager describe-secret --region "${aws_region}" --secret-id "${secret_arn}" >/dev/null
  aws secretsmanager describe-secret --region "${aws_region}" --secret-id "${local_secret_arn}" >/dev/null
  for private_key in "${private_key_file}" "${local_private_key_file}"; do
    if [[ -f "${private_key}" ]]; then
      find "${private_key}" -maxdepth 0 -type f -delete
    fi
  done
  find "${plan_file}" -maxdepth 0 -type f -delete
  printf 'Infrastructure applied. Build AMIs explicitly with: scripts/deploy.sh build-amis\n'
  exit 0
fi

command -v packer >/dev/null || {
  printf 'Missing command packer; run inside nix develop.\n' >&2
  exit 1
}

pushd "${repo_root}/packer" >/dev/null
packer init .
packer build \
  -var "aws_region=${aws_region}" \
  -var "project_name=${project_name}" \
  .
popd >/dev/null

for nix_system in x86_64-linux aarch64-linux; do
  artifact_id="$(jq -er --arg system "${nix_system}" \
    '.builds[] | select(.name | startswith($system + ".")) | .artifact_id' \
    "${repo_root}/packer/manifest.json")"
  ami_id="${artifact_id##*:}"
  if [[ ! "${ami_id}" =~ ^ami-[[:xdigit:]]+$ ]]; then
    printf 'Packer returned an invalid %s AMI ID: %s\n' "${nix_system}" "${ami_id}" >&2
    exit 1
  fi
  ami_parameter="$(tofu -chdir="${repo_root}/infra" output -json builder_ami_parameters | jq -er --arg system "${nix_system}" '.[$system]')"
  aws ssm put-parameter \
    --region "${aws_region}" \
    --name "${ami_parameter}" \
    --type String \
    --value "${ami_id}" \
    --overwrite >/dev/null
  if [[ "${nix_system}" == "x86_64-linux" ]]; then
    legacy_parameter="$(tofu -chdir="${repo_root}/infra" output -raw builder_ami_parameter)"
    aws ssm put-parameter \
      --region "${aws_region}" \
      --name "${legacy_parameter}" \
      --type String \
      --value "${ami_id}" \
      --overwrite >/dev/null
  fi
  printf '%s AMI: %s\n' "${nix_system}" "${ami_id}"
done
