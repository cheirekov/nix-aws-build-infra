#!/usr/bin/env bash
set -euo pipefail

log_file=/var/log/nix-aws-runner.log
exec > >(tee -a "${log_file}") 2>&1

project_name="$(</etc/nix-aws-runner/project-name)"
aws_region="$(</etc/nix-aws-runner/aws-region)"
run_parameter="$(</etc/nix-aws-runner/run-parameter)"

log() {
  printf '[runner-bootstrap] %s\n' "$*"
}

log "loading one-time configuration ${run_parameter}"
run_config="$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "${run_parameter}" \
  --with-decryption \
  --query Parameter.Value \
  --output text)"

repository_url="$(jq -er .repository_url <<<"${run_config}")"
registration_token="$(jq -er .registration_token <<<"${run_config}")"
runner_name="$(jq -er .runner_name <<<"${run_config}")"
runner_labels="$(jq -er .runner_labels <<<"${run_config}")"
nix_bin_dir=/nix/var/nix/profiles/default/bin

if [[ ! -x "${nix_bin_dir}/nix" ]]; then
  log "Nix executable is missing from ${nix_bin_dir}"
  exit 1
fi
runner_path="${nix_bin_dir}:${PATH}"

provisioner_config="$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${project_name}/config/provisioner" \
  --query Parameter.Value \
  --output text)"
cache_public_key="$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${project_name}/config/cache-public-key" \
  --query Parameter.Value \
  --output text)"

cache_bucket="$(jq -er .cache_bucket <<<"${provisioner_config}")"
cache_url="$(jq -er .cache_url <<<"${provisioner_config}")"
signing_secret="$(jq -er .cache_signing_secret_arn <<<"${provisioner_config}")"
signing_key_file=/run/nix-cache-signing-key

aws secretsmanager get-secret-value \
  --region "${aws_region}" \
  --secret-id "${signing_secret}" \
  --query SecretString \
  --output text >"${signing_key_file}"
chown root:gha-runner "${signing_key_file}"
chmod 0640 "${signing_key_file}"

cache_store_url="s3://${cache_bucket}?region=${aws_region}&compression=zstd&parallel-compression=true&write-nar-listing=true&secret-key=${signing_key_file}"
install -m 0644 /dev/null /etc/nix-aws-runner/cache.env
{
  printf 'AWS_REGION=%q\n' "${aws_region}"
  printf 'NIX_CACHE_BUCKET=%q\n' "${cache_bucket}"
  printf 'NIX_CACHE_URL=%q\n' "${cache_url}"
  printf 'NIX_CACHE_PUBLIC_KEY=%q\n' "${cache_public_key}"
  printf 'NIX_CACHE_SIGNING_KEY_FILE=%q\n' "${signing_key_file}"
  printf 'NIX_CACHE_STORE_URL=%q\n' "${cache_store_url}"
} >/etc/nix-aws-runner/cache.env

cat >>/etc/nix/nix.conf <<EOF
substituters = ${cache_url} https://cache.nixos.org
trusted-public-keys = ${cache_public_key} cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
post-build-hook = /opt/nix-aws-build-infra/bin/post-build-hook.sh
narinfo-cache-negative-ttl = 0
EOF
systemctl restart nix-daemon.service

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -s \
  -c file:/etc/nix-aws-runner/amazon-cloudwatch-agent.json

# The registration token is useful once; remove its encrypted parameter before
# any repository code starts executing.
aws ssm delete-parameter --region "${aws_region}" --name "${run_parameter}"
unset run_config

rm -rf /opt/actions-runner
cp -a /opt/actions-runner-dist /opt/actions-runner
chown -R gha-runner:gha-runner /opt/actions-runner

log "registering ${runner_name} for ${repository_url}"
runuser -u gha-runner -- env PATH="${runner_path}" /opt/actions-runner/config.sh \
  --unattended \
  --ephemeral \
  --disableupdate \
  --url "${repository_url}" \
  --token "${registration_token}" \
  --name "${runner_name}" \
  --labels "${runner_labels}" \
  --work _work
unset registration_token

log "starting one-job runner"
set +e
runuser -u gha-runner -- env PATH="${runner_path}" /opt/actions-runner/run.sh
runner_status=$?
set -e

log "runner exited with status ${runner_status}; shutting down"
shutdown -h now
exit "${runner_status}"
