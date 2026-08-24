import datetime
import os

import boto3
from botocore.exceptions import ClientError


PROJECT = os.environ["PROJECT_NAME"]
MAX_AGE = datetime.timedelta(hours=float(os.environ.get("MAX_AGE_HOURS", "12")))
KEEP_AMIS = int(os.environ.get("KEEP_AMIS_PER_ARCHITECTURE", "2"))
LOCK_TABLE = os.environ["LOCK_TABLE"]


def expired(timestamp, now):
    return timestamp is not None and now - timestamp > MAX_AGE


def handler(_event, _context):
    now = datetime.datetime.now(datetime.timezone.utc)
    ec2 = boto3.client("ec2")
    ssm = boto3.client("ssm")
    dynamodb = boto3.client("dynamodb")
    removed = {
        "instances": [],
        "fleets": [],
        "launch_templates": [],
        "parameters": [],
        "amis": [],
        "snapshots": [],
        "lease": False,
    }

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

    for prefix in (f"/{PROJECT}/runs/", f"/{PROJECT}/sessions/"):
        parameter_filter = [{"Key": "Name", "Option": "BeginsWith", "Values": [prefix]}]
        for page in ssm.get_paginator("describe_parameters").paginate(
            ParameterFilters=parameter_filter
        ):
            for parameter in page["Parameters"]:
                if expired(parameter.get("LastModifiedDate"), now):
                    ssm.delete_parameter(Name=parameter["Name"])
                    removed["parameters"].append(parameter["Name"])

    try:
        response = dynamodb.delete_item(
            TableName=LOCK_TABLE,
            Key={"pk": {"S": "GLOBAL"}},
            ConditionExpression="expires_at < :now",
            ExpressionAttributeValues={":now": {"N": str(int(now.timestamp()))}},
            ReturnValues="ALL_OLD",
        )
        removed["lease"] = bool(response.get("Attributes"))
    except dynamodb.exceptions.ConditionalCheckFailedException:
        pass

    images = ec2.describe_images(
        Owners=["self"],
        Filters=[
            {"Name": "tag:ManagedBy", "Values": [PROJECT]},
            {"Name": "tag:Purpose", "Values": ["github-actions-runner"]},
        ],
    ).get("Images", [])
    by_architecture = {}
    for image in images:
        by_architecture.setdefault(image["Architecture"], []).append(image)
    for architecture_images in by_architecture.values():
        architecture_images.sort(key=lambda image: image["CreationDate"], reverse=True)
        for image in architecture_images[KEEP_AMIS:]:
            snapshots = [
                mapping.get("Ebs", {}).get("SnapshotId")
                for mapping in image.get("BlockDeviceMappings", [])
            ]
            ec2.deregister_image(ImageId=image["ImageId"])
            removed["amis"].append(image["ImageId"])
            for snapshot_id in filter(None, snapshots):
                try:
                    ec2.delete_snapshot(SnapshotId=snapshot_id)
                    removed["snapshots"].append(snapshot_id)
                except ClientError:
                    pass

    print(removed)
    return removed
