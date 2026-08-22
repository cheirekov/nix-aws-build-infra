#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_name="${CACHE_KEY_NAME:-nix-aws-build-infra-1}"
secret_dir="${repo_root}/.secrets"
secret_key="${secret_dir}/cache-private-key"
public_key="${repo_root}/config/cache-public-key.txt"

mkdir -p "${secret_dir}"
chmod 700 "${secret_dir}"

if [[ -s "${public_key}" ]]; then
  if [[ -s "${secret_key}" ]]; then
    printf 'Existing signing key pair retained: %s\n' "${public_key}"
  else
    printf 'Existing public key retained; private key is expected in AWS Secrets Manager: %s\n' "${public_key}"
  fi
  exit 0
fi

if [[ -e "${secret_key}" ]]; then
  printf 'Refusing to generate a new public key over an unmatched private key: %s\n' "${secret_key}" >&2
  exit 1
fi

umask 077
nix-store --generate-binary-cache-key "${key_name}" "${secret_key}" "${public_key}"
chmod 600 "${secret_key}"
chmod 644 "${public_key}"
printf 'Generated public key: %s\n' "${public_key}"
printf 'Private key is temporary and ignored by Git: %s\n' "${secret_key}"
