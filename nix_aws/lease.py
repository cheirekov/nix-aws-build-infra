from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from typing import Any

GLOBAL_KEY = {"pk": {"S": "GLOBAL"}}
DEFAULT_ORPHAN_GRACE_SECONDS = 300
ACTIVE_INSTANCE_STATES = {"pending", "running", "shutting-down", "stopping", "stopped"}
INACTIVE_FLEET_STATES = {"deleted"}

AwsCall = Callable[..., subprocess.CompletedProcess[str]]


class LeaseError(RuntimeError):
    pass


@dataclass(frozen=True)
class LeaseRecord:
    owner: str
    expires_at: int
    created_at: int
    lease_id: str = ""
    owner_kind: str = ""
    heartbeat_at: int = 0
    phase: str = ""
    instance_id: str = ""
    fleet_id: str = ""
    expiry_attribute: str = "lease_expires_at"

    @property
    def tag(self) -> tuple[str, str]:
        if self.owner_kind == "github" or self.owner.startswith("gha-"):
            return "GitHubRunId", self.owner.removeprefix("gha-")
        return "SessionId", self.owner


@dataclass(frozen=True)
class LeaseResources:
    instances: tuple[dict[str, str], ...]
    fleets: tuple[dict[str, str], ...]

    @property
    def active(self) -> bool:
        return bool(self.instances or self.fleets)


@dataclass(frozen=True)
class LeaseStatus:
    state: str
    now: int
    lease: LeaseRecord | None
    resources: LeaseResources
    recoverable: bool
    detail: str

    def as_dict(self) -> dict[str, Any]:
        return {
            "state": self.state,
            "now": self.now,
            "recoverable": self.recoverable,
            "detail": self.detail,
            "lease": asdict(self.lease) if self.lease else None,
            "resources": {
                "instances": list(self.resources.instances),
                "fleets": list(self.resources.fleets),
            },
        }


@dataclass(frozen=True)
class LeaseAcquisition:
    lease: LeaseRecord
    recovered: LeaseStatus | None


def _conditional_failure(exc: subprocess.CalledProcessError) -> bool:
    return "ConditionalCheckFailedException" in str(exc.stderr)


def _attribute(item: dict[str, Any], name: str, kind: str, default: str = "") -> str:
    value = item.get(name, {})
    if not isinstance(value, dict):
        return default
    raw = value.get(kind, default)
    return str(raw)


class LeaseManager:
    def __init__(
        self,
        aws: AwsCall,
        project: str,
        *,
        now: Callable[[], float] = time.time,
        orphan_grace_seconds: int = DEFAULT_ORPHAN_GRACE_SECONDS,
    ):
        self.aws = aws
        self.project = project
        self.now = now
        self.orphan_grace_seconds = orphan_grace_seconds

    def _json(self, *arguments: str) -> dict[str, Any]:
        result = self.aws(*arguments, "--output", "json")
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise LeaseError(f"AWS returned invalid JSON for {' '.join(arguments[:2])}") from exc
        if not isinstance(payload, dict):
            raise LeaseError(f"AWS returned a non-object for {' '.join(arguments[:2])}")
        return payload

    def get(self, table: str) -> LeaseRecord | None:
        payload = self._json(
            "dynamodb",
            "get-item",
            "--table-name",
            table,
            "--key",
            json.dumps(GLOBAL_KEY, separators=(",", ":")),
            "--consistent-read",
        )
        item = payload.get("Item")
        if not item:
            return None
        try:
            expiry_attribute = (
                "lease_expires_at" if "lease_expires_at" in item else "expires_at"
            )
            return LeaseRecord(
                owner=_attribute(item, "owner", "S"),
                expires_at=int(_attribute(item, expiry_attribute, "N")),
                created_at=int(_attribute(item, "created_at", "N")),
                lease_id=_attribute(item, "lease_id", "S"),
                owner_kind=_attribute(item, "owner_kind", "S"),
                heartbeat_at=int(_attribute(item, "heartbeat_at", "N", "0")),
                phase=_attribute(item, "phase", "S"),
                instance_id=_attribute(item, "instance_id", "S"),
                fleet_id=_attribute(item, "fleet_id", "S"),
                expiry_attribute=expiry_attribute,
            )
        except (TypeError, ValueError) as exc:
            raise LeaseError("global lease contains invalid DynamoDB attributes; refusing recovery") from exc

    def resources(self, lease: LeaseRecord | None = None) -> LeaseResources:
        owner_tag = lease.tag if lease else None
        filters = [{"Name": "tag:ManagedBy", "Values": [self.project]}]
        if owner_tag:
            filters.append({"Name": f"tag:{owner_tag[0]}", "Values": [owner_tag[1]]})
        instance_payload = self._json(
            "ec2",
            "describe-instances",
            "--filters",
            json.dumps(filters, separators=(",", ":")),
        )
        instances = []
        for reservation in instance_payload.get("Reservations", []):
            for instance in reservation.get("Instances", []):
                state = str(instance.get("State", {}).get("Name", "unknown"))
                if state in ACTIVE_INSTANCE_STATES:
                    instances.append(
                        {"instance_id": str(instance.get("InstanceId", "unknown")), "state": state}
                    )

        fleet_payload = self._json("ec2", "describe-fleets")
        fleets = []
        for fleet in fleet_payload.get("Fleets", []):
            tags = {str(tag.get("Key")): str(tag.get("Value")) for tag in fleet.get("Tags", [])}
            state = str(fleet.get("FleetState", "unknown"))
            if (
                tags.get("ManagedBy") == self.project
                and (owner_tag is None or tags.get(owner_tag[0]) == owner_tag[1])
                and state not in INACTIVE_FLEET_STATES
            ):
                fleets.append({"fleet_id": str(fleet.get("FleetId", "unknown")), "state": state})
        return LeaseResources(tuple(instances), tuple(fleets))

    def inspect(self, table: str) -> LeaseStatus:
        now = int(self.now())
        lease = self.get(table)
        if lease is None:
            resources = self.resources()
            if resources.active:
                return LeaseStatus(
                    "unleased-active",
                    now,
                    None,
                    resources,
                    False,
                    "project has active EC2 builder resources without a global lease; "
                    "refusing a second builder",
                )
            return LeaseStatus(
                "free", now, None, LeaseResources((), ()), True, "no global lease exists"
            )
        if not lease.owner:
            return LeaseStatus(
                "invalid",
                now,
                lease,
                LeaseResources((), ()),
                False,
                "lease has no owner; refusing recovery without manual DynamoDB investigation",
            )
        resources = self.resources(lease)
        if resources.active:
            return LeaseStatus(
                "active",
                now,
                lease,
                resources,
                False,
                f"owner {lease.owner} still has active EC2 instance or fleet resources",
            )
        if lease.expires_at <= now:
            return LeaseStatus(
                "expired",
                now,
                lease,
                resources,
                True,
                f"owner {lease.owner} is expired and has no active EC2 resources",
            )
        last_seen = max(lease.created_at, lease.heartbeat_at)
        recover_after = last_seen + self.orphan_grace_seconds
        if recover_after <= now:
            return LeaseStatus(
                "orphaned",
                now,
                lease,
                resources,
                True,
                f"owner {lease.owner} has no active EC2 resources or recent heartbeat",
            )
        return LeaseStatus(
            "provisioning",
            now,
            lease,
            resources,
            False,
            f"owner {lease.owner} has no EC2 resource yet; recovery is safe after {recover_after}",
        )

    @staticmethod
    def _snapshot_condition(lease: LeaseRecord) -> tuple[str, dict[str, Any], dict[str, Any]]:
        names = {"#owner": "owner"}
        values: dict[str, Any] = {
            ":owner": {"S": lease.owner},
            ":expires_at": {"N": str(lease.expires_at)},
            ":created_at": {"N": str(lease.created_at)},
        }
        parts = [
            "#owner = :owner",
            f"{lease.expiry_attribute} = :expires_at",
            "created_at = :created_at",
        ]
        for name, kind, value in (
            ("lease_id", "S", lease.lease_id),
            ("heartbeat_at", "N", str(lease.heartbeat_at) if lease.heartbeat_at else ""),
        ):
            if value:
                values[f":{name}"] = {kind: value}
                parts.append(f"{name} = :{name}")
            else:
                parts.append(f"attribute_not_exists({name})")
        return " AND ".join(parts), names, values

    def acquire(
        self,
        table: str,
        owner: str,
        owner_kind: str,
        expires_at: int,
    ) -> LeaseAcquisition:
        lease_id = uuid.uuid4().hex
        for _attempt in range(3):
            status = self.inspect(table)
            if not status.recoverable:
                raise LeaseError(f"global lease is {status.state}: {status.detail}")

            now = int(self.now())
            lease = LeaseRecord(
                owner=owner,
                owner_kind=owner_kind,
                lease_id=lease_id,
                expires_at=expires_at,
                created_at=now,
                heartbeat_at=now,
                phase="provisioning",
            )
            item = {
                "pk": {"S": "GLOBAL"},
                "owner": {"S": owner},
                "owner_kind": {"S": owner_kind},
                "lease_id": {"S": lease_id},
                "lease_expires_at": {"N": str(expires_at)},
                "created_at": {"N": str(now)},
                "heartbeat_at": {"N": str(now)},
                "phase": {"S": "provisioning"},
            }
            arguments = [
                "dynamodb",
                "put-item",
                "--table-name",
                table,
                "--item",
                json.dumps(item, separators=(",", ":")),
            ]
            if status.lease is None:
                arguments.extend(["--condition-expression", "attribute_not_exists(pk)"])
            else:
                condition, names, values = self._snapshot_condition(status.lease)
                arguments.extend(
                    [
                        "--condition-expression",
                        condition,
                        "--expression-attribute-names",
                        json.dumps(names, separators=(",", ":")),
                        "--expression-attribute-values",
                        json.dumps(values, separators=(",", ":")),
                    ]
                )
            try:
                self.aws(*arguments)
                return LeaseAcquisition(lease, status if status.lease else None)
            except subprocess.CalledProcessError as exc:
                if not _conditional_failure(exc):
                    raise
        latest = self.inspect(table)
        raise LeaseError(f"global lease changed concurrently; {latest.detail}; retry the command")

    def touch(
        self,
        table: str,
        owner: str,
        lease_id: str,
        phase: str,
        *,
        instance_id: str = "",
        fleet_id: str = "",
    ) -> None:
        now = int(self.now())
        names = {"#owner": "owner", "#phase": "phase"}
        values: dict[str, Any] = {
            ":owner": {"S": owner},
            ":lease_id": {"S": lease_id},
            ":heartbeat_at": {"N": str(now)},
            ":phase": {"S": phase},
        }
        assignments = ["heartbeat_at = :heartbeat_at", "#phase = :phase"]
        for name, value in (("instance_id", instance_id), ("fleet_id", fleet_id)):
            if value:
                values[f":{name}"] = {"S": value}
                assignments.append(f"{name} = :{name}")
        try:
            self.aws(
                "dynamodb",
                "update-item",
                "--table-name",
                table,
                "--key",
                json.dumps(GLOBAL_KEY, separators=(",", ":")),
                "--condition-expression",
                "#owner = :owner AND lease_id = :lease_id",
                "--update-expression",
                f"SET {', '.join(assignments)}",
                "--expression-attribute-names",
                json.dumps(names, separators=(",", ":")),
                "--expression-attribute-values",
                json.dumps(values, separators=(",", ":")),
            )
        except subprocess.CalledProcessError as exc:
            if _conditional_failure(exc):
                raise LeaseError("global lease ownership changed before EC2 launch; refusing to continue") from exc
            raise

    def release_owned(self, table: str, owner: str, lease_id: str) -> bool:
        status = self.inspect(table)
        lease = status.lease
        if lease is None:
            if status.resources.active:
                raise LeaseError(f"refusing cleanup completion: {status.detail}")
            return False
        if lease.owner != owner or (lease_id and lease.lease_id and lease.lease_id != lease_id):
            raise LeaseError(
                f"global lease now belongs to {lease.owner}; refusing to delete another owner's lease"
            )
        if status.resources.active:
            raise LeaseError(f"refusing lease release: {status.detail}")
        return self._delete_snapshot(table, lease)

    def force_release(self, table: str) -> LeaseStatus:
        status = self.inspect(table)
        if status.lease is None:
            if status.state != "free":
                raise LeaseError(f"refusing forced release: {status.detail}")
            return status
        if not status.recoverable:
            raise LeaseError(f"refusing forced release of {status.state} lease: {status.detail}")
        if not self._delete_snapshot(table, status.lease):
            raise LeaseError("lease disappeared before release")
        return status

    def _delete_snapshot(self, table: str, lease: LeaseRecord) -> bool:
        condition, names, values = self._snapshot_condition(lease)
        try:
            result = self.aws(
                "dynamodb",
                "delete-item",
                "--table-name",
                table,
                "--key",
                json.dumps(GLOBAL_KEY, separators=(",", ":")),
                "--condition-expression",
                condition,
                "--expression-attribute-names",
                json.dumps(names, separators=(",", ":")),
                "--expression-attribute-values",
                json.dumps(values, separators=(",", ":")),
                "--return-values",
                "ALL_OLD",
                "--output",
                "json",
            )
        except subprocess.CalledProcessError as exc:
            if _conditional_failure(exc):
                raise LeaseError("lease changed concurrently; no lease was released") from exc
            raise
        payload = json.loads(result.stdout or "{}")
        return bool(payload.get("Attributes"))


def _cli_aws(region: str) -> AwsCall:
    def call(*arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["aws", *arguments, "--region", region],
            check=check,
            text=True,
            capture_output=True,
        )

    return call


def main(argv: Sequence[str] | None = None) -> int:
    root = argparse.ArgumentParser(description="Safely manage the nix-aws global build lease")
    root.add_argument("--region", default=os.environ.get("AWS_REGION", "eu-central-1"))
    root.add_argument("--project", required=True)
    root.add_argument("--table", required=True)
    commands = root.add_subparsers(dest="command", required=True)
    acquire = commands.add_parser("acquire")
    acquire.add_argument("--owner", required=True)
    acquire.add_argument("--owner-kind", choices=("github", "local"), required=True)
    acquire.add_argument("--expires-at", required=True, type=int)
    touch = commands.add_parser("touch")
    touch.add_argument("--owner", required=True)
    touch.add_argument("--lease-id", required=True)
    touch.add_argument("--phase", required=True)
    touch.add_argument("--instance-id", default="")
    touch.add_argument("--fleet-id", default="")
    release = commands.add_parser("release")
    release.add_argument("--owner", required=True)
    release.add_argument("--lease-id", required=True)
    commands.add_parser("status")
    args = root.parse_args(argv)
    manager = LeaseManager(_cli_aws(args.region), args.project)
    try:
        if args.command == "acquire":
            acquired = manager.acquire(args.table, args.owner, args.owner_kind, args.expires_at)
            if acquired.recovered:
                print(
                    f"[lease] recovered {acquired.recovered.state} lease "
                    f"from {acquired.recovered.lease.owner}",
                    file=sys.stderr,
                )
            print(acquired.lease.lease_id)
        elif args.command == "touch":
            manager.touch(
                args.table,
                args.owner,
                args.lease_id,
                args.phase,
                instance_id=args.instance_id,
                fleet_id=args.fleet_id,
            )
        elif args.command == "release":
            manager.release_owned(args.table, args.owner, args.lease_id)
        else:
            print(json.dumps(manager.inspect(args.table).as_dict(), indent=2))
        return 0
    except (LeaseError, subprocess.CalledProcessError) as exc:
        print(f"lease-manager: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
