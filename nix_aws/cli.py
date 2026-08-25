from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.parse
import uuid
from collections.abc import Callable, Iterable, Sequence
from dataclasses import asdict, dataclass
from typing import Any

from .lease import LeaseError, LeaseManager, LeaseRecord

DEFAULT_REGION = "eu-central-1"
DEFAULT_PROJECT = "nix-aws-build-infra"
DEFAULT_PROFILE = "nix-aws-build"
DEFAULT_BUDGET = 25.0
ROLE_RE = re.compile(r":assumed-role/AWSReservedSSO_NixAwsBuildOperator_[^/]+/")
BUILD_ACTIVITY_TYPE = 105


@dataclass(frozen=True)
class BuildProfile:
    name: str
    vcpus: int
    memory_gib: int
    volume_gb: int
    iops: int
    throughput: int
    ttl_hours: int
    instance_types: tuple[str, ...]


PROFILES: dict[tuple[str, str], BuildProfile] = {
    ("x86_64-linux", "standard"): BuildProfile(
        "standard",
        16,
        32,
        150,
        3000,
        125,
        4,
        ("c7i.4xlarge", "m7i.4xlarge", "c6i.4xlarge", "m6i.4xlarge"),
    ),
    ("x86_64-linux", "large"): BuildProfile(
        "large",
        32,
        64,
        350,
        6000,
        250,
        10,
        ("c7i.8xlarge", "m7i.8xlarge", "c6i.8xlarge", "m6i.8xlarge"),
    ),
    ("aarch64-linux", "standard"): BuildProfile(
        "standard",
        16,
        32,
        150,
        3000,
        125,
        4,
        ("c7g.4xlarge", "m7g.4xlarge", "c6g.4xlarge", "m6g.4xlarge"),
    ),
    ("aarch64-linux", "large"): BuildProfile(
        "large",
        32,
        64,
        350,
        6000,
        250,
        10,
        ("c7g.8xlarge", "m7g.8xlarge", "c6g.8xlarge", "m6g.8xlarge"),
    ),
}


@dataclass
class SessionState:
    session_id: str
    system: str
    profile: str
    started_at: str
    expires_at: int
    instance_id: str
    fleet_id: str
    launch_template_id: str
    parameter_name: str
    ready_parameter_name: str
    tunnel_pid: int
    local_port: int
    ssh_key: str
    host_key: str
    lock_table: str
    estimated_hourly_cost: float
    lease_id: str = ""


class NixAwsError(RuntimeError):
    pass


class SignalExit(BaseException):
    def __init__(self, signum: int):
        self.signum = signum
        super().__init__(signal.Signals(signum).name)


@contextlib.contextmanager
def ignore_termination_signals() -> Iterable[None]:
    previous = {
        signum: signal.signal(signum, signal.SIG_IGN)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


class App:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.region = os.environ.get("NIX_AWS_REGION", DEFAULT_REGION)
        self.project = os.environ.get("NIX_AWS_PROJECT", DEFAULT_PROJECT)
        self.aws_profile = os.environ.get("NIX_AWS_PROFILE", DEFAULT_PROFILE)
        runtime_base = pathlib.Path(
            os.environ.get("XDG_RUNTIME_DIR", f"/tmp/nix-aws-{os.getuid()}")
        )
        state_base = pathlib.Path(
            os.environ.get("XDG_STATE_HOME", pathlib.Path.home() / ".local/state")
        )
        self.runtime_dir = runtime_base / "nix-aws"
        self.state_dir = state_base / "nix-aws"
        self.logs_dir = self.state_dir / "logs"
        for directory, mode in (
            (self.runtime_dir, 0o700),
            (self.state_dir, 0o700),
            (self.logs_dir, 0o700),
        ):
            directory.mkdir(parents=True, exist_ok=True, mode=mode)
            directory.chmod(mode)
        self.state_file = self.runtime_dir / "session.json"
        self.last_build_log: pathlib.Path | None = None

    def lease_manager(self) -> LeaseManager:
        return LeaseManager(self.aws, self.project)

    def aws(
        self,
        *arguments: str,
        capture: bool = True,
        check: bool = True,
        stdout: Any | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            "aws",
            "--profile",
            self.aws_profile,
            *arguments,
            "--region",
            self.region,
        ]
        kwargs: dict[str, Any] = {"check": check, "text": True}
        if stdout is not None:
            kwargs["stdout"] = stdout
        elif capture:
            kwargs["capture_output"] = True
        return subprocess.run(command, **kwargs)  # noqa: PLW1510 -- check is supplied in kwargs

    def aws_json(self, *arguments: str) -> Any:
        result = self.aws(*arguments, "--output", "json")
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise NixAwsError(f"AWS returned invalid JSON for {arguments[0]}") from exc

    def require_operator_identity(self) -> dict[str, Any]:
        try:
            identity = self.aws_json("sts", "get-caller-identity")
        except subprocess.CalledProcessError as exc:
            raise NixAwsError(
                f"AWS SSO profile '{self.aws_profile}' is unavailable; run "
                f"'aws sso login --profile {self.aws_profile}'"
            ) from exc
        arn = str(identity.get("Arn", ""))
        override = os.environ.get("NIX_AWS_OPERATOR_ROLE_PATTERN")
        role_re = re.compile(override) if override else ROLE_RE
        if not role_re.search(arn):
            raise NixAwsError(
                f"Refusing AWS mutation through {arn!r}; use the {DEFAULT_PROFILE!r} "
                "Identity Center profile assigned to NixAwsBuildOperator"
            )
        return identity

    def ssm_value(self, name: str, *, decrypt: bool = False) -> str:
        args = ["ssm", "get-parameter", "--name", name]
        if decrypt:
            args.append("--with-decryption")
        args.extend(["--query", "Parameter.Value", "--output", "text"])
        return self.aws(*args).stdout.strip()

    def provisioner_config(self) -> dict[str, Any]:
        value = self.ssm_value(f"/{self.project}/config/provisioner")
        return json.loads(value)

    def new_log(self, label: str, suffix: str = "log") -> pathlib.Path:
        stamp = dt.datetime.now(dt.UTC).strftime("%Y%m%dT%H%M%SZ")
        safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label).strip("-")
        self.prune_logs()
        path = self.logs_dir / f"{stamp}-{safe_label}.{suffix}"
        path.touch(mode=0o600, exist_ok=True)
        path.chmod(0o600)
        return path

    def prune_logs(self, days: int = 30) -> None:
        cutoff = time.time() - days * 86400
        for path in self.logs_dir.iterdir():
            if path.is_file() and path.stat().st_mtime < cutoff:
                path.unlink()

    def run_logged(
        self, command: Sequence[str], label: str, env: dict[str, str] | None = None
    ) -> int:
        log_path = self.new_log(label)
        print(f"[nix-aws] log: {log_path}", file=sys.stderr)
        with log_path.open("w", encoding="utf-8") as log:
            log.write(f"$ {shlex.join(command)}\n")
            log.flush()
            process = subprocess.Popen(
                list(command),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
            )
            assert process.stdout is not None
            for line in process.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
                log.write(line)
                log.flush()
            return process.wait()

    def run_monitored_build(
        self,
        installable: str,
        extra_args: Sequence[str],
        env: dict[str, str] | None = None,
    ) -> int:
        raw_path = self.new_log("build", "jsonl")
        self.last_build_log = raw_path
        print(f"[nix-aws] raw Nix log: {raw_path}", file=sys.stderr)
        nix_command = [
            "nix",
            "build",
            "--log-format",
            "internal-json",
            "-v",
            "--out-link",
            "result",
            installable,
            *extra_args,
        ]
        nix_process = subprocess.Popen(
            nix_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
        )
        nom_process = subprocess.Popen(["nom", "--json"], stdin=subprocess.PIPE, env=env)
        assert nix_process.stdout is not None
        assert nom_process.stdin is not None
        with raw_path.open("wb") as raw:
            while chunk := nix_process.stdout.read(65536):
                raw.write(chunk)
                raw.flush()
                try:
                    nom_process.stdin.write(chunk)
                    nom_process.stdin.flush()
                except BrokenPipeError:
                    pass
        with contextlib.suppress(BrokenPipeError):
            nom_process.stdin.close()
        nix_status = nix_process.wait()
        nom_status = nom_process.wait()
        return nix_status if nix_status != 0 else nom_status

    @staticmethod
    def built_derivations_from_log(raw_path: pathlib.Path) -> list[str]:
        derivations: set[str] = set()
        for line in raw_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not line.startswith("@nix "):
                continue
            try:
                event = json.loads(line.removeprefix("@nix "))
            except json.JSONDecodeError:
                continue
            fields = event.get("fields", [])
            if (
                event.get("action") == "start"
                and event.get("type") == BUILD_ACTIVITY_TYPE
                and fields
                and isinstance(fields[0], str)
                and fields[0].startswith("/nix/store/")
                and fields[0].endswith(".drv")
            ):
                derivations.add(fields[0])
        return sorted(derivations)

    def locally_built_outputs(self) -> list[str]:
        if self.last_build_log is None:
            raise NixAwsError("the local build log is unavailable")
        derivations = self.built_derivations_from_log(self.last_build_log)
        if not derivations:
            return []
        result = subprocess.run(
            ["nix-store", "--query", "--outputs", *derivations],
            check=True,
            text=True,
            capture_output=True,
        )
        outputs = sorted(
            {
                line
                for line in result.stdout.splitlines()
                if line.startswith("/nix/store/")
            }
        )
        manifest = self.last_build_log.with_suffix(".built-paths")
        manifest.write_text("".join(f"{path}\n" for path in outputs), encoding="utf-8")
        manifest.chmod(0o600)
        print(f"[nix-aws] locally built output manifest: {manifest}", file=sys.stderr)
        return outputs

    def resolve_store_paths(self, targets: Iterable[str]) -> list[str]:
        resolved: list[str] = []
        installables: list[str] = []
        for target in targets:
            candidate = pathlib.Path(target)
            if candidate.exists() or candidate.is_symlink():
                path = str(candidate.resolve(strict=True))
                if not path.startswith("/nix/store/"):
                    raise NixAwsError(f"{target!r} does not resolve into /nix/store")
                resolved.append(path)
            elif target.startswith("/nix/store/"):
                resolved.append(target)
            else:
                installables.append(target)
        if installables:
            command = ["nix", "build", "--no-link", "--print-out-paths", *installables]
            result = subprocess.run(command, check=True, text=True, capture_output=True)
            resolved.extend(
                line for line in result.stdout.splitlines() if line.startswith("/nix/store/")
            )
        if not resolved:
            raise NixAwsError("no Nix store paths were resolved")
        return sorted(set(resolved))

    def cache_push(self, targets: Iterable[str], *, closure: bool = False) -> None:
        self.require_operator_identity()
        config = self.provisioner_config()
        secret_arn = config.get("local_cache_signing_secret_arn")
        if not secret_arn:
            raise NixAwsError("the local cache signing secret has not been deployed")
        paths = self.resolve_store_paths(targets)
        key_path = self.runtime_dir / f"local-signing-key-{uuid.uuid4().hex}"
        key_path.touch(mode=0o600, exist_ok=False)
        key_path.chmod(0o600)
        try:
            with key_path.open("w", encoding="utf-8") as key_file:
                self.aws(
                    "secretsmanager",
                    "get-secret-value",
                    "--secret-id",
                    str(secret_arn),
                    "--query",
                    "SecretString",
                    "--output",
                    "text",
                    capture=False,
                    stdout=key_file,
                )
            bucket = str(config["cache_bucket"])
            cache_url = str(config["cache_url"])
            store_url = (
                f"s3://{bucket}?region={self.region}&compression=zstd"
                f"&parallel-compression=true&write-nar-listing=true"
                f"&secret-key={urllib.parse.quote(str(key_path), safe='/')}"
            )
            command = ["nix", "copy", "-L"]
            if not closure:
                command.append("--no-recursive")
            command.extend(["--to", store_url, *paths])
            status = self.run_logged(command, "cache-push")
            if status:
                raise NixAwsError(f"nix copy failed with status {status}")
            for path in paths:
                for attempt in range(6):
                    result = subprocess.run(
                        ["nix", "path-info", "--store", cache_url, path],
                        check=False,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    if result.returncode == 0:
                        break
                    if attempt == 5:
                        raise NixAwsError(f"CloudFront did not expose the signed path: {path}")
                    time.sleep(2)
            print(f"[nix-aws] published and verified {len(paths)} store path(s)")
        finally:
            with contextlib.suppress(FileNotFoundError):
                key_path.unlink()

    def state_save(self, state: SessionState) -> None:
        temporary = self.state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(asdict(state), indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        temporary.replace(self.state_file)

    def state_load(self) -> SessionState:
        if not self.state_file.exists():
            raise NixAwsError("no active local nix-aws session")
        return SessionState(**json.loads(self.state_file.read_text(encoding="utf-8")))

    def state_remove(self) -> None:
        with contextlib.suppress(FileNotFoundError):
            self.state_file.unlink()

    def lock_acquire(self, table: str, session_id: str, expires_at: int) -> str:
        try:
            acquired = self.lease_manager().acquire(table, session_id, "local", expires_at)
        except LeaseError as exc:
            raise NixAwsError(str(exc)) from exc
        if acquired.recovered is not None:
            previous = acquired.recovered
            assert previous.lease is not None
            print(
                f"[nix-aws] recovered {previous.state} global lease from "
                f"{previous.lease.owner} after confirming no active EC2 instance or fleet",
                file=sys.stderr,
            )
        return acquired.lease.lease_id

    def lock_release(self, table: str, session_id: str, lease_id: str) -> bool:
        try:
            return self.lease_manager().release_owned(table, session_id, lease_id)
        except LeaseError as exc:
            raise NixAwsError(str(exc)) from exc

    def put_session_history(self, state: SessionState, ended_at: int) -> None:
        duration_hours = max(
            0.0, (ended_at - int(dt.datetime.fromisoformat(state.started_at).timestamp())) / 3600
        )
        estimated = round(duration_hours * state.estimated_hourly_cost, 4)
        item = {
            "pk": {"S": f"SESSION#{state.session_id}"},
            "owner": {"S": state.session_id},
            "created_at": {"N": str(int(dt.datetime.fromisoformat(state.started_at).timestamp()))},
            "expires_at": {"N": str(ended_at + 93 * 86400)},
            "ended_at": {"N": str(ended_at)},
            "estimated_cost": {"N": str(estimated)},
            "system": {"S": state.system},
            "profile": {"S": state.profile},
        }
        self.aws(
            "dynamodb",
            "put-item",
            "--table-name",
            state.lock_table,
            "--item",
            json.dumps(item, separators=(",", ":")),
            check=False,
        )

    def spot_prices(self, profile: BuildProfile) -> list[float]:
        start = dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        data = self.aws_json(
            "ec2",
            "describe-spot-price-history",
            "--instance-types",
            *profile.instance_types,
            "--product-descriptions",
            "Linux/UNIX",
            "--start-time",
            start,
        )
        prices = [float(entry["SpotPrice"]) for entry in data.get("SpotPriceHistory", [])]
        return prices

    def estimate(self, system: str, profile_name: str) -> tuple[float, float]:
        self.require_operator_identity()
        profile = PROFILES[(system, profile_name)]
        prices = self.spot_prices(profile)
        if not prices:
            raise NixAwsError("AWS returned no current Spot prices for the selected profile")
        # Conservative regional gp3/public-IPv4 approximation. The CLI labels
        # this as an estimate and the constants can be overridden without a release.
        ebs_gb_month = float(os.environ.get("NIX_AWS_EBS_GB_MONTH_USD", "0.10"))
        public_ipv4_hour = float(os.environ.get("NIX_AWS_PUBLIC_IPV4_HOUR_USD", "0.005"))
        ebs_hour = profile.volume_gb * ebs_gb_month / 730
        extra_iops_hour = max(0, profile.iops - 3000) * 0.005 / 730
        extra_throughput_hour = max(0, profile.throughput - 125) * 0.04 / 730
        overhead = ebs_hour + extra_iops_hour + extra_throughput_hour + public_ipv4_hour
        return min(prices) + overhead, max(prices) + overhead

    def monthly_estimate(self, table: str) -> float:
        month_start = int(
            dt.datetime.now(dt.UTC)
            .replace(day=1, hour=0, minute=0, second=0, microsecond=0)
            .timestamp()
        )
        data = self.aws_json(
            "dynamodb",
            "scan",
            "--table-name",
            table,
            "--filter-expression",
            "begins_with(pk, :prefix) AND created_at >= :start",
            "--expression-attribute-values",
            json.dumps({":prefix": {"S": "SESSION#"}, ":start": {"N": str(month_start)}}),
        )
        return sum(
            float(item.get("estimated_cost", {}).get("N", "0")) for item in data.get("Items", [])
        )

    def budget_preflight(
        self,
        table: str,
        system: str,
        profile_name: str,
        allow_override: bool,
    ) -> float:
        low, high = self.estimate(system, profile_name)
        profile = PROFILES[(system, profile_name)]
        projected = high * profile.ttl_hours
        month = self.monthly_estimate(table)
        print(
            f"[nix-aws] estimated hourly cost: ${low:.2f}-${high:.2f}; "
            f"TTL upper estimate: ${projected:.2f}; recorded month: ${month:.2f}"
        )
        budget = float(os.environ.get("NIX_AWS_MONTHLY_BUDGET_USD", str(DEFAULT_BUDGET)))
        if month + projected > budget and not allow_override:
            raise NixAwsError(
                f"projected ${month + projected:.2f} exceeds ${budget:.2f} soft ceiling; "
                "use --allow-budget-override after reviewing the estimate"
            )
        return high

    @staticmethod
    def free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])

    def create_spot_fleet(
        self,
        fleet_config: dict[str, Any],
        *,
        before_attempt: Callable[[], None] | None = None,
    ) -> tuple[str, str]:
        """Launch one instance, excluding capacity-starved pools between attempts.

        An instant EC2 Fleet evaluates every supplied override, but makes only one
        synchronous launch attempt.  A subsequent request is therefore required
        after InsufficientInstanceCapacity.  Keep the recommended allocation
        strategy for every request and remove only the pool AWS just rejected.
        """
        remaining = list(fleet_config["LaunchTemplateConfigs"][0]["Overrides"])
        capacity_failures: list[str] = []
        while remaining:
            if before_attempt is not None:
                before_attempt()
            request = json.loads(json.dumps(fleet_config))
            request["LaunchTemplateConfigs"][0]["Overrides"] = remaining
            fleet = self.aws_json(
                "ec2",
                "create-fleet",
                "--cli-input-json",
                json.dumps(request, separators=(",", ":")),
            )
            fleet_id = str(fleet.get("FleetId", ""))
            instances = [
                instance_id
                for group in fleet.get("Instances", [])
                for instance_id in group.get("InstanceIds", [])
            ]
            if instances:
                return fleet_id, str(instances[0])

            if fleet_id:
                self.aws(
                    "ec2",
                    "delete-fleets",
                    "--fleet-ids",
                    fleet_id,
                    "--terminate-instances",
                    check=False,
                )
            errors = fleet.get("Errors", [])
            if not errors or any(
                error.get("ErrorCode") != "InsufficientInstanceCapacity" for error in errors
            ):
                raise NixAwsError(f"EC2 Fleet failed: {json.dumps(errors)}")

            rejected = {
                (
                    error.get("LaunchTemplateAndOverrides", {})
                    .get("Overrides", {})
                    .get("SubnetId"),
                    error.get("LaunchTemplateAndOverrides", {})
                    .get("Overrides", {})
                    .get("InstanceType"),
                )
                for error in errors
            }
            next_remaining = [
                override
                for override in remaining
                if (override.get("SubnetId"), override.get("InstanceType")) not in rejected
            ]
            if len(next_remaining) == len(remaining):
                raise NixAwsError(f"EC2 Fleet failed: {json.dumps(errors)}")
            capacity_failures.extend(
                f"{instance_type}@{subnet}"
                for subnet, instance_type in rejected
                if subnet and instance_type
            )
            remaining = next_remaining
            print(
                "[nix-aws] Spot capacity unavailable in "
                f"{', '.join(capacity_failures)}; retrying across "
                f"{len(remaining)} remaining pools",
                file=sys.stderr,
            )

        raise NixAwsError("EC2 Fleet exhausted every configured Spot capacity pool")

    def session_start(
        self,
        system: str,
        profile_name: str,
        allow_budget_override: bool,
    ) -> SessionState:
        self.require_operator_identity()
        if self.state_file.exists():
            existing = self.state_load()
            if self.session_alive(existing):
                raise NixAwsError(f"session {existing.session_id} is already active")
            print(
                f"[nix-aws] recovering interrupted local session {existing.session_id}",
                file=sys.stderr,
            )
            self.session_stop(quiet=True)
        config = self.provisioner_config()
        lock_table = str(config["build_lock_table"])
        profile = PROFILES[(system, profile_name)]
        hourly = self.budget_preflight(lock_table, system, profile_name, allow_budget_override)
        session_id = uuid.uuid4().hex
        expires_at = int(time.time()) + profile.ttl_hours * 3600
        lease_id = ""
        state: SessionState | None = None
        tunnel: subprocess.Popen[Any] | None = None
        try:
            lease_id = self.lock_acquire(lock_table, session_id, expires_at + 900)
            key_path = self.runtime_dir / f"id_ed25519-{session_id}"
            parameter_name = f"/{self.project}/sessions/{session_id}/config"
            ready_parameter_name = f"/{self.project}/sessions/{session_id}/ready"
            state = SessionState(
                session_id=session_id,
                system=system,
                profile=profile_name,
                started_at=dt.datetime.now(dt.UTC).isoformat(),
                expires_at=expires_at,
                instance_id="",
                fleet_id="",
                launch_template_id="",
                parameter_name=parameter_name,
                ready_parameter_name=ready_parameter_name,
                tunnel_pid=0,
                local_port=0,
                ssh_key=str(key_path),
                host_key="",
                lock_table=lock_table,
                estimated_hourly_cost=hourly,
                lease_id=lease_id,
            )
            self.state_save(state)
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_path)],
                check=True,
            )
            public_key = key_path.with_suffix(".pub").read_text(encoding="utf-8").strip()
            run_config = {
                "mode": "remote-builder",
                "authorized_key": public_key,
                "session_id": session_id,
                "expires_at": expires_at,
            }
            self.aws(
                "ssm",
                "put-parameter",
                "--name",
                parameter_name,
                "--description",
                f"Ephemeral local Nix builder session {session_id}",
                "--type",
                "SecureString",
                "--key-id",
                str(config["kms_key_id"]),
                "--value",
                json.dumps(run_config, separators=(",", ":")),
            )
            ami_id = self.ssm_value(f"/{self.project}/ami/{system}")
            if not re.fullmatch(r"ami-[0-9a-f]+", ami_id):
                raise NixAwsError(f"AMI for {system} is not ready: {ami_id!r}")
            user_data = "\n".join(
                [
                    "#!/usr/bin/env bash",
                    "set -euo pipefail",
                    f"printf '%s\\n' {shlex.quote(self.region)} > /etc/nix-aws-runner/aws-region",
                    f"printf '%s\\n' {shlex.quote(parameter_name)} > /etc/nix-aws-runner/run-parameter",
                    "systemctl enable --now nix-aws-runner.service",
                ]
            )
            launch_data = {
                "ImageId": ami_id,
                "IamInstanceProfile": {"Name": config["local_instance_profile_name"]},
                "SecurityGroupIds": [config["runner_security_group_id"]],
                "UserData": base64.b64encode(user_data.encode()).decode(),
                "MetadataOptions": {
                    "HttpTokens": "required",
                    "HttpEndpoint": "enabled",
                    "HttpPutResponseHopLimit": 1,
                },
                "InstanceInitiatedShutdownBehavior": "terminate",
                "BlockDeviceMappings": [
                    {
                        "DeviceName": "/dev/sda1",
                        "Ebs": {
                            "DeleteOnTermination": True,
                            "Encrypted": True,
                            "VolumeType": "gp3",
                            "VolumeSize": profile.volume_gb,
                            "Iops": profile.iops,
                            "Throughput": profile.throughput,
                        },
                    }
                ],
                "TagSpecifications": [
                    {
                        "ResourceType": resource_type,
                        "Tags": [
                            {"Key": "Name", "Value": f"nix-aws-local-{session_id[:12]}"},
                            {"Key": "ManagedBy", "Value": self.project},
                            {"Key": "Project", "Value": self.project},
                            {"Key": "SessionId", "Value": session_id},
                            {"Key": "ExpiresAt", "Value": str(expires_at)},
                        ],
                    }
                    for resource_type in ("instance", "volume")
                ],
            }
            template = self.aws_json(
                "ec2",
                "create-launch-template",
                "--launch-template-name",
                f"{self.project}-local-{session_id}",
                "--tag-specifications",
                f"ResourceType=launch-template,Tags=[{{Key=ManagedBy,Value={self.project}}},"
                f"{{Key=Project,Value={self.project}}},{{Key=SessionId,Value={session_id}}}]",
                "--launch-template-data",
                json.dumps(launch_data, separators=(",", ":")),
            )
            state.launch_template_id = template["LaunchTemplate"]["LaunchTemplateId"]
            self.state_save(state)
            overrides = [
                {"SubnetId": subnet, "InstanceType": instance_type}
                for subnet in config["runner_subnet_ids"]
                for instance_type in profile.instance_types
            ]
            fleet_config = {
                "Type": "instant",
                "SpotOptions": {
                    "AllocationStrategy": "price-capacity-optimized",
                    "InstanceInterruptionBehavior": "terminate",
                },
                "TargetCapacitySpecification": {
                    "TotalTargetCapacity": 1,
                    "DefaultTargetCapacityType": "spot",
                },
                "LaunchTemplateConfigs": [
                    {
                        "LaunchTemplateSpecification": {
                            "LaunchTemplateId": state.launch_template_id,
                            "Version": "$Latest",
                        },
                        "Overrides": overrides,
                    }
                ],
                "TagSpecifications": [
                    {
                        "ResourceType": "fleet",
                        "Tags": [
                            {"Key": "ManagedBy", "Value": self.project},
                            {"Key": "Project", "Value": self.project},
                            {"Key": "SessionId", "Value": session_id},
                        ],
                    }
                ],
            }
            state.fleet_id, state.instance_id = self.create_spot_fleet(
                fleet_config,
                before_attempt=lambda: self.lease_manager().touch(
                    lock_table, session_id, lease_id, "launching"
                ),
            )
            self.state_save(state)
            self.lease_manager().touch(
                lock_table,
                session_id,
                lease_id,
                "active",
                instance_id=state.instance_id,
                fleet_id=state.fleet_id,
            )
            self.aws("ec2", "wait", "instance-running", "--instance-ids", state.instance_id)
            deadline = time.monotonic() + 900
            ready: dict[str, Any] | None = None
            while time.monotonic() < deadline:
                response = self.aws(
                    "ssm",
                    "get-parameter",
                    "--name",
                    ready_parameter_name,
                    "--query",
                    "Parameter.Value",
                    "--output",
                    "text",
                    check=False,
                )
                if response.returncode == 0:
                    ready = json.loads(response.stdout)
                    break
                time.sleep(10)
            if ready is None:
                raise NixAwsError("remote builder did not become ready within 15 minutes")
            expected_machine = {"x86_64-linux": "x86_64", "aarch64-linux": "aarch64"}[system]
            if ready.get("machine") != expected_machine:
                raise NixAwsError(
                    f"AMI architecture mismatch: expected {expected_machine}, "
                    f"got {ready.get('machine')!r}"
                )
            local_port = self.free_port()
            tunnel_log = self.new_log(f"ssm-{session_id[:8]}")
            tunnel_handle = tunnel_log.open("w", encoding="utf-8")
            tunnel = subprocess.Popen(
                [
                    "aws",
                    "--profile",
                    self.aws_profile,
                    "ssm",
                    "start-session",
                    "--region",
                    self.region,
                    "--target",
                    state.instance_id,
                    "--document-name",
                    "AWS-StartPortForwardingSession",
                    "--parameters",
                    json.dumps({"portNumber": ["22"], "localPortNumber": [str(local_port)]}),
                ],
                stdout=tunnel_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if tunnel.poll() is not None:
                    raise NixAwsError(f"SSM tunnel exited; inspect {tunnel_log}")
                try:
                    with socket.create_connection(("127.0.0.1", local_port), timeout=1):
                        break
                except OSError:
                    time.sleep(1)
            else:
                raise NixAwsError(f"SSM tunnel did not open; inspect {tunnel_log}")
            state.tunnel_pid = tunnel.pid
            state.local_port = local_port
            state.host_key = str(ready["host_key"])
            self.state_save(state)
            print(
                f"[nix-aws] session {session_id} ready on {state.instance_id}; "
                f"{system}/{profile_name}, expires "
                f"{dt.datetime.fromtimestamp(expires_at, tz=dt.UTC).isoformat()}"
            )
            return state
        except BaseException:
            if tunnel is not None and tunnel.poll() is None:
                tunnel.terminate()
            try:
                if state is not None:
                    self.stop_state(state, quiet=True)
                else:
                    current = self.lease_manager().get(lock_table)
                    if current is not None and current.owner == session_id:
                        self.lock_release(lock_table, session_id, lease_id)
            except (
                LeaseError,
                NixAwsError,
                OSError,
                subprocess.CalledProcessError,
                ValueError,
            ) as cleanup_exc:
                print(
                    f"[nix-aws] interrupted-session cleanup incomplete: {cleanup_exc}; "
                    "the lease was retained if any EC2 resource could still be active",
                    file=sys.stderr,
                )
            raise

    def session_alive(self, state: SessionState) -> bool:
        if state.tunnel_pid <= 0:
            return False
        try:
            os.kill(state.tunnel_pid, 0)
            return state.expires_at > int(time.time())
        except OSError:
            return False

    def builder_nix_config(self, state: SessionState) -> str:
        host_key = urllib.parse.quote(state.host_key, safe="")
        builder_uri = (
            f"ssh-ng://nixremote@127.0.0.1:{state.local_port}?base64-ssh-public-host-key={host_key}"
        )
        jobs = PROFILES[(state.system, state.profile)].vcpus
        return "\n".join(
            [
                f"builders = {builder_uri} {state.system} {state.ssh_key} {jobs} 1 big-parallel,kvm,nixos-test -",
                "builders-use-substitutes = true",
                "max-jobs = 0",
                "narinfo-cache-negative-ttl = 0",
            ]
        )

    def session_exec(
        self,
        command: Sequence[str] = (),
        *,
        monitored_build: str | None = None,
        extra_args: Sequence[str] = (),
    ) -> int:
        state = self.state_load()
        if not self.session_alive(state):
            raise NixAwsError("the local SSM tunnel is not running; stop and recreate the session")
        env = os.environ.copy()
        existing = env.get("NIX_CONFIG", "").strip()
        env["NIX_CONFIG"] = "\n".join(filter(None, (existing, self.builder_nix_config(state))))
        if monitored_build is not None:
            return self.run_monitored_build(monitored_build, extra_args, env)
        return self.run_logged(command, f"session-{state.session_id[:8]}", env)

    def cleanup_aws_resources(
        self,
        *,
        fleet_id: str,
        instance_id: str,
        launch_template_id: str,
        parameters: Iterable[str],
    ) -> None:
        if fleet_id:
            self.aws(
                "ec2",
                "delete-fleets",
                "--fleet-ids",
                fleet_id,
                "--terminate-instances",
                check=False,
            )
        elif instance_id:
            self.aws("ec2", "terminate-instances", "--instance-ids", instance_id, check=False)
        if launch_template_id:
            self.aws(
                "ec2",
                "delete-launch-template",
                "--launch-template-id",
                launch_template_id,
                check=False,
            )
        for parameter in parameters:
            if parameter:
                self.aws("ssm", "delete-parameter", "--name", parameter, check=False)

    def wait_for_lease_resources_inactive(
        self,
        state: SessionState,
        *,
        timeout_seconds: int = 300,
    ) -> None:
        if state.instance_id:
            self.aws(
                "ec2",
                "wait",
                "instance-terminated",
                "--instance-ids",
                state.instance_id,
                check=False,
            )
        deadline = time.monotonic() + timeout_seconds
        owner = LeaseRecord(
            owner=state.session_id,
            owner_kind="local",
            expires_at=state.expires_at,
            created_at=0,
        )
        while True:
            try:
                resources = self.lease_manager().resources(owner)
            except (LeaseError, subprocess.CalledProcessError) as exc:
                raise NixAwsError(
                    f"could not verify EC2 resources for lease owner {state.session_id}: {exc}"
                ) from exc
            if not resources.active:
                return
            if time.monotonic() >= deadline:
                details = json.dumps(
                    {
                        "instances": list(resources.instances),
                        "fleets": list(resources.fleets),
                    },
                    separators=(",", ":"),
                )
                raise NixAwsError(
                    f"EC2 resources for {state.session_id} remain active after termination: {details}; "
                    "the global lease was retained"
                )
            time.sleep(5)

    def terminate_owner_tagged_resources(self, state: SessionState) -> None:
        try:
            resources = self.lease_manager().resources(
                LeaseRecord(
                    owner=state.session_id,
                    owner_kind="local",
                    expires_at=state.expires_at,
                    created_at=0,
                )
            )
        except (LeaseError, subprocess.CalledProcessError) as exc:
            raise NixAwsError(
                f"could not inspect resources owned by {state.session_id}; retaining the lease"
            ) from exc
        for fleet in resources.fleets:
            self.aws(
                "ec2",
                "delete-fleets",
                "--fleet-ids",
                fleet["fleet_id"],
                "--terminate-instances",
                check=False,
            )
        for instance in resources.instances:
            self.aws(
                "ec2",
                "terminate-instances",
                "--instance-ids",
                instance["instance_id"],
                check=False,
            )

    def stop_state(self, state: SessionState, *, quiet: bool = False) -> None:
        with ignore_termination_signals():
            with contextlib.suppress(ProcessLookupError):
                if state.tunnel_pid > 0:
                    os.killpg(state.tunnel_pid, signal.SIGTERM)
            self.terminate_owner_tagged_resources(state)
            self.cleanup_aws_resources(
                fleet_id=state.fleet_id,
                instance_id=state.instance_id,
                launch_template_id=state.launch_template_id,
                parameters=(state.parameter_name, state.ready_parameter_name),
            )
            self.wait_for_lease_resources_inactive(state)
            if state.launch_template_id:
                self.aws(
                    "ec2",
                    "delete-launch-template",
                    "--launch-template-id",
                    state.launch_template_id,
                    check=False,
                )
            ended_at = int(time.time())
            self.put_session_history(state, ended_at)
            self.lock_release(state.lock_table, state.session_id, state.lease_id)
            for path in (
                pathlib.Path(state.ssh_key),
                pathlib.Path(state.ssh_key).with_suffix(".pub"),
            ):
                with contextlib.suppress(FileNotFoundError):
                    path.unlink()
            self.state_remove()
        if not quiet:
            print(f"[nix-aws] stopped session {state.session_id}")

    def session_stop(self, *, quiet: bool = False) -> None:
        self.require_operator_identity()
        state = self.state_load()
        self.stop_state(state, quiet=quiet)


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="nix-aws")
    commands = root.add_subparsers(dest="command", required=True)

    build = commands.add_parser("build", help="build locally or on an ephemeral AWS builder")
    build.add_argument("installable")
    build.add_argument("nix_args", nargs=argparse.REMAINDER)
    build.add_argument("--remote", action="store_true")
    build.add_argument("--push", action="store_true")
    build.add_argument(
        "--system", choices=("x86_64-linux", "aarch64-linux"), default="x86_64-linux"
    )
    build.add_argument("--profile", choices=("standard", "large"), default="standard")
    build.add_argument("--allow-budget-override", action="store_true")

    session = commands.add_parser("session", help="manage a reusable AWS builder")
    session_commands = session.add_subparsers(dest="session_command", required=True)
    start = session_commands.add_parser("start")
    start.add_argument(
        "--system", choices=("x86_64-linux", "aarch64-linux"), default="x86_64-linux"
    )
    start.add_argument("--profile", choices=("standard", "large"), default="standard")
    start.add_argument("--allow-budget-override", action="store_true")
    session_commands.add_parser("status")
    session_commands.add_parser("stop")
    execute = session_commands.add_parser("exec")
    execute.add_argument("exec_command", nargs=argparse.REMAINDER)

    cache = commands.add_parser("cache")
    cache_commands = cache.add_subparsers(dest="cache_command", required=True)
    push = cache_commands.add_parser("push")
    push.add_argument(
        "--closure",
        action="store_true",
        help="publish each target and its full dependency closure",
    )
    push.add_argument("targets", nargs="+")

    logs = commands.add_parser("logs")
    log_commands = logs.add_subparsers(dest="logs_command", required=True)
    log_commands.add_parser("list")
    tail = log_commands.add_parser("tail")
    tail.add_argument("path", nargs="?")
    show = log_commands.add_parser("show")
    show.add_argument("path", nargs="?")

    cost = commands.add_parser("cost")
    cost_commands = cost.add_subparsers(dest="cost_command", required=True)
    estimate = cost_commands.add_parser("estimate")
    estimate.add_argument(
        "--system", choices=("x86_64-linux", "aarch64-linux"), default="x86_64-linux"
    )
    estimate.add_argument("--profile", choices=("standard", "large"), default="standard")
    cost_commands.add_parser("status")

    lease = commands.add_parser("lease", help="inspect or safely recover the global build lease")
    lease_commands = lease.add_subparsers(dest="lease_command", required=True)
    lease_commands.add_parser("status")
    release = lease_commands.add_parser("release")
    release.add_argument(
        "--force",
        action="store_true",
        help="release only after DynamoDB and EC2 prove the lease is recoverable",
    )
    return root


def latest_log(app: App) -> pathlib.Path:
    logs = sorted(
        (path for path in app.logs_dir.iterdir() if path.is_file()),
        key=lambda path: path.stat().st_mtime,
    )
    if not logs:
        raise NixAwsError("no nix-aws logs exist")
    return logs[-1]


def run(args: argparse.Namespace) -> int:
    app = App(args)
    if args.command == "build":
        if args.remote and args.push:
            raise NixAwsError(
                "remote builders publish automatically; --push is only for local builds"
            )
        if args.remote:
            app.session_start(args.system, args.profile, args.allow_budget_override)
            try:
                status = app.session_exec(
                    monitored_build=args.installable, extra_args=args.nix_args
                )
            finally:
                app.session_stop(quiet=True)
            return status
        status = app.run_monitored_build(args.installable, args.nix_args)
        if status == 0 and args.push:
            outputs = app.locally_built_outputs()
            if outputs:
                app.cache_push(outputs)
            else:
                print("[nix-aws] no local build outputs; nothing to publish")
        return status
    if args.command == "session":
        if args.session_command == "start":
            app.session_start(args.system, args.profile, args.allow_budget_override)
            return 0
        if args.session_command == "stop":
            app.session_stop()
            return 0
        if args.session_command == "status":
            state = app.state_load()
            payload = asdict(state) | {"alive": app.session_alive(state)}
            print(json.dumps(payload, indent=2))
            return 0
        command = args.exec_command
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            raise NixAwsError("session exec requires a command after --")
        return app.session_exec(command)
    if args.command == "cache":
        app.cache_push(args.targets, closure=args.closure)
        return 0
    if args.command == "logs":
        if args.logs_command == "list":
            for path in sorted(app.logs_dir.iterdir()):
                if path.is_file():
                    print(path)
            return 0
        path = pathlib.Path(args.path) if args.path else latest_log(app)
        if args.logs_command == "show":
            return subprocess.run(["less", "+G", str(path)], check=False).returncode
        return subprocess.run(["tail", "-F", str(path)], check=False).returncode
    if args.command == "cost":
        app.require_operator_identity()
        config = app.provisioner_config()
        if args.cost_command == "estimate":
            low, high = app.estimate(args.system, args.profile)
            profile = PROFILES[(args.system, args.profile)]
            print(
                json.dumps(
                    {
                        "system": args.system,
                        "profile": args.profile,
                        "hourly_usd": {"low": round(low, 4), "high": round(high, 4)},
                        "ttl_hours": profile.ttl_hours,
                        "ttl_upper_usd": round(high * profile.ttl_hours, 2),
                    },
                    indent=2,
                )
            )
            return 0
        table = str(config["build_lock_table"])
        print(
            json.dumps(
                {
                    "recorded_month_usd": round(app.monthly_estimate(table), 2),
                    "soft_ceiling_usd": float(
                        os.environ.get("NIX_AWS_MONTHLY_BUDGET_USD", str(DEFAULT_BUDGET))
                    ),
                },
                indent=2,
            )
        )
        return 0
    if args.command == "lease":
        app.require_operator_identity()
        table = str(app.provisioner_config()["build_lock_table"])
        manager = app.lease_manager()
        if args.lease_command == "status":
            print(json.dumps(manager.inspect(table).as_dict(), indent=2))
            return 0
        if not args.force:
            raise NixAwsError(
                "lease release requires --force; it still refuses active or recently provisioning owners"
            )
        try:
            previous = manager.force_release(table)
        except LeaseError as exc:
            raise NixAwsError(str(exc)) from exc
        if previous.lease is None:
            print("[nix-aws] global lease is already free")
        else:
            print(
                f"[nix-aws] released {previous.state} lease owned by "
                f"{previous.lease.owner} after confirming no active EC2 instance or fleet"
            )
        return 0
    raise NixAwsError("unknown command")


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    for required in ("nix", "nom"):
        if args.command == "build" and shutil.which(required) is None:
            print(f"nix-aws: required executable not found: {required}", file=sys.stderr)
            return 127
    previous_handlers = {
        signum: signal.getsignal(signum) for signum in (signal.SIGINT, signal.SIGTERM)
    }

    def terminate(signum: int, _frame: Any) -> None:
        raise SignalExit(signum)

    for signum in previous_handlers:
        signal.signal(signum, terminate)
    try:
        return run(args)
    except SignalExit as exc:
        print(
            f"nix-aws: received {signal.Signals(exc.signum).name}; cleanup completed or the "
            "lease was retained for safety",
            file=sys.stderr,
        )
        return 128 + exc.signum
    except (LeaseError, NixAwsError, subprocess.CalledProcessError, KeyError, ValueError) as exc:
        print(f"nix-aws: {exc}", file=sys.stderr)
        return 1
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
