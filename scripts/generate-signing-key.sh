#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
key_kind="${1:-ci}"
secret_dir="${repo_root}/.secrets"
deployment_dir="${repo_root}/.deployment"

case "${key_kind}" in
  ci)
    key_name="${CACHE_KEY_NAME:-nix-aws-build-infra-1}"
    secret_key="${secret_dir}/cache-private-key"
    public_key="${deployment_dir}/cache-public-key.txt"
    ;;
  local)
    key_name="${LOCAL_CACHE_KEY_NAME:-nix-aws-local-1}"
    secret_key="${secret_dir}/cache-local-private-key"
    public_key="${deployment_dir}/cache-local-public-key.txt"
    ;;
  *)
    printf 'Usage: %s [ci|local]\n' "$0" >&2
    exit 2
    ;;
esac

mkdir -p "${secret_dir}"
chmod 700 "${secret_dir}"
mkdir -p "${deployment_dir}"
chmod 700 "${deployment_dir}"

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
