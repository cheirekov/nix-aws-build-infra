from __future__ import annotations

import json
import subprocess
from typing import Any

import pytest

from nix_aws.lease import LeaseError, LeaseManager


def lease_item(
    owner: str,
    *,
    expires_at: int,
    created_at: int,
    lease_id: str = "lease-old",
    heartbeat_at: int | None = None,
) -> dict[str, Any]:
    item = {
        "pk": {"S": "GLOBAL"},
        "owner": {"S": owner},
        "owner_kind": {"S": "local"},
        "lease_id": {"S": lease_id},
        "expires_at": {"N": str(expires_at)},
        "created_at": {"N": str(created_at)},
    }
    if heartbeat_at is not None:
        item["heartbeat_at"] = {"N": str(heartbeat_at)}
    return item


class FakeAws:
    def __init__(
        self,
        item: dict[str, Any] | None,
        *,
        instance_state: str | None = None,
        fleet_state: str | None = None,
    ):
        self.item = item
        self.instance_state = instance_state
        self.fleet_state = fleet_state
        self.calls: list[tuple[str, ...]] = []
        self.concurrent_item: dict[str, Any] | None = None

    @staticmethod
    def completed(arguments: tuple[str, ...], payload: dict[str, Any]) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(arguments, 0, stdout=json.dumps(payload), stderr="")

    def __call__(self, *arguments: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        self.calls.append(arguments)
        operation = arguments[:2]
        if operation == ("dynamodb", "get-item"):
            return self.completed(arguments, {"Item": self.item} if self.item else {})
        if operation == ("ec2", "describe-instances"):
            instances = []
            if self.instance_state:
                instances = [{"InstanceId": "i-owner", "State": {"Name": self.instance_state}}]
            return self.completed(arguments, {"Reservations": [{"Instances": instances}]})
        if operation == ("ec2", "describe-fleets"):
            fleets = []
            if self.fleet_state and self.item:
                owner = self.item["owner"]["S"]
                fleets = [
                    {
                        "FleetId": "fleet-owner",
                        "FleetState": self.fleet_state,
                        "Tags": [
                            {"Key": "ManagedBy", "Value": "project"},
                            {"Key": "SessionId", "Value": owner},
                        ],
                    }
                ]
            return self.completed(arguments, {"Fleets": fleets})
        if operation == ("dynamodb", "put-item"):
            if self.concurrent_item is not None:
                self.item = self.concurrent_item
                self.concurrent_item = None
                self.instance_state = "running"
                raise subprocess.CalledProcessError(
                    255,
                    arguments,
                    stderr="ConditionalCheckFailedException: lease changed",
                )
            item_index = arguments.index("--item") + 1
            self.item = json.loads(arguments[item_index])
            return self.completed(arguments, {})
        if operation == ("dynamodb", "delete-item"):
            old = self.item
            self.item = None
            return self.completed(arguments, {"Attributes": old} if old else {})
        raise AssertionError(f"unexpected AWS call: {arguments}")


def manager(fake: FakeAws, now: int = 1_000) -> LeaseManager:
    return LeaseManager(fake, "project", now=lambda: now, orphan_grace_seconds=300)


def test_active_expired_lease_is_never_recovered() -> None:
    fake = FakeAws(lease_item("active-owner", expires_at=900, created_at=100), instance_state="running")
    leases = manager(fake)

    status = leases.inspect("locks")
    assert status.state == "active"
    assert status.recoverable is False
    with pytest.raises(LeaseError, match="still has active EC2"):
        leases.acquire("locks", "new-owner", "local", 2_000)
    assert not any(call[:2] == ("dynamodb", "put-item") for call in fake.calls)


def test_unleased_active_builder_blocks_acquisition() -> None:
    fake = FakeAws(None, instance_state="running")

    with pytest.raises(LeaseError, match="active EC2 builder resources without a global lease"):
        manager(fake).acquire("locks", "new-owner", "local", 2_000)
    assert not any(call[:2] == ("dynamodb", "put-item") for call in fake.calls)


def test_expired_inactive_lease_is_conditionally_recovered() -> None:
    fake = FakeAws(lease_item("expired-owner", expires_at=900, created_at=100, heartbeat_at=200))
    acquired = manager(fake).acquire("locks", "new-owner", "local", 2_000)

    assert acquired.recovered is not None
    assert acquired.recovered.state == "expired"
    assert fake.item["owner"] == {"S": "new-owner"}
    assert fake.item["lease_expires_at"] == {"N": "2000"}
    assert "expires_at" not in fake.item
    put = next(call for call in fake.calls if call[:2] == ("dynamodb", "put-item"))
    condition = put[put.index("--condition-expression") + 1]
    assert "lease_id = :lease_id" in condition
    assert "heartbeat_at = :heartbeat_at" in condition
    assert "expires_at <" not in condition


def test_orphaned_unexpired_lease_is_automatically_recovered() -> None:
    fake = FakeAws(lease_item("orphan-owner", expires_at=2_000, created_at=100, heartbeat_at=200))
    acquired = manager(fake).acquire("locks", "new-owner", "local", 2_000)

    assert acquired.recovered is not None
    assert acquired.recovered.state == "orphaned"
    assert acquired.lease.owner == "new-owner"


def test_recent_heartbeat_prevents_orphan_recovery() -> None:
    fake = FakeAws(lease_item("launching-owner", expires_at=2_000, created_at=100, heartbeat_at=900))

    with pytest.raises(LeaseError, match="recovery is safe after 1200"):
        manager(fake).acquire("locks", "new-owner", "local", 2_000)
    assert fake.item["owner"] == {"S": "launching-owner"}


def test_concurrent_lease_change_cannot_be_overwritten() -> None:
    fake = FakeAws(lease_item("orphan-owner", expires_at=2_000, created_at=100))
    fake.concurrent_item = lease_item(
        "concurrent-owner", expires_at=3_000, created_at=1_000, lease_id="lease-concurrent"
    )

    with pytest.raises(LeaseError, match="concurrent-owner still has active EC2"):
        manager(fake).acquire("locks", "new-owner", "local", 2_000)
    assert fake.item["owner"] == {"S": "concurrent-owner"}


def test_forced_release_refuses_active_owner() -> None:
    fake = FakeAws(lease_item("active-owner", expires_at=900, created_at=100), fleet_state="active")

    with pytest.raises(LeaseError, match="refusing forced release of active lease"):
        manager(fake).force_release("locks")
    assert fake.item is not None
    assert not any(call[:2] == ("dynamodb", "delete-item") for call in fake.calls)


def test_forced_release_of_expired_owner_uses_snapshot_condition() -> None:
    fake = FakeAws(lease_item("expired-owner", expires_at=900, created_at=100, heartbeat_at=200))

    previous = manager(fake).force_release("locks")

    assert previous.state == "expired"
    assert fake.item is None
    delete = next(call for call in fake.calls if call[:2] == ("dynamodb", "delete-item"))
    condition = delete[delete.index("--condition-expression") + 1]
    assert condition == (
        "#owner = :owner AND expires_at = :expires_at AND created_at = :created_at "
        "AND lease_id = :lease_id AND heartbeat_at = :heartbeat_at"
    )
