#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
aws_region="${AWS_REGION:-eu-central-1}"
project_name="${PROJECT_NAME:-nix-aws-build-infra}"
public_key_file="${repo_root}/config/cache-public-key.txt"
private_key_file="${repo_root}/.secrets/cache-private-key"

for command in aws jq nix-store packer tofu; do
  command -v "${command}" >/dev/null || {
    printf 'Missing command %s; run this script inside nix develop.\n' "${command}" >&2
    exit 1
  }
done

"${repo_root}/scripts/bootstrap-state.sh"
"${repo_root}/scripts/generate-signing-key.sh"

cache_public_key="$(tr -d '\r\n' <"${public_key_file}")"

tofu -chdir="${repo_root}/infra" init -backend-config=backend.hcl
tofu -chdir="${repo_root}/infra" apply \
  -auto-approve \
  -var "aws_region=${aws_region}" \
  -var "project_name=${project_name}" \
  -var "cache_public_key=${cache_public_key}"

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
  printf 'No local signing key and no current key in Secrets Manager.\n' >&2
  exit 1
fi

pushd "${repo_root}/packer" >/dev/null
packer init .
packer build \
  -var "aws_region=${aws_region}" \
  -var "project_name=${project_name}" \
  .
popd >/dev/null

artifact_id="$(jq -er '.builds[-1].artifact_id' "${repo_root}/packer/manifest.json")"
ami_id="${artifact_id##*:}"
if [[ ! "${ami_id}" =~ ^ami-[[:xdigit:]]+$ ]]; then
  printf 'Packer returned an invalid AMI ID: %s\n' "${ami_id}" >&2
  exit 1
fi

ami_parameter="$(tofu -chdir="${repo_root}/infra" output -raw builder_ami_parameter)"
aws ssm put-parameter \
  --region "${aws_region}" \
  --name "${ami_parameter}" \
  --type String \
  --value "${ami_id}" \
  --overwrite >/dev/null

# The AWS secret version is confirmed before any recoverable local copy is removed.
aws secretsmanager describe-secret --region "${aws_region}" --secret-id "${secret_arn}" >/dev/null
find "${private_key_file}" -maxdepth 0 -type f -delete

printf 'Deployment complete.\nAMI: %s\nCache: %s\nRole: %s\n' \
  "${ami_id}" \
  "$(tofu -chdir="${repo_root}/infra" output -raw cache_url)" \
  "$(tofu -chdir="${repo_root}/infra" output -raw github_provisioner_role_arn)"
