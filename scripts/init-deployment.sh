#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deployment_dir="${repo_root}/.deployment"
tfvars_file="${deployment_dir}/terraform.tfvars.json"
reference=""
github_owner=""
infra_repository="nix-aws-build-infra"
aws_region="eu-central-1"
project_name="nix-aws-build-infra"
monthly_budget_usd=25
repositories=()

usage() {
  cat <<'EOF'
Usage:
  init-deployment.sh --reference NAME
  init-deployment.sh --github-owner OWNER [options]

Options:
  --infra-repository NAME   Infrastructure repository (default: nix-aws-build-infra)
  --repository NAME         Allowlisted build repository; repeat as needed
  --region REGION           AWS region (default: eu-central-1)
  --project-name NAME       AWS resource prefix (default: nix-aws-build-infra)
  --monthly-budget-usd USD  Monthly soft budget (default: 25)

The command performs GitHub read-only discovery and writes only ignored local
files under .deployment/ and .secrets/. It never creates AWS resources.
EOF
}

while (($#)); do
  case "$1" in
    --reference)
      reference="${2:?--reference requires a name}"
      shift 2
      ;;
    --github-owner)
      github_owner="${2:?--github-owner requires a value}"
      shift 2
      ;;
    --infra-repository)
      infra_repository="${2:?--infra-repository requires a value}"
      shift 2
      ;;
    --repository)
      repositories+=("${2:?--repository requires a value}")
      shift 2
      ;;
    --region)
      aws_region="${2:?--region requires a value}"
      shift 2
      ;;
    --project-name)
      project_name="${2:?--project-name requires a value}"
      shift 2
      ;;
    --monthly-budget-usd)
      monthly_budget_usd="${2:?--monthly-budget-usd requires a value}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for command in jq nix-store; do
  command -v "${command}" >/dev/null || {
    printf 'Missing command %s; run inside nix develop.\n' "${command}" >&2
    exit 1
  }
done

if [[ -n "${reference}" && -n "${github_owner}" ]]; then
  printf 'Use --reference or --github-owner, not both.\n' >&2
  exit 2
fi
if [[ -n "${reference}" && ! "${reference}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  printf 'Invalid reference deployment name: %s\n' "${reference}" >&2
  exit 2
fi
if [[ -n "${github_owner}" && ! "${github_owner}" =~ ^[A-Za-z0-9-]+$ ]]; then
  printf 'Invalid GitHub owner: %s\n' "${github_owner}" >&2
  exit 2
fi
if [[ ! "${infra_repository}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  printf 'Invalid infrastructure repository name: %s\n' "${infra_repository}" >&2
  exit 2
fi
for repository in "${repositories[@]}"; do
  if [[ ! "${repository}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    printf 'Invalid build repository name: %s\n' "${repository}" >&2
    exit 2
  fi
done
if ((${#project_name} < 3 || ${#project_name} > 24)) ||
  [[ ! "${project_name}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
  printf 'Project name must be 3-24 lowercase letters, digits or hyphens: %s\n' "${project_name}" >&2
  exit 2
fi
if [[ ! "${aws_region}" =~ ^[a-z0-9-]+-[0-9]+$ ]]; then
  printf 'Invalid AWS region: %s\n' "${aws_region}" >&2
  exit 2
fi
if ! jq -en --arg value "${monthly_budget_usd}" '$value | tonumber > 0' >/dev/null 2>&1; then
  printf 'Monthly budget must be a positive number: %s\n' "${monthly_budget_usd}" >&2
  exit 2
fi

if [[ -e "${tfvars_file}" ]]; then
  printf 'Deployment is already initialized: %s\n' "${tfvars_file}" >&2
  printf 'Move the existing .deployment directory aside before initializing another deployment.\n' >&2
  exit 1
fi

install -d -m 0700 "${deployment_dir}"

if [[ -n "${reference}" ]]; then
  reference_file="${repo_root}/deployments/${reference}/public.json"
  if [[ ! -f "${reference_file}" ]]; then
    printf 'Unknown reference deployment: %s\n' "${reference}" >&2
    exit 1
  fi
  jq '{aws_region, project_name, github_owner, github_owner_id, infra_repository_name, allowed_repositories, monthly_budget_usd}' \
    "${reference_file}" >"${tfvars_file}"
  jq -er '.cache_public_keys[0]' "${reference_file}" >"${deployment_dir}/cache-public-key.txt"
  if [[ "$(jq '.cache_public_keys | length' "${reference_file}")" -gt 1 ]]; then
    jq -er '.cache_public_keys[1]' "${reference_file}" >"${deployment_dir}/cache-local-public-key.txt"
  fi
else
  if [[ -z "${github_owner}" ]]; then
    printf 'Use either --reference NAME or --github-owner OWNER.\n' >&2
    exit 2
  fi
  command -v gh >/dev/null || {
    printf 'Missing command gh; run inside nix develop and authenticate with gh auth login.\n' >&2
    exit 1
  }

  github_owner_id="$(gh api "users/${github_owner}" --jq .id)"
  all_repositories=("${infra_repository}" "${repositories[@]}")
  allowed_repositories='{}'
  seen='|'
  for repository in "${all_repositories[@]}"; do
    if [[ "${seen}" == *"|${repository}|"* ]]; then
      continue
    fi
    seen+="${repository}|"
    repository_id="$(gh api "repos/${github_owner}/${repository}" --jq .id)"
    oidc="$(gh api "repos/${github_owner}/${repository}/actions/oidc/customization/sub")"
    expected_prefix="repo:${github_owner}@${github_owner_id}/${repository}@${repository_id}"
    actual_prefix="$(jq -r '.sub_claim_prefix // ""' <<<"${oidc}")"
    if [[ "${actual_prefix}" != "${expected_prefix}" ]]; then
      printf 'Repository %s does not use immutable OIDC subjects.\n' "${repository}" >&2
      printf 'Enable immutable subjects in GitHub before creating AWS trust.\n' >&2
      exit 1
    fi
    allowed_repositories="$(jq -c --arg name "${repository}" --argjson id "${repository_id}" '. + {($name): $id}' <<<"${allowed_repositories}")"
  done

  jq -n \
    --arg aws_region "${aws_region}" \
    --arg project_name "${project_name}" \
    --arg github_owner "${github_owner}" \
    --argjson github_owner_id "${github_owner_id}" \
    --arg infra_repository_name "${infra_repository}" \
    --argjson allowed_repositories "${allowed_repositories}" \
    --argjson monthly_budget_usd "${monthly_budget_usd}" \
    '{aws_region:$aws_region,project_name:$project_name,github_owner:$github_owner,github_owner_id:$github_owner_id,infra_repository_name:$infra_repository_name,allowed_repositories:$allowed_repositories,monthly_budget_usd:$monthly_budget_usd}' \
    >"${tfvars_file}"
fi

chmod 0600 "${tfvars_file}"
[[ ! -f "${deployment_dir}/cache-public-key.txt" ]] || chmod 0644 "${deployment_dir}/cache-public-key.txt"
[[ ! -f "${deployment_dir}/cache-local-public-key.txt" ]] || chmod 0644 "${deployment_dir}/cache-local-public-key.txt"

"${repo_root}/scripts/generate-signing-key.sh" ci
"${repo_root}/scripts/generate-signing-key.sh" local

printf 'Deployment initialized: %s\n' "${tfvars_file}"
printf 'Next: export NIX_AWS_INFRA_PROFILE=... and run scripts/bootstrap-state.sh\n'
