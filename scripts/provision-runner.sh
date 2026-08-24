#!/usr/bin/env bash
set -euo pipefail

aws_region="${AWS_REGION:-eu-central-1}"
project_name="${PROJECT_NAME:-nix-aws-build-infra}"
github_token="${GITHUB_APP_TOKEN:?GITHUB_APP_TOKEN is required}"
github_repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
github_run_id="${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}"
github_run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
github_output="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
runner_profile="${RUNNER_PROFILE:-large-x86_64}"
run_key="${github_run_id}-${github_run_attempt}"
runner_name="nix-aws-${run_key}"
runner_label="nix-aws-run-${run_key}"
parameter_name="/${project_name}/runs/${run_key}"
launch_template_name="${project_name}-run-${run_key}"

case "${runner_profile}" in
  standard-x86_64)
    nix_system=x86_64-linux
    capacity_profile=standard
    github_arch=x64
    ;;
  large-x86_64)
    nix_system=x86_64-linux
    capacity_profile=large
    github_arch=x64
    ;;
  standard-aarch64)
    nix_system=aarch64-linux
    capacity_profile=standard
    github_arch=ARM64
    ;;
  large-aarch64)
    nix_system=aarch64-linux
    capacity_profile=large
    github_arch=ARM64
    ;;
  *)
    printf 'Unsupported runner profile: %s\n' "${runner_profile}" >&2
    exit 2
    ;;
esac

log() {
  printf '[provision] %s\n' "$*" >&2
}

api() {
  curl --fail --silent --show-error \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${github_token}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$@"
}

# Invoked indirectly by the ERR trap.
# shellcheck disable=SC2329
cleanup_partial() {
  local status=$?
  if [[ -n "${fleet_id:-}" ]]; then
    aws ec2 delete-fleets --region "${aws_region}" --fleet-ids "${fleet_id}" --terminate-instances >/dev/null 2>&1 || true
  elif [[ -n "${instance_id:-}" ]]; then
    aws ec2 terminate-instances --region "${aws_region}" --instance-ids "${instance_id}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${launch_template_id:-}" ]]; then
    aws ec2 delete-launch-template --region "${aws_region}" --launch-template-id "${launch_template_id}" >/dev/null 2>&1 || true
  fi
  aws ssm delete-parameter --region "${aws_region}" --name "${parameter_name}" >/dev/null 2>&1 || true
  if [[ -n "${lock_table:-}" ]]; then
    aws dynamodb delete-item \
      --region "${aws_region}" \
      --table-name "${lock_table}" \
      --key '{"pk":{"S":"GLOBAL"}}' \
      --condition-expression '#owner = :owner' \
      --expression-attribute-names '{"#owner":"owner"}' \
      --expression-attribute-values "{\":owner\":{\"S\":\"${lock_owner}\"}}" >/dev/null 2>&1 || true
  fi
  return "${status}"
}
trap cleanup_partial ERR

log "requesting one-hour registration token for ${github_repository}"
registration_token="$(api \
  --request POST \
  "https://api.github.com/repos/${github_repository}/actions/runners/registration-token" | jq -er .token)"

provisioner_config="$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${project_name}/config/provisioner" \
  --query Parameter.Value \
  --output text)"
lock_table="$(jq -er .build_lock_table <<<"${provisioner_config}")"
lock_owner="gha-${run_key}"
lock_expires_at="$(($(date +%s) + 43200))"
aws dynamodb put-item \
  --region "${aws_region}" \
  --table-name "${lock_table}" \
  --item "{\"pk\":{\"S\":\"GLOBAL\"},\"owner\":{\"S\":\"${lock_owner}\"},\"expires_at\":{\"N\":\"${lock_expires_at}\"},\"created_at\":{\"N\":\"$(date +%s)\"}}" \
  --condition-expression 'attribute_not_exists(pk) OR expires_at < :now' \
  --expression-attribute-values "{\":now\":{\"N\":\"$(date +%s)\"}}" >/dev/null
printf 'lock_table=%s\nlock_owner=%s\n' "${lock_table}" "${lock_owner}" >>"${github_output}"

ami_id="$(aws ssm get-parameter \
  --region "${aws_region}" \
  --name "/${project_name}/ami/${nix_system}" \
  --query Parameter.Value \
  --output text)"
if [[ ! "${ami_id}" =~ ^ami-[[:xdigit:]]+$ ]]; then
  printf 'Builder AMI is not ready: %s\n' "${ami_id}" >&2
  exit 1
fi

instance_profile="$(jq -er .instance_profile_name <<<"${provisioner_config}")"
kms_key_id="$(jq -er .kms_key_id <<<"${provisioner_config}")"
security_group_id="$(jq -er .runner_security_group_id <<<"${provisioner_config}")"
subnet_ids="$(jq -ec .runner_subnet_ids <<<"${provisioner_config}")"
root_volume_gb="$(jq -er .root_volume_gb <<<"${provisioner_config}")"
root_volume_iops="$(jq -er .root_volume_iops <<<"${provisioner_config}")"
root_volume_throughput="$(jq -er .root_volume_throughput <<<"${provisioner_config}")"
profile_config="$(jq -ec --arg system "${nix_system}" --arg profile "${capacity_profile}" '.profiles[$system][$profile]' <<<"${provisioner_config}")"
instance_types="$(jq -ec .instance_types <<<"${profile_config}")"
root_volume_gb="$(jq -er .root_volume_gb <<<"${profile_config}")"
root_volume_iops="$(jq -er .root_volume_iops <<<"${profile_config}")"
root_volume_throughput="$(jq -er .root_volume_throughput <<<"${profile_config}")"

run_config="$(jq -cn \
  --arg repository_url "https://github.com/${github_repository}" \
  --arg registration_token "${registration_token}" \
  --arg runner_name "${runner_name}" \
  --arg runner_labels "nix-aws,${runner_profile},${runner_label}" \
  '{mode:"github-runner",repository_url:$repository_url,registration_token:$registration_token,runner_name:$runner_name,runner_labels:$runner_labels}')"
aws ssm put-parameter \
  --region "${aws_region}" \
  --name "${parameter_name}" \
  --description "One-time GitHub runner configuration for ${github_repository} run ${run_key}" \
  --type SecureString \
  --key-id "${kms_key_id}" \
  --value "${run_config}" \
  --overwrite >/dev/null
unset run_config registration_token

user_data="$(printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  "printf '%s\\n' '${aws_region}' > /etc/nix-aws-runner/aws-region" \
  "printf '%s\\n' '${parameter_name}' > /etc/nix-aws-runner/run-parameter" \
  'systemctl enable --now nix-aws-runner.service' | base64 -w0)"

launch_data="$(jq -cn \
  --arg ami_id "${ami_id}" \
  --arg instance_profile "${instance_profile}" \
  --arg project_name "${project_name}" \
  --arg run_key "${run_key}" \
  --arg runner_name "${runner_name}" \
  --arg security_group_id "${security_group_id}" \
  --arg user_data "${user_data}" \
  --argjson root_volume_gb "${root_volume_gb}" \
  --argjson root_volume_iops "${root_volume_iops}" \
  --argjson root_volume_throughput "${root_volume_throughput}" \
  '{
    ImageId:$ami_id,
    IamInstanceProfile:{Name:$instance_profile},
    SecurityGroupIds:[$security_group_id],
    UserData:$user_data,
    MetadataOptions:{HttpTokens:"required",HttpEndpoint:"enabled",HttpPutResponseHopLimit:1},
    InstanceInitiatedShutdownBehavior:"terminate",
    BlockDeviceMappings:[{DeviceName:"/dev/sda1",Ebs:{DeleteOnTermination:true,Encrypted:true,VolumeType:"gp3",VolumeSize:$root_volume_gb,Iops:$root_volume_iops,Throughput:$root_volume_throughput}}],
    TagSpecifications:[
      {ResourceType:"instance",Tags:[{Key:"Name",Value:$runner_name},{Key:"ManagedBy",Value:$project_name},{Key:"Project",Value:$project_name},{Key:"GitHubRunId",Value:$run_key},{Key:"RunnerName",Value:$runner_name}]},
      {ResourceType:"volume",Tags:[{Key:"Name",Value:$runner_name},{Key:"ManagedBy",Value:$project_name},{Key:"Project",Value:$project_name},{Key:"GitHubRunId",Value:$run_key}]}
    ]
  }')"

launch_template_id="$(aws ec2 create-launch-template \
  --region "${aws_region}" \
  --launch-template-name "${launch_template_name}" \
  --tag-specifications "ResourceType=launch-template,Tags=[{Key=ManagedBy,Value=${project_name}},{Key=Project,Value=${project_name}},{Key=GitHubRunId,Value=${run_key}}]" \
  --launch-template-data "${launch_data}" \
  --query LaunchTemplate.LaunchTemplateId \
  --output text)"
printf 'launch_template_id=%s\n' "${launch_template_id}" >>"${github_output}"

overrides="$(jq -cn --argjson types "${instance_types}" --argjson subnets "${subnet_ids}" \
  '[$subnets[] as $subnet | $types[] | {SubnetId:$subnet,InstanceType:.}]')"
fleet_config="$(jq -cn \
  --arg launch_template_id "${launch_template_id}" \
  --arg project_name "${project_name}" \
  --arg run_key "${run_key}" \
  --argjson overrides "${overrides}" \
  '{
    Type:"instant",
    SpotOptions:{AllocationStrategy:"price-capacity-optimized",InstanceInterruptionBehavior:"terminate"},
    TargetCapacitySpecification:{TotalTargetCapacity:1,DefaultTargetCapacityType:"spot"},
    LaunchTemplateConfigs:[{LaunchTemplateSpecification:{LaunchTemplateId:$launch_template_id,Version:"$Latest"},Overrides:$overrides}],
    TagSpecifications:[{ResourceType:"fleet",Tags:[{Key:"ManagedBy",Value:$project_name},{Key:"Project",Value:$project_name},{Key:"GitHubRunId",Value:$run_key}]}]
  }')"

fleet_output="$(aws ec2 create-fleet --region "${aws_region}" --cli-input-json "${fleet_config}")"
fleet_id="$(jq -er .FleetId <<<"${fleet_output}")"
instance_id="$(jq -er '.Instances[0].InstanceIds[0]' <<<"${fleet_output}")"
printf 'fleet_id=%s\ninstance_id=%s\n' "${fleet_id}" "${instance_id}" >>"${github_output}"

log "waiting for ${instance_id}"
aws ec2 wait instance-running --region "${aws_region}" --instance-ids "${instance_id}"

deadline=$((SECONDS + 900))
while ((SECONDS < deadline)); do
  runner_status="$(api "https://api.github.com/repos/${github_repository}/actions/runners?per_page=100" |
    jq -r --arg name "${runner_name}" '.runners[]? | select(.name==$name) | .status' | head -n1)"
  if [[ "${runner_status}" == "online" ]]; then
    runs_on="$(jq -cn --arg arch "${github_arch}" --arg label "${runner_label}" '["self-hosted","linux",$arch,$label]')"
    printf 'runner_name=%s\nrunner_label=%s\nruns_on=%s\nssm_parameter=%s\n' \
      "${runner_name}" "${runner_label}" "${runs_on}" "${parameter_name}" >>"${github_output}"
    trap - ERR
    log "runner ${runner_name} is online"
    exit 0
  fi
  sleep 10
done

printf 'Runner %s did not become online within 15 minutes\n' "${runner_name}" >&2
exit 1
