"""The local driver runner runs a CI driver job's own steps in a disposable container."""

import json
import os
import runpy
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

from ci import run_driver
from ci.run_driver import LOCAL_JOBS, job_steps, main, podman_command

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"

FAKE_PODMAN = r"""
import json, os, sys
argv = sys.argv[1:]
data = sys.stdin.buffer.read() if "-i" in argv else b""
log = os.environ["FAKE_LOG"]
count = sum(1 for _ in open(log)) if os.path.exists(log) else 0
entry = {"argv": argv}
if data:
    path = f"{log}.stdin{count}"
    open(path, "wb").write(data)
    entry["stdin"] = path
with open(log, "a") as stream:
    stream.write(json.dumps(entry) + "\n")
fail = os.environ.get("FAKE_FAIL", "")
if fail and fail in " ".join(argv):
    print(f"fake failure for {fail}", file=sys.stderr)
    sys.exit(int(os.environ.get("FAKE_RC", "3")))
if "is-system-running" in argv:
    boots = sum(1 for line in open(log) if "is-system-running" in line)
    state = "starting" if boots <= int(os.environ.get("FAKE_BOOT_AFTER", "0")) else os.environ.get("FAKE_STATE", "degraded")
    print(state)
    sys.exit(0 if state in {"running", "degraded"} else 1)
if argv[:1] == ["rm"]:
    print(argv[-1])
if argv[:1] == ["exec"] and argv[-1].startswith("/opt/steps/"):
    print(f"ran {argv[-1]}")
"""


@pytest.fixture
def fake(tmp_path, monkeypatch):
    script = tmp_path / "fake_podman.py"
    script.write_text(FAKE_PODMAN)
    log = tmp_path / "podman.log"
    monkeypatch.setenv("FAKE_LOG", str(log))

    def calls():
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines()]

    return [sys.executable, str(script)], calls


def step_calls(calls):
    return [
        c["argv"]
        for c in calls()
        if c["argv"][0] == "exec" and c["argv"][-1].startswith("/opt/steps/")
    ]


def test_openbao_steps_come_from_ci_yml_in_order_with_github_default_shell():
    steps = job_steps(WORKFLOW, "openbao")

    assert [s.name for s in steps] == [
        "pip install -r ../requirements.txt",
        "ansible-galaxy collection install -r collections/requirements.yml",
        "sudo apt-get update && sudo apt-get install -y podman passt",
        "Existing account is preserved",
        "Occupied port is preserved",
        "Deliberate role failure cleans up",
        "OpenBao role integration cases",
        "Full driver cleans up",
    ]
    assert {s.working_directory for s in steps} == {"ansible"}
    assert {tuple(s.shell) for s in steps} == {("bash", "-e")}
    assert steps[6].script.startswith('if sudo env "PATH=$PATH"')


def test_named_bash_shell_runs_with_githubs_bash_flags():
    steps = job_steps(WORKFLOW, "break-glass-sheet")

    assert steps[-1].name == "Break-glass role integration cases and cleanup"
    assert steps[-1].shell == ["bash", "--noprofile", "--norc", "-eo", "pipefail"]
    assert steps[0].shell == ["bash", "-e"]


@pytest.mark.parametrize(
    ("step", "message"),
    [
        ({"run": "echo ${{ matrix.os }}"}, "uses a GitHub expression"),
        ({"run": "print(1)", "shell": "python"}, "uses shell python"),
        ({"run": "ls", "working-directory": "roles"}, "sets its own working-directory"),
        ({"run": "ls", "env": {"A": "1"}}, "sets its own env"),
    ],
)
def test_step_shapes_the_runner_cannot_reproduce_are_refused(tmp_path, step, message):
    workflow = tmp_path / "ci.yml"
    step = {"name": "odd step", **step}
    workflow.write_text(
        json.dumps(
            {"jobs": {"demo": {"steps": [{"uses": "actions/checkout@v7"}, step]}}}
        )
    )

    with pytest.raises(ValueError) as error:
        job_steps(workflow, "demo")

    assert (
        str(error.value)
        == f"demo step 1 (odd step) {message}, which the local runner cannot reproduce"
    )


def test_unknown_job_is_refused():
    with pytest.raises(ValueError) as error:
        job_steps(WORKFLOW, "no-such-job")

    assert str(error.value) == "no-such-job is not a job in .github/workflows/ci.yml"


def test_job_without_working_directory_runs_from_the_repository_root(tmp_path):
    workflow = tmp_path / "ci.yml"
    workflow.write_text(json.dumps({"jobs": {"demo": {"steps": [{"run": "ls"}]}}}))

    assert job_steps(workflow, "demo")[0].working_directory == ""
    assert job_steps(workflow, "demo")[0].name == "ls"


def test_local_jobs_are_exactly_the_two_proven_on_2026_11_05():
    assert LOCAL_JOBS == ("b2-bucket", "openbao")


@pytest.mark.parametrize(
    "job",
    [
        "b2-copy",
        "backup-server",
        "break-glass-sheet",
        "hub-backup-disk",
        "vaultwarden-backup",
    ],
)
def test_driver_jobs_that_need_host_root_are_refused_before_podman_starts(
    job, fake, capsys
):
    podman, calls = fake

    assert main([job], podman=podman) == 2

    assert capsys.readouterr().err == (
        f"{job} needs root in the host's own namespace (loop devices or security attributes), "
        "which a rootless container does not have. It runs in CI only. "
        "Local jobs: b2-bucket, openbao\n"
    )
    assert calls() == []


def test_a_name_that_is_not_a_driver_job_is_refused(fake, capsys):
    podman, calls = fake

    assert main(["syntax-check"], podman=podman) == 2

    assert capsys.readouterr().err == (
        "syntax-check is not a driver job. Local jobs: b2-bucket, openbao\n"
    )
    assert calls() == []


def test_no_job_name_is_a_usage_error(capsys):
    with pytest.raises(SystemExit) as exit_:
        main([])

    assert exit_.value.code == 2
    assert capsys.readouterr().err.endswith("error: name a job, or use --list\n")


def test_list_prints_the_local_jobs(capsys):
    assert main(["--list"]) == 0

    assert capsys.readouterr().out == "b2-bucket\nopenbao\n"


def test_openbao_runs_every_step_as_runner_and_removes_its_container(fake, capfd):
    podman, calls = fake

    assert main(["openbao"], podman=podman, root=ROOT) == 0

    name = f"kbi-driver-openbao-{os.getpid()}"
    argvs = [c["argv"] for c in calls()]
    assert argvs[0] == [
        "build",
        "-t",
        "localhost/kbi-driver-runner",
        str(ROOT / "ci" / "driver-image"),
    ]
    assert argvs[1] == [
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
        "localhost/kbi-driver-runner",
    ]
    assert argvs[2] == ["exec", name, "systemctl", "is-system-running"]
    assert argvs[3] == [
        "exec",
        name,
        "bash",
        "-c",
        "mkdir -p /home/runner /opt && chown runner:runner /home/runner /opt",
    ]
    assert argvs[4] == ["exec", "-i", "-u", "runner", name, "tar", "-x", "-C", "/opt"]
    assert argvs[5:13] == [
        [
            "exec",
            "-u",
            "runner",
            "-w",
            "/opt/src/ansible",
            "-e",
            "HOME=/home/runner",
            name,
            "bash",
            "-e",
            f"/opt/steps/{n:02d}.sh",
        ]
        for n in range(1, 9)
    ]
    assert argvs[13:] == [["rm", "-f", "-t", "10", name]]
    names = [s.name for s in job_steps(WORKFLOW, "openbao")]
    expected = []
    for n, step_name in enumerate(names, 1):
        expected += [f"=== step {n}/8: {step_name}", f"ran /opt/steps/{n:02d}.sh"]
    expected.append("=== openbao: all 8 steps passed")
    assert capfd.readouterr().out.splitlines() == expected


def test_a_failing_step_stops_the_job_and_still_removes_the_container(
    fake, monkeypatch, capsys
):
    podman, calls = fake
    monkeypatch.setenv("FAKE_FAIL", "/opt/steps/06.sh")

    assert main(["openbao"], podman=podman, root=ROOT) == 3

    assert [s[-1] for s in step_calls(calls)] == [
        f"/opt/steps/{n:02d}.sh" for n in range(1, 7)
    ]
    assert calls()[-1]["argv"][:2] == ["rm", "-f"]
    out = capsys.readouterr().out
    assert out.endswith(
        "=== openbao: failed at step 6/8 (Deliberate role failure cleans up), exit 3\n"
    )


def test_the_copy_holds_the_working_tree_and_the_step_scripts(fake, tmp_path):
    podman, calls = fake
    repo = tmp_path / "repo"
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / "ansible").mkdir()
    (repo / ".github" / "workflows" / "ci.yml").write_text(WORKFLOW.read_text())
    (repo / "ansible" / "tracked.txt").write_text("committed\n")
    (repo / ".gitignore").write_text("ignored.txt\n")
    (repo / "ansible" / "link.txt").symlink_to("tracked.txt")
    git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run([*git, "init", "-q"], check=True)
    subprocess.run([*git, "add", "."], check=True)
    subprocess.run([*git, "commit", "-qm", "base"], check=True)
    (repo / "ansible" / "tracked.txt").write_text("edited, not committed\n")
    (repo / "ansible" / "new.txt").write_text("untracked\n")
    (repo / "ignored.txt").write_text("ignored\n")
    (repo / "gone.txt").write_text("x")
    subprocess.run([*git, "add", "gone.txt"], check=True)
    (repo / "gone.txt").unlink()

    assert main(["b2-bucket"], podman=podman, root=repo) == 0

    copies = [c for c in calls() if c["argv"][0] == "exec" and "tar" in c["argv"]]
    assert len(copies) == 1
    assert copies[0]["argv"][copies[0]["argv"].index("-u") + 1] == "runner"
    with tarfile.open(copies[0]["stdin"]) as archive:
        names = set(archive.getnames())
        tracked = archive.extractfile("src/ansible/tracked.txt").read()
        step = archive.extractfile("steps/05.sh").read().decode()
        link = archive.getmember("src/ansible/link.txt")
    assert link.issym() and link.linkname == "tracked.txt"
    assert {
        "src/ansible/tracked.txt",
        "src/ansible/new.txt",
        "src/.github/workflows/ci.yml",
    } <= names
    assert "src/ignored.txt" not in names
    assert "src/gone.txt" not in names
    assert tracked == b"edited, not committed\n"
    assert {f"steps/{n:02d}.sh" for n in range(1, 6)} <= names
    assert step == job_steps(WORKFLOW, "b2-bucket")[4].script


def test_a_failed_copy_runs_no_step_and_removes_the_container(
    fake, monkeypatch, capsys
):
    podman, calls = fake
    monkeypatch.setenv("FAKE_FAIL", "tar -x")
    monkeypatch.setenv("FAKE_RC", "1")

    assert main(["openbao"], podman=podman, root=ROOT) == 1

    assert step_calls(calls) == []
    assert calls()[-1]["argv"][:2] == ["rm", "-f"]
    assert "could not copy the working tree into" in capsys.readouterr().err


def test_a_container_whose_systemd_never_boots_is_removed(fake, monkeypatch, capsys):
    podman, calls = fake
    monkeypatch.setenv("FAKE_STATE", "starting")
    monkeypatch.setattr(run_driver, "BOOT_SECONDS", 0.3)
    monkeypatch.setattr(run_driver, "BOOT_POLL", 0.1)

    assert main(["openbao"], podman=podman, root=ROOT) == 1

    assert step_calls(calls) == []
    assert calls()[-1]["argv"][:2] == ["rm", "-f"]
    assert "systemd did not finish booting in" in capsys.readouterr().err


def test_a_failed_image_build_starts_no_container(fake, monkeypatch, capsys):
    podman, calls = fake
    monkeypatch.setenv("FAKE_FAIL", "build")
    monkeypatch.setenv("FAKE_RC", "125")

    assert main(["openbao"], podman=podman, root=ROOT) == 125

    assert [c["argv"][0] for c in calls()] == ["build"]
    assert "could not build" in capsys.readouterr().err


def test_a_container_that_cannot_start_is_not_removed_twice(fake, monkeypatch, capsys):
    podman, calls = fake
    monkeypatch.setenv("FAKE_FAIL", "--systemd=always")
    monkeypatch.setenv("FAKE_RC", "125")

    assert main(["openbao"], podman=podman, root=ROOT) == 125

    assert [c["argv"][0] for c in calls()] == ["build", "run"]
    assert capsys.readouterr().err == (
        f"could not start kbi-driver-openbao-{os.getpid()}: fake failure for --systemd=always\n"
    )


def test_a_container_left_behind_is_reported_and_fails_the_run(
    fake, monkeypatch, capsys
):
    podman, _calls = fake
    monkeypatch.setenv("FAKE_FAIL", "rm -f")
    monkeypatch.setenv("FAKE_RC", "1")

    assert main(["openbao"], podman=podman, root=ROOT) == 1

    assert "was not removed; remove it with podman rm -f" in capsys.readouterr().err


def test_podman_runs_directly_on_the_host_and_through_distrobox_inside_dev(monkeypatch):
    monkeypatch.setattr(
        run_driver.shutil,
        "which",
        lambda name: "/usr/bin/podman" if name == "podman" else None,
    )
    assert podman_command() == ["podman"]
    monkeypatch.setattr(run_driver.shutil, "which", lambda name: None)
    assert podman_command() == ["distrobox-host-exec", "podman"]


def test_the_script_entry_point_lists_the_local_jobs(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["run_driver.py", "--list"])

    with pytest.raises(SystemExit) as exit_:
        runpy.run_path(str(ROOT / "ci" / "run_driver.py"), run_name="__main__")

    assert exit_.value.code == 0
    assert capsys.readouterr().out == "b2-bucket\nopenbao\n"


@pytest.mark.parametrize("state", ["running", "degraded"])
def test_the_runner_waits_for_systemd_to_finish_booting(fake, monkeypatch, state):
    podman, calls = fake
    monkeypatch.setenv("FAKE_BOOT_AFTER", "2")
    monkeypatch.setenv("FAKE_STATE", state)
    monkeypatch.setattr(run_driver, "BOOT_POLL", 0.01)

    assert main(["openbao"], podman=podman, root=ROOT) == 0

    boots = [c for c in calls() if "is-system-running" in c["argv"]]
    assert len(boots) == 3
    assert len(step_calls(calls)) == 8


def test_a_failed_preparation_copies_nothing_and_removes_the_container(
    fake, monkeypatch, capsys
):
    podman, calls = fake
    monkeypatch.setenv("FAKE_FAIL", "mkdir -p")
    monkeypatch.setenv("FAKE_RC", "1")

    assert main(["openbao"], podman=podman, root=ROOT) == 1

    assert not [c for c in calls() if "tar" in c["argv"]]
    assert calls()[-1]["argv"][:2] == ["rm", "-f"]
    assert capsys.readouterr().err == (
        f"could not prepare /home/runner and /opt in kbi-driver-openbao-{os.getpid()}\n"
    )


def test_a_tree_git_cannot_list_runs_no_step(fake, tmp_path, monkeypatch, capsys):
    podman, calls = fake
    (tmp_path / ".github" / "workflows").mkdir(parents=True)
    (tmp_path / ".github" / "workflows" / "ci.yml").write_text(WORKFLOW.read_text())
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path.parent))

    assert main(["openbao"], podman=podman, root=tmp_path) == 1

    assert step_calls(calls) == []
    assert calls()[-1]["argv"][:2] == ["rm", "-f"]
    assert capsys.readouterr().err.startswith(
        f"git could not list the working tree in {tmp_path}: fatal: not a git repository"
    )


def test_a_job_without_a_working_directory_runs_from_the_tree_root(fake, tmp_path):
    podman, calls = fake
    repo = tmp_path / "repo"
    (repo / ".github" / "workflows").mkdir(parents=True)
    (repo / ".github" / "workflows" / "ci.yml").write_text(
        json.dumps({"jobs": {"openbao": {"steps": [{"run": "bash tests/x/run.sh"}]}}})
    )
    subprocess.run(["git", "init", "-q", str(repo)], check=True)

    assert main(["openbao"], podman=podman, root=repo) == 0

    (step,) = step_calls(calls)
    assert step[step.index("-w") + 1] == "/opt/src"


@pytest.mark.parametrize(
    ("job", "driver"),
    [
        ("real", True),
        ("tests-only", False),
        ("flat-run", False),
        ("reusable", False),
        ("absent", False),
    ],
)
def test_only_a_job_running_a_test_folders_run_sh_counts_as_a_driver(
    fake, tmp_path, capsys, job, driver
):
    podman, calls = fake
    (tmp_path / ".github" / "workflows").mkdir(parents=True)
    (tmp_path / ".github" / "workflows" / "ci.yml").write_text(
        json.dumps(
            {
                "jobs": {
                    "real": {
                        "steps": [
                            {"uses": "actions/checkout@v7"},
                            {"run": "sudo bash tests/x/run.sh"},
                        ]
                    },
                    "tests-only": {
                        "steps": [{"run": "python3 -m pytest ansible/tests/"}]
                    },
                    "flat-run": {"steps": [{"run": "bash tests/run.sh"}]},
                    "reusable": {
                        "uses": "sh4i-yurei/ci-workflows/.github/workflows/python.yml@v1"
                    },
                }
            }
        )
    )

    assert main([job], podman=podman, root=tmp_path) == 2

    err = capsys.readouterr().err
    assert err.startswith(f"{job} needs root") is driver
    assert err.startswith(f"{job} is not a driver job") is not driver
    assert calls() == []


def test_help_names_the_runner_and_its_options(capsys):
    with pytest.raises(SystemExit):
        main(["--help"])

    out = " ".join(capsys.readouterr().out.split())
    assert (
        "Run one CI driver job's own steps on the laptop, in a disposable privileged container."
        in out
    )
    assert "job a driver job from .github/workflows/ci.yml" in out
    assert "--list print the jobs that run locally" in out


def test_step_lines_come_before_each_steps_output_when_stdout_is_buffered(
    fake, monkeypatch, capfd
):
    podman, _calls = fake
    # A pipe or a file makes Python's stdout block-buffered, while each step writes
    # straight to the same file descriptor.
    with open(1, "w", buffering=65536, closefd=False) as buffered:
        monkeypatch.setattr(sys, "stdout", buffered)
        status = main(["openbao"], podman=podman, root=ROOT)
        buffered.flush()

    assert status == 0
    lines = capfd.readouterr().out.splitlines()
    assert lines[:4] == [
        "=== step 1/8: pip install -r ../requirements.txt",
        "ran /opt/steps/01.sh",
        "=== step 2/8: ansible-galaxy collection install -r collections/requirements.yml",
        "ran /opt/steps/02.sh",
    ]
    assert lines[-1] == "=== openbao: all 8 steps passed"
