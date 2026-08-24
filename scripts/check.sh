#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shellcheck "${repo_root}"/scripts/*.sh "${repo_root}"/packer/scripts/*.sh "${repo_root}"/packer/runtime/*.sh
shfmt -d -i 2 -ci "${repo_root}"/scripts/*.sh "${repo_root}"/packer/scripts/*.sh "${repo_root}"/packer/runtime/*.sh
# GitHub added job.workflow_repository/job.workflow_sha for reusable workflows
# after actionlint 1.7.12. Keep all other expression checks enabled while the
# pinned Nixpkgs version catches up.
actionlint \
  -ignore 'property "workflow_(repository|sha)" is not defined in object type' \
  "${repo_root}"/.github/workflows/*.yml
ruff check "${repo_root}/nix_aws" "${repo_root}/tests/unit"
python3 -m pytest -q "${repo_root}/tests/unit"
"${repo_root}/scripts/check-security.sh"
"${repo_root}/scripts/check-portability.sh"
tofu -chdir="${repo_root}/infra" fmt -check -recursive
tofu -chdir="${repo_root}/infra" init -backend=false -input=false
tofu -chdir="${repo_root}/infra" validate
pushd "${repo_root}/packer" >/dev/null
packer fmt -check -recursive .
packer init .
packer validate .
popd >/dev/null
nix flake check "path:${repo_root}" --all-systems --no-build
nix flake check "path:${repo_root}" --print-build-logs
