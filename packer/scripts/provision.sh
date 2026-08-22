#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y ca-certificates curl git jq unzip xz-utils zstd

aws_zip="/tmp/awscliv2.zip"
curl --fail --location --retry 5 \
  "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
  -o "${aws_zip}"
unzip -q "${aws_zip}" -d /tmp
sudo /tmp/aws/install --update

nix_installer="/tmp/install-nix-${NIX_VERSION}"
curl --fail --location --retry 5 \
  "https://releases.nixos.org/nix/nix-${NIX_VERSION}/install" \
  -o "${nix_installer}"
sudo sh "${nix_installer}" --daemon --yes

runner_archive="/tmp/actions-runner.tar.gz"
curl --fail --location --retry 5 \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  -o "${runner_archive}"
printf '%s  %s\n' "${RUNNER_SHA256}" "${runner_archive}" | sha256sum --check

sudo useradd --create-home --shell /bin/bash gha-runner
sudo install -d -o gha-runner -g gha-runner /opt/actions-runner-dist
sudo tar -xzf "${runner_archive}" -C /opt/actions-runner-dist
sudo /opt/actions-runner-dist/bin/installdependencies.sh

if snap list amazon-ssm-agent >/dev/null 2>&1; then
  sudo systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service
else
  ssm_deb="/tmp/amazon-ssm-agent.deb"
  curl --fail --location --retry 5 \
    "https://s3.${AWS_REGION}.amazonaws.com/amazon-ssm-${AWS_REGION}/latest/debian_amd64/amazon-ssm-agent.deb" \
    -o "${ssm_deb}"
  sudo dpkg -i "${ssm_deb}"
  sudo systemctl enable amazon-ssm-agent
fi

cloudwatch_deb="/tmp/amazon-cloudwatch-agent.deb"
curl --fail --location --retry 5 \
  "https://amazoncloudwatch-agent-${AWS_REGION}.s3.${AWS_REGION}.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb" \
  -o "${cloudwatch_deb}"
sudo dpkg -i "${cloudwatch_deb}"

sudo install -d -m 0755 /opt/nix-aws-build-infra/bin /etc/nix-aws-runner
sudo install -m 0755 /tmp/nix-aws-runtime/start-runner.sh /opt/nix-aws-build-infra/bin/start-runner.sh
sudo install -m 0755 /tmp/nix-aws-runtime/post-build-hook.sh /opt/nix-aws-build-infra/bin/post-build-hook.sh
sudo install -m 0644 /tmp/nix-aws-runtime/amazon-cloudwatch-agent.json /etc/nix-aws-runner/amazon-cloudwatch-agent.json
sudo install -m 0644 /tmp/nix-aws-runtime/nix-aws-runner.service /etc/systemd/system/nix-aws-runner.service
sudo sed -i "s/__PROJECT_NAME__/${PROJECT_NAME}/g" /etc/nix-aws-runner/amazon-cloudwatch-agent.json
printf '%s\n' "${PROJECT_NAME}" | sudo tee /etc/nix-aws-runner/project-name >/dev/null
sudo systemctl daemon-reload
sudo systemctl disable nix-aws-runner.service

sudo mkdir -p /etc/nix
sudo touch /etc/nix/nix.conf
sudo tee -a /etc/nix/nix.conf >/dev/null <<'EOF'
experimental-features = nix-command flakes
accept-flake-config = true
max-jobs = auto
cores = 0
trusted-users = root gha-runner
EOF

sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/* /tmp/aws /tmp/awscliv2.zip /tmp/actions-runner.tar.gz /tmp/nix-aws-runtime
