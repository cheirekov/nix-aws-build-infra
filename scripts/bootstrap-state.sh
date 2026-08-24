#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tfvars_file="${repo_root}/.deployment/terraform.tfvars.json"
infra_profile="${NIX_AWS_INFRA_PROFILE:-}"

if [[ -z "${infra_profile}" ]]; then
  printf 'Set NIX_AWS_INFRA_PROFILE to an approved Identity Center infrastructure-admin profile.\n' >&2
  exit 2
fi
if [[ ! -f "${tfvars_file}" ]]; then
  printf 'Missing %s; run scripts/init-deployment.sh first.\n' "${tfvars_file}" >&2
  exit 1
fi
export AWS_PROFILE="${infra_profile}"
project_name="$(jq -er .project_name "${tfvars_file}")"
aws_region="$(jq -er .aws_region "${tfvars_file}")"
account_id="$(aws sts get-caller-identity --query Account --output text)"
bucket_name="${project_name}-tfstate-${account_id}-${aws_region}"
backend_file="${repo_root}/infra/backend.hcl"

if ! aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
  if [[ "${aws_region}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${bucket_name}" \
      --region "${aws_region}" >/dev/null
  else
    aws s3api create-bucket \
      --bucket "${bucket_name}" \
      --region "${aws_region}" \
      --create-bucket-configuration "LocationConstraint=${aws_region}" >/dev/null
  fi
fi

aws s3api put-public-access-block \
  --bucket "${bucket_name}" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
aws s3api put-bucket-encryption \
  --bucket "${bucket_name}" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-versioning \
  --bucket "${bucket_name}" \
  --versioning-configuration Status=Enabled

umask 077
{
  printf 'bucket = "%s"\n' "${bucket_name}"
  printf 'key = "%s/terraform.tfstate"\n' "${project_name}"
  printf 'region = "%s"\n' "${aws_region}"
} >"${backend_file}"

printf 'State bucket: %s\nBackend config: %s\n' "${bucket_name}" "${backend_file}"
