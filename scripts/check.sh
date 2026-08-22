#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

shellcheck "${repo_root}"/scripts/*.sh "${repo_root}"/packer/scripts/*.sh "${repo_root}"/packer/runtime/*.sh
shfmt -d -i 2 -ci "${repo_root}"/scripts/*.sh "${repo_root}"/packer/scripts/*.sh "${repo_root}"/packer/runtime/*.sh
actionlint "${repo_root}"/.github/workflows/*.yml
"${repo_root}/scripts/check-security.sh"
tofu -chdir="${repo_root}/infra" fmt -check -recursive
tofu -chdir="${repo_root}/infra" init -backend=false -input=false
tofu -chdir="${repo_root}/infra" validate
pushd "${repo_root}/packer" >/dev/null
packer fmt -check -recursive .
packer init .
packer validate .
popd >/dev/null
nix flake check "${repo_root}" --print-build-logs
