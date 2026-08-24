#!/usr/bin/env bash
set -euo pipefail

aws_region="${AWS_REGION:-eu-central-1}"
github_repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
github_token="${GITHUB_APP_TOKEN:?GITHUB_APP_TOKEN is required}"
fleet_id="${FLEET_ID:-}"
instance_id="${INSTANCE_ID:-}"
launch_template_id="${LAUNCH_TEMPLATE_ID:-}"
runner_name="${RUNNER_NAME:-}"
ssm_parameter="${SSM_PARAMETER:-}"
lock_table="${LOCK_TABLE:-}"
lock_owner="${LOCK_OWNER:-}"

if [[ -n "${fleet_id}" ]]; then
  aws ec2 delete-fleets \
    --region "${aws_region}" \
    --fleet-ids "${fleet_id}" \
    --terminate-instances >/dev/null 2>&1 || true
fi
if [[ -n "${instance_id}" ]]; then
  aws ec2 terminate-instances --region "${aws_region}" --instance-ids "${instance_id}" >/dev/null 2>&1 || true
  aws ec2 wait instance-terminated --region "${aws_region}" --instance-ids "${instance_id}" 2>/dev/null || true
fi
if [[ -n "${launch_template_id}" ]]; then
  aws ec2 delete-launch-template --region "${aws_region}" --launch-template-id "${launch_template_id}" >/dev/null 2>&1 || true
fi
if [[ -n "${ssm_parameter}" ]]; then
  aws ssm delete-parameter --region "${aws_region}" --name "${ssm_parameter}" >/dev/null 2>&1 || true
fi
if [[ -n "${lock_table}" && -n "${lock_owner}" ]]; then
  aws dynamodb delete-item \
    --region "${aws_region}" \
    --table-name "${lock_table}" \
    --key '{"pk":{"S":"GLOBAL"}}' \
    --condition-expression '#owner = :owner' \
    --expression-attribute-names '{"#owner":"owner"}' \
    --expression-attribute-values "{\":owner\":{\"S\":\"${lock_owner}\"}}" >/dev/null 2>&1 || true
fi

if [[ -n "${runner_name}" ]]; then
  runner_id="$(curl --fail --silent --show-error \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${github_repository}/actions/runners?per_page=100" |
    jq -r --arg name "${runner_name}" '.runners[]? | select(.name==$name) | .id' | head -n1)"
  if [[ -n "${runner_id}" ]]; then
    curl --fail --silent --show-error \
      --request DELETE \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${github_token}" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com/repos/${github_repository}/actions/runners/${runner_id}"
  fi
fi

printf 'Cleanup complete for runner %s and instance %s\n' "${runner_name:-unknown}" "${instance_id:-unknown}"
