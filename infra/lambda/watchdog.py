import datetime
import os

import boto3
from botocore.exceptions import ClientError


PROJECT = os.environ["PROJECT_NAME"]
MAX_AGE = datetime.timedelta(hours=float(os.environ.get("MAX_AGE_HOURS", "12")))


def expired(timestamp, now):
    return timestamp is not None and now - timestamp > MAX_AGE


def handler(_event, _context):
    now = datetime.datetime.now(datetime.timezone.utc)
    ec2 = boto3.client("ec2")
    ssm = boto3.client("ssm")
    removed = {"instances": [], "fleets": [], "launch_templates": [], "parameters": []}

    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[
            {"Name": "tag:ManagedBy", "Values": [PROJECT]},
            {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )
    instance_ids = []
    for page in pages:
        for reservation in page["Reservations"]:
            for instance in reservation["Instances"]:
                if expired(instance.get("LaunchTime"), now):
                    instance_ids.append(instance["InstanceId"])
    if instance_ids:
        ec2.terminate_instances(InstanceIds=instance_ids)
        removed["instances"] = instance_ids

    for fleet in ec2.describe_fleets().get("Fleets", []):
        tags = {tag["Key"]: tag["Value"] for tag in fleet.get("Tags", [])}
        if tags.get("ManagedBy") == PROJECT and expired(fleet.get("CreateTime"), now):
            ec2.delete_fleets(FleetIds=[fleet["FleetId"]], TerminateInstances=True)
            removed["fleets"].append(fleet["FleetId"])

    paginator = ec2.get_paginator("describe_launch_templates")
    for page in paginator.paginate(Filters=[{"Name": "tag:ManagedBy", "Values": [PROJECT]}]):
        for template in page["LaunchTemplates"]:
            if expired(template.get("CreateTime"), now):
                try:
                    ec2.delete_launch_template(LaunchTemplateId=template["LaunchTemplateId"])
                    removed["launch_templates"].append(template["LaunchTemplateId"])
                except ClientError:
                    pass

    parameter_filter = [{"Key": "Name", "Option": "BeginsWith", "Values": [f"/{PROJECT}/runs/"]}]
    for page in ssm.get_paginator("describe_parameters").paginate(ParameterFilters=parameter_filter):
        for parameter in page["Parameters"]:
            if expired(parameter.get("LastModifiedDate"), now):
                ssm.delete_parameter(Name=parameter["Name"])
                removed["parameters"].append(parameter["Name"])

    print(removed)
    return removed
