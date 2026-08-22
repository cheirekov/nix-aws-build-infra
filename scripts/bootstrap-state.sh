#!/usr/bin/env bash
set -euo pipefail

project_name="${PROJECT_NAME:-nix-aws-build-infra}"
aws_region="${AWS_REGION:-eu-central-1}"
account_id="$(aws sts get-caller-identity --query Account --output text)"
bucket_name="${project_name}-tfstate-${account_id}-${aws_region}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend_file="${repo_root}/infra/backend.hcl"

if ! aws s3api head-bucket --bucket "${bucket_name}" 2>/dev/null; then
  aws s3api create-bucket \
    --bucket "${bucket_name}" \
    --region "${aws_region}" \
    --create-bucket-configuration "LocationConstraint=${aws_region}" >/dev/null
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
  printf 'region = "%s"\n' "${aws_region}"
} >"${backend_file}"

printf 'State bucket: %s\nBackend config: %s\n' "${bucket_name}" "${backend_file}"
