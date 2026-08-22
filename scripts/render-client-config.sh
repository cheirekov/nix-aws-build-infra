#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cache_url="$(tofu -chdir="${repo_root}/infra" output -raw cache_url)"
public_key="$(tr -d '\r\n' <"${repo_root}/config/cache-public-key.txt")"

sed \
  -e "s|https://CLOUDFRONT_DOMAIN|${cache_url}|g" \
  -e "s|nix-aws-build-infra-1:PUBLIC_KEY|${public_key}|g" \
  "${repo_root}/examples/nixos.nix.template"
