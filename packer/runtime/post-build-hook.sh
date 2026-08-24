#!/usr/bin/env bash
set -euo pipefail

[[ -n "${OUT_PATHS:-}" ]] || exit 0
# shellcheck source=/dev/null
source /etc/nix-aws-runner/cache.env
read -r -a output_paths <<<"${OUT_PATHS}"

{
  flock 9
  printf '%s\n' "${output_paths[@]}" >>"${NIX_AWS_BUILT_PATHS_FILE}"
} 9>>"${NIX_AWS_BUILT_PATHS_FILE}.lock"

printf '[post-build-hook] uploading outputs for %s\n' "${DRV_PATH:-unknown}" >&2
if ! env -u NIX_CONFIG /nix/var/nix/profiles/default/bin/nix \
  --extra-experimental-features 'nix-command flakes' \
  copy -L --no-recursive --to "${NIX_CACHE_STORE_URL}" "${output_paths[@]}"; then
  printf '[post-build-hook] cache upload failed for %s\n' "${DRV_PATH:-unknown}" >&2
fi
