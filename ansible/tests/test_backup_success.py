"""Public behaviour of node_exporter's backup success writer."""

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time

import pytest
from ansible.plugins.test.core import TestModule as CoreTests
from jinja2 import Environment
import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
REPOSITORY = ANSIBLE.parent
TEMPLATE = ANSIBLE / "roles/node_exporter/templates/backup-success"
USAGE = (
    "usage: backup-success [--if-absent] STAGE TARGET MAX_AGE_SECONDS\n"
    "       backup-success --read STAGE TARGET\n"
    "STAGE and TARGET are lower-case letters, digits and hyphens, starting with a letter or a\n"
    "digit, and MAX_AGE_SECONDS is a positive whole number.\n"
)


def metric(stage, target, timestamp, max_age):
    labels = f'stage="{stage}",target="{target}"'
    return (
        "# HELP backup_last_success_timestamp_seconds Unix time of the stage's last successful run.\n"
        "# TYPE backup_last_success_timestamp_seconds gauge\n"
        f"backup_last_success_timestamp_seconds{{{labels}}} {timestamp}\n"
        "# HELP backup_max_age_seconds Age after which the stage's last success counts as stale.\n"
        "# TYPE backup_max_age_seconds gauge\n"
        f"backup_max_age_seconds{{{labels}}} {max_age}\n"
    )


def render(script, folder):
    result = subprocess.run(
        [
            "ansible",
            "localhost",
            "-i",
            "localhost,",
            "-c",
            "local",
            "-m",
            "ansible.builtin.template",
            "-a",
            f"src={TEMPLATE} dest={script}",
            "-e",
            json.dumps({"node_exporter_textfile_directory": str(folder)}),
        ],
        cwd=REPOSITORY,
        env={
            "PATH": os.environ["PATH"],
            "HOME": os.environ["HOME"],
            "ANSIBLE_NOCOLOR": "1",
        },
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.fixture(scope="module")
def rendered(tmp_path_factory):
    root = tmp_path_factory.mktemp("backup-success")
    folder = root / "text files"
    folder.mkdir()
    script = root / "backup-success"
    render(script, folder)
    return script, folder


@pytest.fixture
def writer(rendered):
    script, folder = rendered
    for path in folder.iterdir():
        path.unlink()
    return script, folder


def run(script, *args):
    return subprocess.run(
        ["/usr/bin/bash", str(script), *args],
        cwd=REPOSITORY,
        env={"PATH": "/usr/bin:/bin"},
        capture_output=True,
        text=True,
    )


def test_a_success_is_written_whole_with_the_current_time(writer):
    script, folder = writer
    before = int(time.time())
    result = run(script, "copy", "vaultserv", "93600")
    after = int(time.time())
    path = folder / "backup-copy-vaultserv.prom"
    assert (result.returncode, result.stdout, result.stderr) == (0, "wrote\n", "")
    assert list(folder.iterdir()) == [path]
    match = re.fullmatch(r"[0-9]+", path.read_text().splitlines()[2].split(" ")[-1])
    assert match is not None
    timestamp = int(match.group())
    assert before <= timestamp <= after
    assert path.read_text() == metric("copy", "vaultserv", timestamp, 93600)
    assert stat.S_IMODE(path.stat().st_mode) == 0o644


def test_a_new_success_replaces_the_file_by_renaming(writer):
    script, folder = writer
    path = folder / "backup-pull-web.prom"
    path.write_text(metric("pull", "web", 1, 612000))
    old_inode = path.stat().st_ino
    before = int(time.time())
    result = run(script, "pull", "web", "612000")
    assert (result.returncode, result.stdout, result.stderr) == (0, "wrote\n", "")
    timestamp = int(path.read_text().splitlines()[2].split(" ")[-1])
    assert timestamp >= before
    assert path.read_text() == metric("pull", "web", timestamp, 612000)
    assert path.stat().st_ino != old_inode
    assert list(folder.iterdir()) == [path]


def test_if_absent_writes_a_first_success(writer):
    script, folder = writer
    result = run(script, "--if-absent", "prune", "hub", "612000")
    path = folder / "backup-prune-hub.prom"
    assert (result.returncode, result.stdout, result.stderr) == (0, "wrote\n", "")
    timestamp = int(path.read_text().splitlines()[2].split(" ")[-1])
    assert path.read_text() == metric("prune", "hub", timestamp, 612000)
    assert list(folder.iterdir()) == [path]


def test_if_absent_keeps_an_existing_file(writer):
    script, folder = writer
    path = folder / "backup-check-mail.prom"
    old_text = metric("check", "mail", 1, 612000)
    path.write_text(old_text)
    old_inode = path.stat().st_ino
    result = run(script, "--if-absent", "check", "mail", "93600")
    assert (result.returncode, result.stdout, result.stderr) == (0, "kept\n", "")
    assert (path.read_text(), path.stat().st_ino) == (old_text, old_inode)
    assert list(folder.iterdir()) == [path]


def test_read_prints_the_named_stages_own_time(writer):
    script, folder = writer
    for target, timestamp in (("hub", 100), ("mail", 200), ("web", 300)):
        (folder / f"backup-pull-{target}.prom").write_text(
            metric("pull", target, timestamp, 612000)
        )
    before = {p.name: p.read_text() for p in folder.iterdir()}
    result = run(script, "--read", "pull", "mail")
    assert (result.returncode, result.stdout, result.stderr) == (0, "200\n", "")
    assert {p.name: p.read_text() for p in folder.iterdir()} == before


@pytest.mark.parametrize("planted", [False, True])
def test_read_without_a_record_exits_1(writer, planted):
    script, folder = writer
    if planted:
        (folder / "backup-copy-web.prom").write_text(metric("copy", "web", 1, 93600))
    before = {p.name: p.read_text() for p in folder.iterdir()}
    result = run(script, "--read", "copy", "vaultserv")
    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "",
        "backup-success: no success recorded for copy vaultserv\n",
    )
    assert {p.name: p.read_text() for p in folder.iterdir()} == before


@pytest.mark.parametrize(
    "args",
    [
        (),
        ("copy", "vaultserv"),
        ("copy", "vaultserv", "93600", "extra"),
        ("Copy", "vaultserv", "93600"),
        ("copy", "vault serv", "93600"),
        ("copy", 'web"}', "93600"),
        ("copy", "-web", "93600"),
        ("copy", "vaultserv", "0"),
        ("copy", "vaultserv", "-5"),
        ("copy", "vaultserv", "1.5"),
        ("copy", "vaultserv", "93600s"),
        ("copy", "vaultserv", "093600"),
        ("--if-absent", "copy", "vaultserv"),
        ("--read", "copy"),
        ("--read", "copy", "vaultserv", "extra"),
        ("--read", "Copy", "vaultserv"),
    ],
)
def test_invalid_arguments_leave_no_file(writer, args):
    script, folder = writer
    result = run(script, *args)
    assert (result.returncode, result.stdout, result.stderr) == (2, "", USAGE)
    assert list(folder.iterdir()) == []


def test_a_missing_folder_fails_and_creates_nothing(tmp_path):
    folder = tmp_path / "missing text files"
    script = tmp_path / "backup-success"
    render(script, folder)
    for args in (("copy", "vaultserv", "93600"), ("--read", "copy", "vaultserv")):
        result = run(script, *args)
        assert (result.returncode, result.stdout, result.stderr) == (
            1,
            "",
            f"backup-success: {folder} is not a folder\n",
        )
        assert not folder.exists()


def list_tasks(playbook, *, roles_path=None):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": os.environ["HOME"],
        "ANSIBLE_CONFIG": str(ANSIBLE / "ansible.cfg"),
        "ANSIBLE_NOCOLOR": "1",
    }
    if roles_path:
        env["ANSIBLE_ROLES_PATH"] = str(roles_path)
    result = subprocess.run(
        ["ansible-playbook", str(playbook), "--list-tasks"],
        cwd=ANSIBLE,
        env=env,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def play_tasks(output, title):
    blocks = re.split(r"(?=^  play #\d+ )", output, flags=re.MULTILINE)[1:]
    for block in blocks:
        if re.search(rf"^  play #\d+ \([^)]*\): {re.escape(title)}(?:\t|$)", block):
            return [
                line.strip().split("\t")[0]
                for line in block.splitlines()[1:]
                if line.startswith("      ")
            ]
    raise AssertionError(f"no play named {title}")


def test_tasks_from_installs_only_the_writer_after_checking_its_input(tmp_path):
    playbook = tmp_path / "backup-success.yml"
    playbook.write_text(
        "---\n- name: Test backup success entry point\n  hosts: localhost\n"
        "  tasks:\n    - ansible.builtin.import_role:\n"
        "        name: node_exporter\n        tasks_from: backup-success\n"
    )
    output = list_tasks(playbook, roles_path=ANSIBLE / "roles")
    assert play_tasks(output, "Test backup success entry point") == [
        "node_exporter : Validating arguments against arg spec 'backup-success' - Install the writer that records each backup stage's last success",
        "node_exporter : Install the backup success writer",
    ]


@pytest.mark.parametrize(
    "playbook,title",
    [("node-exporter.yml", "Node exporter"), ("hub.yml", "Hub services")],
)
def test_every_play_with_node_exporter_installs_the_writer(playbook, title):
    tasks = play_tasks(list_tasks(ANSIBLE / "playbooks" / playbook), title)
    index = tasks.index(
        "node_exporter : Install the atomic reboot-required metric writer"
    )
    assert tasks[index + 1] == "node_exporter : Install the backup success writer"


def test_node_exporter_verify_accepts_only_an_unrecorded_stage_in_a_real_folder(
    writer, tmp_path
):
    tasks = yaml.safe_load(
        (ANSIBLE / "roles/node_exporter/tasks/verify.yml").read_text()
    )[0]["block"]

    def task_named(name):
        matches = [task for task in tasks if task["name"] == name]
        assert len(matches) == 1
        return matches[0]

    read_task = task_named(
        "verify | Ask the backup success writer about a stage nobody records"
    )
    assert_task = task_named(
        "verify | The backup success writer runs and reads the textfile folder"
    )
    argv = read_task["ansible.builtin.command"]["argv"]
    assert argv[0] == "/usr/local/libexec/backup-success"
    conditions = assert_task["ansible.builtin.assert"]["that"]
    assert all(isinstance(condition, str) for condition in conditions), conditions
    environment = Environment()
    environment.tests.update(CoreTests().tests())

    def accepts(script):
        result = run(script, *argv[1:])
        registered = {
            "rc": result.returncode,
            "stderr": result.stderr.rstrip("\r\n"),
        }
        passed = all(
            bool(
                environment.compile_expression(condition)(
                    node_exporter_backup_success_read=registered
                )
            )
            for condition in conditions
        )
        return result, passed

    script, folder = writer
    empty_result, empty_passed = accepts(script)
    assert (empty_result.returncode, empty_result.stderr) == (
        1,
        "backup-success: no success recorded for node-exporter-verify none\n",
    )
    assert empty_passed

    recorded = run(script, "node-exporter-verify", "none", "93600")
    assert recorded.returncode == 0, recorded.stderr
    recorded_result, recorded_passed = accepts(script)
    assert recorded_result.returncode == 0
    assert not recorded_passed

    missing_folder = tmp_path / "missing text files"
    missing_script = tmp_path / "backup-success"
    render(missing_script, missing_folder)
    missing_result, missing_passed = accepts(missing_script)
    assert (missing_result.returncode, missing_result.stderr) == (
        1,
        f"backup-success: {missing_folder} is not a folder\n",
    )
    assert not missing_passed
