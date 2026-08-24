from __future__ import annotations

import argparse
import json
import os
import pathlib

import pytest

from nix_aws.cli import PROFILES, App, NixAwsError, SessionState, parser, run


def test_all_profiles_have_twelve_capacity_pools() -> None:
    for profile in PROFILES.values():
        assert len(profile.instance_types) == 4
        assert profile.ttl_hours <= 10
        assert profile.iops >= 3000


def test_build_defaults_to_local_standard_x86() -> None:
    args = parser().parse_args(["build", ".#fixture"])
    assert args.remote is False
    assert args.push is False
    assert args.system == "x86_64-linux"
    assert args.profile == "standard"


def test_remote_arm_arguments() -> None:
    args = parser().parse_args(
        ["build", "--remote", "--system", "aarch64-linux", "--profile", "large", ".#x"]
    )
    assert args.remote is True
    assert args.system == "aarch64-linux"
    assert args.profile == "large"


def test_state_round_trip(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    state = SessionState(
        session_id="abc",
        system="x86_64-linux",
        profile="standard",
        started_at="2026-08-24T00:00:00+00:00",
        expires_at=2_000_000_000,
        instance_id="i-abc",
        fleet_id="fleet-abc",
        launch_template_id="lt-abc",
        parameter_name="/config",
        ready_parameter_name="/ready",
        tunnel_pid=os.getpid(),
        local_port=12345,
        ssh_key="/tmp/key",
        host_key="AAAA",
        lock_table="locks",
        estimated_hourly_cost=0.5,
    )
    app.state_save(state)
    assert app.state_load() == state
    assert json.loads(app.state_file.read_text())["session_id"] == "abc"


def test_resolve_store_path_rejects_non_store_path(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    ordinary = tmp_path / "ordinary"
    ordinary.write_text("x")
    with pytest.raises(NixAwsError, match="does not resolve"):
        app.resolve_store_paths([str(ordinary)])


def test_operator_identity_rejects_long_lived_admin(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    monkeypatch.setattr(
        app,
        "aws_json",
        lambda *_args: {
            "Account": "123456789012",
            "Arn": "arn:aws:iam::123456789012:user/administrator",
        },
    )

    with pytest.raises(NixAwsError, match="Refusing AWS mutation"):
        app.require_operator_identity()


def test_cleanup_targets_only_session_resources(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    calls: list[tuple[str, ...]] = []

    def record(*arguments: str, **_kwargs: object) -> None:
        calls.append(arguments)

    monkeypatch.setattr(app, "aws", record)
    app.cleanup_aws_resources(
        fleet_id="fleet-session",
        instance_id="i-session",
        launch_template_id="lt-session",
        parameters=("/project/sessions/id/config", "/project/sessions/id/ready"),
    )

    assert calls == [
        ("ec2", "delete-fleets", "--fleet-ids", "fleet-session", "--terminate-instances"),
        ("ec2", "delete-launch-template", "--launch-template-id", "lt-session"),
        ("ssm", "delete-parameter", "--name", "/project/sessions/id/config"),
        ("ssm", "delete-parameter", "--name", "/project/sessions/id/ready"),
    ]


def test_local_build_without_push_never_publishes(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr(App, "run_monitored_build", lambda *_args, **_kwargs: 0)

    def unexpected_push(*_args: object, **_kwargs: object) -> None:
        pytest.fail("cache_push must not run without --push")

    monkeypatch.setattr(App, "cache_push", unexpected_push)
    assert run(parser().parse_args(["build", ".#fixture"])) == 0


def test_remote_and_push_are_mutually_exclusive(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    args = parser().parse_args(["build", "--remote", "--push", ".#fixture"])

    with pytest.raises(NixAwsError, match="remote builders publish automatically"):
        run(args)
