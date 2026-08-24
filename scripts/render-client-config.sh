#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
deployment_dir="${repo_root}/.deployment"
cache_url="$(tofu -chdir="${repo_root}/infra" output -raw cache_url)"
public_key="$(tr -d '\r\n' <"${deployment_dir}/cache-public-key.txt")"
local_public_key="$(tr -d '\r\n' <"${deployment_dir}/cache-local-public-key.txt")"

sed \
  -e "s|https://CLOUDFRONT_DOMAIN|${cache_url}|g" \
  -e "s|CI_CACHE_PUBLIC_KEY|${public_key}|g" \
  -e "s|LOCAL_CACHE_PUBLIC_KEY|${local_public_key}|g" \
  "${repo_root}/examples/nixos.nix.template"
