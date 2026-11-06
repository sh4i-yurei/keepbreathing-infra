"""Run one CI driver job's own steps on the laptop, in a disposable privileged container.

The steps are read from .github/workflows/ci.yml, never copied. Each run starts a fresh
container booted with systemd, copies in the working tree, runs every run: step as the user
runner from the job's working directory, and removes the container whatever happens.
"""

import argparse
import io
import os
import shutil
import subprocess
import sys
import tarfile
import time
from dataclasses import dataclass
from pathlib import Path

import yaml

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


@dataclass
class Step:
    name: str
    script: str
    shell: list
    working_directory: str


def _jobs(workflow):
    return yaml.load(Path(workflow).read_text(), Loader=yaml.BaseLoader)["jobs"]


def job_steps(workflow, job):
    """Return a job's run: steps in order, refusing any shape the runner can't reproduce."""
    jobs = _jobs(workflow)
    if job not in jobs:
        raise ValueError(f"{job} is not a job in {WORKFLOW}")
    spec = jobs[job]
    working_directory = (
        spec.get("defaults", {}).get("run", {}).get("working-directory", "")
    )
    steps = []
    for step in spec["steps"]:
        if "run" not in step:
            continue
        script = step["run"]
        name = step.get("name") or script.splitlines()[0]
        problem = None
        if "${{" in script:
            problem = "uses a GitHub expression"
        elif step.get("shell") not in SHELLS:
            problem = f"uses shell {step['shell']}"
        elif "working-directory" in step:
            problem = "sets its own working-directory"
        elif "env" in step:
            problem = "sets its own env"
        if problem:
            raise ValueError(
                f"{job} step {len(steps) + 1} ({name}) {problem}, "
                "which the local runner cannot reproduce"
            )
        steps.append(Step(name, script, SHELLS[step.get("shell")], working_directory))
    return steps


def _is_driver(workflow, job):
    spec = _jobs(workflow).get(job, {})
    return any(
        "tests/" in step.get("run", "") and "/run.sh" in step.get("run", "")
        for step in spec.get("steps", [])
    )


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
    ).stdout.decode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for path in sorted(set(filter(None, listed.split("\0")))):
            if (root / path).is_file():
                archive.add(root / path, arcname=f"src/{path}", recursive=False)
        for number, step in enumerate(steps, 1):
            data = step.script.encode()
            info = tarfile.TarInfo(f"steps/{number:02d}.sh")
            info.size = len(data)
            info.mode = 0o644
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


def run_job(job, root, podman):
    """Run every step of one local job; return its exit status."""
    steps = job_steps(root / WORKFLOW, job)
    built = _podman(podman, "build", "-t", IMAGE, str(root / "ci" / "driver-image"))
    if built.returncode:
        print(f"could not build {IMAGE}", file=sys.stderr)
        return built.returncode
    name = f"kbi-driver-{job}-{os.getpid()}"
    started = _podman(
        podman,
        "run",
        "-d",
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
    if started.returncode:
        print(f"could not start {name}: {started.stderr.strip()}", file=sys.stderr)
        return started.returncode
    status = 1
    try:
        status = _run_in(podman, name, job, root, steps)
    finally:
        removed = _podman(podman, "rm", "-f", "-t", "10", name, capture_output=True)
        if removed.returncode:
            print(
                f"{name} was not removed; remove it with podman rm -f {name}",
                file=sys.stderr,
            )
            status = status or 1
    return status


def _run_in(podman, name, job, root, steps):
    if not _wait_for_boot(podman, name):
        print(
            f"systemd did not finish booting in {name} within {BOOT_SECONDS}s",
            file=sys.stderr,
        )
        return 1
    _podman(
        podman,
        "exec",
        name,
        "bash",
        "-c",
        "mkdir -p /home/runner /opt && chown runner:runner /home/runner /opt",
    )
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
        input=_archive(root, steps),
    )
    if copied.returncode:
        print(f"could not copy the working tree into {name}", file=sys.stderr)
        return 1
    total = len(steps)
    for number, step in enumerate(steps, 1):
        print(f"=== step {number}/{total}: {step.name}", flush=True)
        workdir = f"/opt/src/{step.working_directory}".rstrip("/")
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
        if _is_driver(root / WORKFLOW, args.job):
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
    return run_job(args.job, root, podman or podman_command())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
