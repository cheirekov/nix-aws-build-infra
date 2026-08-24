from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess

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


def test_log_files_are_private(tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())

    previous_umask = os.umask(0o002)
    try:
        log_path = app.new_log("fixture")
    finally:
        os.umask(previous_umask)

    assert log_path.stat().st_mode & 0o777 == 0o600


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


def test_spot_fleet_retries_without_rejected_capacity_pool(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    requests: list[dict[str, object]] = []
    responses = iter(
        [
            {
                "FleetId": "fleet-failed",
                "Errors": [
                    {
                        "ErrorCode": "InsufficientInstanceCapacity",
                        "LaunchTemplateAndOverrides": {
                            "Overrides": {
                                "SubnetId": "subnet-a",
                                "InstanceType": "c7i.4xlarge",
                            }
                        },
                    }
                ],
                "Instances": [],
            },
            {
                "FleetId": "fleet-ready",
                "Errors": [],
                "Instances": [{"InstanceIds": ["i-ready"]}],
            },
        ]
    )

    def fake_aws_json(*arguments: str) -> dict[str, object]:
        requests.append(json.loads(arguments[-1]))
        return next(responses)

    cleanup_calls: list[tuple[str, ...]] = []
    monkeypatch.setattr(app, "aws_json", fake_aws_json)
    monkeypatch.setattr(
        app,
        "aws",
        lambda *arguments, **_kwargs: cleanup_calls.append(arguments),
    )
    config = {
        "LaunchTemplateConfigs": [
            {
                "Overrides": [
                    {"SubnetId": "subnet-a", "InstanceType": "c7i.4xlarge"},
                    {"SubnetId": "subnet-b", "InstanceType": "m7i.4xlarge"},
                ]
            }
        ]
    }

    assert app.create_spot_fleet(config) == ("fleet-ready", "i-ready")
    assert requests[1]["LaunchTemplateConfigs"][0]["Overrides"] == [
        {"SubnetId": "subnet-b", "InstanceType": "m7i.4xlarge"}
    ]
    assert cleanup_calls == [
        (
            "ec2",
            "delete-fleets",
            "--fleet-ids",
            "fleet-failed",
            "--terminate-instances",
        )
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


def test_local_build_pushes_only_outputs_recorded_in_its_build_log(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr(App, "run_monitored_build", lambda *_args, **_kwargs: 0)
    monkeypatch.setattr(
        App,
        "locally_built_outputs",
        lambda _self: ["/nix/store/aaa-local-output", "/nix/store/bbb-local-output"],
    )
    calls: list[tuple[object, ...]] = []
    monkeypatch.setattr(
        App,
        "cache_push",
        lambda _self, targets, *, closure=False: calls.append((list(targets), closure)),
    )

    assert run(parser().parse_args(["build", "--push", ".#fixture"])) == 0
    assert calls == [
        (["/nix/store/aaa-local-output", "/nix/store/bbb-local-output"], False)
    ]


def test_local_build_push_skips_a_fully_substituted_build(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    monkeypatch.setattr(App, "run_monitored_build", lambda *_args, **_kwargs: 0)
    monkeypatch.setattr(App, "locally_built_outputs", lambda _self: [])

    def unexpected_push(*_args: object, **_kwargs: object) -> None:
        pytest.fail("cache_push must not run when every path was substituted")

    monkeypatch.setattr(App, "cache_push", unexpected_push)
    assert run(parser().parse_args(["build", "--push", ".#fixture"])) == 0
    assert "no local build outputs" in capsys.readouterr().out


def test_locally_built_outputs_uses_only_build_activities(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    raw_log = app.new_log("build", "jsonl")
    raw_log.write_text(
        """@nix {"action":"start","type":105,"fields":["/nix/store/bbb.drv"]}
@nix {"action":"start","type":105,"fields":["/nix/store/aaa.drv"]}
@nix {"action":"start","type":104,"fields":["/nix/store/substitute.drv"]}
@nix {"action":"msg","type":105,"fields":["/nix/store/not-a-build.drv"]}
not-json
""",
        encoding="utf-8",
    )
    app.last_build_log = raw_log
    commands: list[list[str]] = []

    def fake_run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        commands.append(command)
        return subprocess.CompletedProcess(
            command,
            0,
            stdout="/nix/store/zzz-output\n/nix/store/aaa-output\n/nothing\n",
        )

    monkeypatch.setattr("nix_aws.cli.subprocess.run", fake_run)
    assert app.locally_built_outputs() == ["/nix/store/aaa-output", "/nix/store/zzz-output"]
    assert commands == [["nix-store", "--query", "--outputs", "/nix/store/aaa.drv", "/nix/store/bbb.drv"]]
    assert raw_log.with_suffix(".built-paths").read_text() == (
        "/nix/store/aaa-output\n/nix/store/zzz-output\n"
    )


def test_cache_push_defaults_to_exact_paths_and_accepts_closure_mode() -> None:
    exact = parser().parse_args(["cache", "push", "./result"])
    closure = parser().parse_args(["cache", "push", "--closure", "./result"])
    assert exact.closure is False
    assert closure.closure is True


def test_cache_push_uses_no_recursive_unless_closure_is_requested(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    app = App(argparse.Namespace())
    monkeypatch.setattr(app, "require_operator_identity", dict)
    monkeypatch.setattr(
        app,
        "provisioner_config",
        lambda: {
            "local_cache_signing_secret_arn": "arn:secret",
            "cache_bucket": "cache-bucket",
            "cache_url": "https://cache.example.test",
        },
    )
    monkeypatch.setattr(app, "resolve_store_paths", lambda _targets: ["/nix/store/local-output"])

    def fake_aws(*_args: str, **kwargs: object) -> None:
        output = kwargs.get("stdout")
        assert output is not None
        output.write("secret-key")  # type: ignore[union-attr]

    commands: list[list[str]] = []
    monkeypatch.setattr(app, "aws", fake_aws)
    monkeypatch.setattr(
        app,
        "run_logged",
        lambda command, _label: commands.append(list(command)) or 0,
    )
    monkeypatch.setattr(
        "nix_aws.cli.subprocess.run",
        lambda *args, **_kwargs: subprocess.CompletedProcess(args[0], 0),
    )

    app.cache_push(["./result"])
    app.cache_push(["./result"], closure=True)

    assert "--no-recursive" in commands[0]
    assert "--no-recursive" not in commands[1]


def test_remote_and_push_are_mutually_exclusive(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    args = parser().parse_args(["build", "--remote", "--push", ".#fixture"])

    with pytest.raises(NixAwsError, match="remote builders publish automatically"):
        run(args)


def test_remote_build_uses_one_shot_session_and_always_stops(
    tmp_path: pathlib.Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(tmp_path / "run"))
    monkeypatch.setenv("XDG_STATE_HOME", str(tmp_path / "state"))
    calls: list[tuple[object, ...]] = []

    monkeypatch.setattr(
        App,
        "session_start",
        lambda _self, system, profile, override: calls.append(("start", system, profile, override)),
    )

    def fake_exec(
        _self: App,
        command: tuple[str, ...] = (),
        *,
        monitored_build: str | None = None,
        extra_args: tuple[str, ...] = (),
    ) -> int:
        calls.append(("exec", command, monitored_build, extra_args))
        return 0

    monkeypatch.setattr(App, "session_exec", fake_exec)
    monkeypatch.setattr(
        App,
        "session_stop",
        lambda _self, *, quiet=False: calls.append(("stop", quiet)),
    )
    args = parser().parse_args(
        ["build", "--remote", "--system", "x86_64-linux", "--profile", "standard", ".#fixture"]
    )

    assert run(args) == 0
    assert calls == [
        ("start", "x86_64-linux", "standard", False),
        ("exec", (), ".#fixture", []),
        ("stop", True),
    ]
