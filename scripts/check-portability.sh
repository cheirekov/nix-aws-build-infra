#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generic_paths=(
  "${repo_root}/.github"
  "${repo_root}/docs"
  "${repo_root}/examples"
  "${repo_root}/infra"
  "${repo_root}/nix_aws"
  "${repo_root}/packer"
  "${repo_root}/scripts"
  "${repo_root}/tests"
  "${repo_root}/README.md"
  "${repo_root}/deployment.example.tfvars.json"
  "${repo_root}/flake.nix"
)

reject() {
  local description="$1"
  local pattern="$2"
  if rg --hidden --glob '!check-portability.sh' --quiet "${pattern}" "${generic_paths[@]}"; then
    printf 'Portability check failed (%s):\n' "${description}" >&2
    rg --hidden --glob '!check-portability.sh' --line-number "${pattern}" "${generic_paths[@]}" >&2
    exit 1
  fi
}

# Tenant-specific values are permitted only in an explicitly named public
# reference deployment under deployments/. Generic code and documentation must
# remain usable by a fork without editing source files.
reject 'reference owner leaked into generic files' 'cheirekov'
reject 'reference numeric IDs leaked into generic files' '16937955|1340587597|1342757814|4682343'
reject 'reference cache endpoint leaked into generic files' 'd387h9bqwrf18p\.cloudfront\.net'
reject 'reference cache key leaked into generic files' 'cU3u9sqlj9HCxWPQtV\+jDuoFk7bPB5Ckru7DO4/ELvs'
reject 'unpinned reusable workflow example' 'uses:[[:space:]]+[^[:space:]]+/nix-aws-build-infra/\.github/workflows/nix-build\.yml@main'
reject 'automatic infrastructure apply' 'tofu([^\n]*)apply([^\n]*)-auto-approve'

rg --quiet 'repository: \$\{\{ job\.workflow_repository \}\}' \
  "${repo_root}/.github/workflows/nix-build.yml"
rg --quiet 'ref: \$\{\{ job\.workflow_sha \}\}' \
  "${repo_root}/.github/workflows/nix-build.yml"
rg --quiet 'variable "github_owner"' "${repo_root}/infra/variables.tf"
rg --quiet 'variable "allowed_repositories"' "${repo_root}/infra/variables.tf"
rg --quiet '^\.deployment/$' "${repo_root}/.gitignore"
rg --quiet '^\.secrets/$' "${repo_root}/.gitignore"

while IFS= read -r -d '' reference; do
  jq -e '
    (.github_owner | type == "string" and length > 0) and
    (.github_owner_id | type == "number") and
    (.aws_region | test("^[a-z0-9-]+-[0-9]+$")) and
    (.project_name | test("^[a-z][a-z0-9-]{1,22}[a-z0-9]$")) and
    (.infra_repository_name | type == "string" and length > 0) and
    (.allowed_repositories | type == "object") and
    (all(.allowed_repositories | keys[]; test("^[A-Za-z0-9_.-]+$"))) and
    (.allowed_repositories[.infra_repository_name] | type == "number") and
    (.cache_url | startswith("https://")) and
    (.cache_public_keys | type == "array" and length > 0) and
    (all(.cache_public_keys[]; test("^[^:]+:[A-Za-z0-9+/=]+$")))
  ' "${reference}" >/dev/null
done < <(find "${repo_root}/deployments" -mindepth 2 -maxdepth 2 -name public.json -print0)

printf 'Portability assertions passed.\n'
