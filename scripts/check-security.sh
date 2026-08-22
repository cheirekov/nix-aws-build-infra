#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
iam_file="${repo_root}/infra/iam.tf"
network_file="${repo_root}/infra/network.tf"
cache_file="${repo_root}/infra/cache.tf"

require_pattern() {
  local pattern="$1"
  local file="$2"
  if ! rg --quiet --multiline "${pattern}" "${file}"; then
    printf 'Required security constraint is missing from %s: %s\n' "${file}" "${pattern}" >&2
    exit 1
  fi
}

reject_pattern() {
  local pattern="$1"
  shift
  if rg --quiet --multiline "${pattern}" "$@"; then
    printf 'Forbidden broad security policy found: %s\n' "${pattern}" >&2
    exit 1
  fi
}

# No role may receive every API action. Resource wildcards remain only on
# EC2 APIs that do not support complete resource-level authorization and the
# watchdog's parameter enumeration call.
reject_pattern 'actions?\s*=\s*\[?"\*"' "${repo_root}/infra"
wildcard_resources="$(rg --count-matches '(?i)resources?\s*=\s*\[?"\*"' "${iam_file}" "${repo_root}/infra/operations.tf" | awk -F: '{ total += $2 } END { print total + 0 }')"
if [[ "${wildcard_resources}" -ne 4 ]]; then
  printf 'Expected exactly 4 reviewed wildcard-resource statements, found %s.\n' "${wildcard_resources}" >&2
  exit 1
fi

# OIDC is audience-bound and only environment-scoped allowlisted repositories,
# identified by immutable owner and repository IDs, can assume the provisioning
# role. The only PassRole target is the runner.
require_pattern 'variable = "token.actions.githubusercontent.com:aud"[[:space:]]+values[[:space:]]+= \["sts.amazonaws.com"\]' "${iam_file}"
require_pattern 'repo:\$\{var.github_owner\}@\$\{var.github_owner_id\}/\$\{repository\}@\$\{repository_id\}:environment:\$\{var.github_environment\}' "${iam_file}"
require_pattern 'nix-aws-build-infra@\$\{var.allowed_repositories\["nix-aws-build-infra"\]\}:environment:\$\{var.github_environment\}' "${iam_file}"
require_pattern 'actions[[:space:]]+= \["iam:PassRole"\][[:space:]]+resources = \[aws_iam_role.runner.arn\]' "${iam_file}"

# The runner can read only its project secret/parameters and write only the
# dedicated cache bucket. CloudFront receives GetObject but no write action.
require_pattern 'actions[[:space:]]+= \["secretsmanager:GetSecretValue"\][[:space:]]+resources = \[aws_secretsmanager_secret.cache_signing_key.arn\]' "${iam_file}"
require_pattern 'resources = \["\$\{aws_s3_bucket.cache.arn\}/\*"\]' "${iam_file}"
require_pattern 'actions[[:space:]]+= \["s3:GetObject"\][[:space:]]+resources = \["\$\{aws_s3_bucket.cache.arn\}/\*"\]' "${cache_file}"
reject_pattern 'CloudFrontReadOnly[[:space:][:print:]]*s3:PutObject' "${cache_file}"

# Runtime builders deliberately expose no inbound port.
reject_pattern '(^|[[:space:]])ingress[[:space:]]*\{' "${network_file}"

printf 'Security policy assertions passed.\n'
