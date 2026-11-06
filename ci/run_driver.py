"""Run one CI driver job's own steps on the laptop, in a disposable privileged container.

Run it from the repository root as python3 -m ci.run_driver <job>. The steps are read from
.github/workflows/ci.yml, never copied. Each run creates a fresh container booted with
systemd, copies in the working tree, runs every run: step as the user runner from the job's
working directory, and removes the container whatever happens.
"""

import argparse
import io
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

import yaml

from ci.select_jobs import driver_jobs

# Jobs proven to run in a rootless container on 2026-11-05. The other driver jobs mount
# loop devices or set security.* attributes, which need root in the host's own namespace.
LOCAL_JOBS = ("b2-bucket", "openbao")
IMAGE = "localhost/kbi-driver-runner"
BOOT_SECONDS = 60
BOOT_POLL = 1
WORKFLOW = Path(".github") / "workflows" / "ci.yml"

# GitHub's own command for each shell a run: step can name, from its workflow syntax docs.
SHELLS = {
    None: ["bash", "-e"],
    "bash": ["bash", "--noprofile", "--norc", "-eo", "pipefail"],
}

# The settings the runner reproduces or may ignore without changing how a step runs. A job's
# if and needs decide whether CI runs it at all, which is the caller's choice here. Anything
# else is refused, so a new setting fails loudly instead of running differently from CI.
WORKFLOW_KEYS = {"name", "on", "run-name", "permissions", "concurrency", "jobs"}
JOB_KEYS = {
    "name",
    "runs-on",
    "needs",
    "if",
    "permissions",
    "timeout-minutes",
    "defaults",
    "steps",
}
STEP_KEYS = {"name", "id", "run", "shell"}

SIGNALS = (signal.SIGTERM, signal.SIGHUP)


class UnsupportedWorkflow(ValueError):
    """The workflow uses something the local runner can't reproduce exactly."""


@dataclass
class Step:
    name: str
    script: str
    shell: list
    working_directory: str


def job_steps(workflow, job):
    """Return a job's run: steps in order, refusing any shape the runner can't reproduce."""
    data = yaml.load(Path(workflow).read_text(), Loader=yaml.BaseLoader)
    jobs = data["jobs"]
    if job not in jobs:
        raise UnsupportedWorkflow(f"{job} is not a job in {WORKFLOW}")
    _refuse_keys(data, WORKFLOW_KEYS, f"{WORKFLOW} sets ")
    spec = jobs[job]
    _refuse_keys(spec, JOB_KEYS, f"{job} sets ")
    defaults = spec.get("defaults", {})
    _refuse_keys(defaults, {"run"}, f"{job} sets defaults.")
    run_defaults = defaults.get("run", {})
    _refuse_keys(run_defaults, {"working-directory"}, f"{job} sets defaults.run.")
    working_directory = run_defaults.get("working-directory", "")
    steps = []
    for step in spec["steps"]:
        if "run" not in step:
            continue
        name = step.get("name") or step["run"].splitlines()[0]
        problem = _problem(step)
        if problem is not None:
            raise UnsupportedWorkflow(
                f"{job} step {len(steps) + 1} ({name}) {problem}, "
                "which the local runner cannot reproduce"
            )
        steps.append(
            Step(name, step["run"], SHELLS[step.get("shell")], working_directory)
        )
    return steps


def _refuse_keys(mapping, allowed, where):
    for key in mapping:
        if key not in allowed:
            raise UnsupportedWorkflow(
                f"{where}{key}, which the local runner cannot reproduce"
            )


def _problem(step):
    """Why the runner can't reproduce this step exactly, or None when it can."""
    for key in step:
        if key not in STEP_KEYS:
            return f"sets {key}"
    if any("${{" in value for value in step.values()):
        return "uses a GitHub expression"
    if step.get("shell") not in SHELLS:
        return f"uses shell {step['shell']}"
    return None


def podman_command():
    """Podman on the host, or the host's Podman through distrobox inside the dev container."""
    if shutil.which("podman"):
        return ["podman"]
    return ["distrobox-host-exec", "podman"]


def _archive(root, steps):
    """The working tree as git sees it, tracked and untracked but not ignored, plus the steps."""
    listed = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "-z",
            "--cached",
            "--others",
            "--exclude-standard",
        ],
        check=True,
        capture_output=True,
    ).stdout
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        # Names stay bytes until here, so a name that isn't UTF-8 survives the copy.
        for path in sorted({os.fsdecode(raw) for raw in listed.split(b"\0") if raw}):
            full = root / path
            # A symlink is kept as a link; a path git lists but the tree lacks is skipped.
            if full.is_symlink() or full.is_file():
                archive.add(full, arcname=f"src/{path}")
        for number, step in enumerate(steps, 1):
            data = step.script.encode()
            info = tarfile.TarInfo(f"steps/{number:02d}.sh")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def _podman(podman, *args, **kwargs):
    return subprocess.run([*podman, *args], check=False, **kwargs)


def _wait_for_boot(podman, name):
    deadline = time.monotonic() + BOOT_SECONDS
    while True:
        state = _podman(
            podman,
            "exec",
            name,
            "systemctl",
            "is-system-running",
            capture_output=True,
            text=True,
        ).stdout.strip()
        if state in {"running", "degraded"}:
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(BOOT_POLL)


def _exit_on_signal(signum, _frame):
    raise SystemExit(128 + signum)


def run_job(job, root, podman):
    """Run every step of one local job; return its exit status."""
    steps = job_steps(root / WORKFLOW, job)
    built = _podman(podman, "build", "-t", IMAGE, str(root / "ci" / "driver-image"))
    if built.returncode:
        print(f"could not build {IMAGE}", file=sys.stderr)
        return built.returncode
    name = f"kbi-driver-{job}-{os.getpid()}"
    created = _podman(
        podman,
        "create",
        "--name",
        name,
        "--privileged",
        "--systemd=always",
        "--tmpfs",
        "/home:rw,exec,size=6g",
        "--tmpfs",
        "/var/lib/containers:rw,exec,size=3g",
        IMAGE,
        capture_output=True,
        text=True,
    )
    if created.returncode:
        print(f"could not create {name}: {created.stderr.strip()}", file=sys.stderr)
        return created.returncode
    # From here the container exists, so every way out, a terminating signal included,
    # goes through its removal.
    previous = {number: signal.signal(number, _exit_on_signal) for number in SIGNALS}
    try:
        status = _run_in(podman, name, job, root, steps)
    finally:
        for number in SIGNALS:
            signal.signal(number, signal.SIG_IGN)
        removed = _remove(podman, name)
        for number, handler in previous.items():
            signal.signal(number, handler)
    return status if removed else status or 1


def _remove(podman, name):
    """Remove the container, quietly; name it with the command to remove it if that fails."""
    command = [*podman, "rm", "-f", "-t", "10", name]
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode:
        print(
            f"{name} was not removed; remove it with {' '.join(command)}",
            file=sys.stderr,
        )
    return result.returncode == 0


def _run_in(podman, name, job, root, steps):
    started = _podman(podman, "start", name, capture_output=True, text=True)
    if started.returncode:
        print(f"could not start {name}: {started.stderr.strip()}", file=sys.stderr)
        return started.returncode
    if not _wait_for_boot(podman, name):
        print(
            f"systemd did not finish booting in {name} within {BOOT_SECONDS}s",
            file=sys.stderr,
        )
        return 1
    prepared = _podman(
        podman,
        "exec",
        name,
        "bash",
        "-c",
        "mkdir -p /home/runner /opt && chown runner:runner /home/runner /opt",
    )
    if prepared.returncode:
        print(f"could not prepare /home/runner and /opt in {name}", file=sys.stderr)
        return 1
    try:
        archive = _archive(root, steps)
    except subprocess.CalledProcessError as error:
        print(
            f"git could not list the working tree in {root}: {error.stderr.decode().strip()}",
            file=sys.stderr,
        )
        return 1
    except OSError as error:
        print(f"could not read the working tree in {root}: {error}", file=sys.stderr)
        return 1
    copied = _podman(
        podman,
        "exec",
        "-i",
        "-u",
        "runner",
        name,
        "tar",
        "-x",
        "-C",
        "/opt",
        input=archive,
    )
    if copied.returncode:
        print(f"could not copy the working tree into {name}", file=sys.stderr)
        return 1
    total = len(steps)
    for number, step in enumerate(steps, 1):
        print(f"=== step {number}/{total}: {step.name}", flush=True)
        workdir = PurePosixPath("/opt/src", step.working_directory).as_posix()
        result = _podman(
            podman,
            "exec",
            "-u",
            "runner",
            "-w",
            workdir,
            "-e",
            "HOME=/home/runner",
            name,
            *step.shell,
            f"/opt/steps/{number:02d}.sh",
        )
        if result.returncode:
            print(
                f"=== {job}: failed at step {number}/{total} ({step.name}), "
                f"exit {result.returncode}",
                flush=True,
            )
            return result.returncode
    print(f"=== {job}: all {total} steps passed", flush=True)
    return 0


def main(argv, podman=None, root=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "job", nargs="?", help="a driver job from .github/workflows/ci.yml"
    )
    parser.add_argument(
        "--list", action="store_true", help="print the jobs that run locally"
    )
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(LOCAL_JOBS))
        return 0
    if not args.job:
        parser.error("name a job, or use --list")
    root = Path(root) if root is not None else Path(__file__).resolve().parents[1]
    local = ", ".join(LOCAL_JOBS)
    if args.job not in LOCAL_JOBS:
        drivers, _ = driver_jobs(root)
        if args.job in drivers:
            print(
                f"{args.job} needs root in the host's own namespace (loop devices or security "
                "attributes), which a rootless container does not have. It runs in CI only. "
                f"Local jobs: {local}",
                file=sys.stderr,
            )
        else:
            print(
                f"{args.job} is not a driver job. Local jobs: {local}", file=sys.stderr
            )
        return 2
    try:
        return run_job(args.job, root, podman or podman_command())
    except UnsupportedWorkflow as error:
        print(error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
