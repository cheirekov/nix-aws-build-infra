#!/usr/bin/env bash
set -euo pipefail

flake_attribute="${FLAKE_ATTRIBUTE:-default}"
verification_script="${VERIFICATION_SCRIPT:-}"
nix_profile=/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh

if [[ ! "${flake_attribute}" =~ ^[A-Za-z0-9._+/-]+$ ]]; then
  printf 'Invalid flake attribute: %s\n' "${flake_attribute}" >&2
  exit 2
fi

# shellcheck source=/dev/null
source /etc/nix-aws-runner/cache.env
export AWS_REGION

# GitHub launches self-hosted jobs in a non-login shell, so the multi-user Nix
# installer profile is not loaded automatically on a fresh runner.
if [[ -r "${nix_profile}" ]]; then
  # shellcheck source=/dev/null
  source "${nix_profile}"
fi
if ! command -v nix >/dev/null; then
  printf 'Nix is installed but is not available on PATH. Expected profile: %s\n' "${nix_profile}" >&2
  exit 127
fi

printf '[build] building .#%s\n' "${flake_attribute}"
nix build -L --accept-flake-config ".#${flake_attribute}"
result_path="$(readlink -f result)"
nix path-info -Sh "${result_path}"

if [[ -n "${verification_script}" ]]; then
  printf '[build] verifying with: %s\n' "${verification_script}"
  bash -euo pipefail -c "${verification_script}"
fi

printf '[build] uploading final closure to %s\n' "${NIX_CACHE_BUCKET}"
nix copy -L --to "${NIX_CACHE_STORE_URL}" "${result_path}"
nix path-info --store "${NIX_CACHE_URL}" "${result_path}"

printf 'BUILD_RESULT=%s\nCACHE_PUSH=ok\n' "${result_path}"
