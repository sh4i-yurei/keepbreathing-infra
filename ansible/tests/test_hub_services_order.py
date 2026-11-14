"""The order of hub.yml's services play (OpenBao on the hub decisions 55, 72 and 75).

openbao_config needs the band's account to exist, so ticket_band's account part runs before it,
and the band's service part runs after it, once its AppRole files are written. openbao_client
only installs and reads files, so it runs before both.
"""

import os
from pathlib import Path
import re
import subprocess


ANSIBLE = Path(__file__).resolve().parents[1]


def list_tasks(playbook, extra_arguments=()):
    environment = {key: os.environ[key] for key in ("PATH", "HOME")}
    environment.update(ANSIBLE_CONFIG=str(ANSIBLE / "ansible.cfg"), ANSIBLE_NOCOLOR="1")
    result = subprocess.run(
        ["ansible-playbook", playbook, "--list-tasks", *extra_arguments],
        cwd=ANSIBLE,
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def play_tasks(output, name):
    """The task names listed under one play, in order, without their tags."""
    blocks = re.split(r"(?=^  play #\d+ )", output, flags=re.MULTILINE)[1:]
    for block in blocks:
        title = re.search(r"^  play #\d+ \([^)]*\): ([^\t\n]+)", block).group(1)
        if title == name:
            return [
                line.strip().split("\t")[0]
                for line in block.splitlines()[1:]
                if line.startswith("      ")
            ]
    raise AssertionError(f"no play named {name}")


def first(tasks, matches, what):
    for index, task in enumerate(tasks):
        if matches(task):
            return index
    raise AssertionError(f"Hub services lists no {what}")


def test_hub_services_run_the_band_account_between_openbao_client_and_openbao_config():
    tasks = play_tasks(list_tasks("playbooks/hub.yml"), "Hub services")
    order = [
        first(
            tasks,
            lambda task: task.startswith("openbao_client : "),
            "openbao_client task",
        ),
        first(
            tasks,
            lambda task: task == "ticket_band : Ticket band | Create the account",
            "ticket_band account task",
        ),
        first(
            tasks,
            lambda task: task.startswith("openbao_config : "),
            "openbao_config task",
        ),
        first(
            tasks,
            lambda task: task == "ticket_band : Ticket band | Read account UID",
            "ticket_band verify task",
        ),
        first(
            tasks,
            lambda task: task.startswith("tailscale_service : "),
            "tailscale_service task",
        ),
    ]
    assert order == sorted(order) and len(set(order)) == len(order), order


def is_openbao_backup(task):
    return task.startswith("openbao_backup : ")


def test_gatus_readings_follow_tailnet_service_and_precede_backup():
    tasks = play_tasks(list_tasks("playbooks/hub.yml"), "Hub services")
    served = max(
        index
        for index, task in enumerate(tasks)
        if task.startswith("tailscale_service : ")
    )
    readings = first(
        tasks,
        lambda task: task.startswith("hub : gatus-readings-verify | "),
        "gatus-readings-verify task",
    )
    backup = first(tasks, is_openbao_backup, "openbao_backup task")
    assert served < readings < backup


def test_grafana_cloud_keys_follow_openbao_service_and_precede_readings():
    tasks = play_tasks(list_tasks("playbooks/hub.yml"), "Hub services")
    served = max(
        i for i, task in enumerate(tasks) if task.startswith("tailscale_service : ")
    )
    keys = [
        i for i, task in enumerate(tasks) if task.startswith("hub : grafana-keys | ")
    ]
    verify = [
        i
        for i, task in enumerate(tasks)
        if task.startswith("hub : grafana-keys-verify | ")
    ]
    assert keys, "Hub services lists no grafana-keys task"
    assert verify, "Hub services lists no grafana-keys-verify task"
    readings = first(
        tasks,
        lambda task: task.startswith("hub : gatus-readings-verify | "),
        "gatus-readings-verify task",
    )
    backup = first(tasks, is_openbao_backup, "openbao_backup task")
    assert (
        served < min(keys) <= max(keys) < min(verify) <= max(verify) < readings < backup
    )


def test_hub_services_run_openbao_backup_last_after_tailscale_service():
    tasks = play_tasks(list_tasks("playbooks/hub.yml"), "Hub services")
    backup = first(tasks, is_openbao_backup, "openbao_backup task")
    served = first(
        tasks,
        lambda task: task.startswith("tailscale_service : "),
        "tailscale_service task",
    )
    assert served < backup, (served, backup)
    assert all(is_openbao_backup(task) for task in tasks[backup:]), tasks[backup:]


def test_skipping_the_openbao_backup_tag_drops_only_its_tasks():
    unskipped = play_tasks(list_tasks("playbooks/hub.yml"), "Hub services")
    skipped = play_tasks(
        list_tasks("playbooks/hub.yml", ["--skip-tags", "openbao_backup"]),
        "Hub services",
    )
    assert any(is_openbao_backup(task) for task in unskipped), unskipped
    assert not any(is_openbao_backup(task) for task in skipped), skipped
    order = [
        first(
            skipped,
            lambda task: task == "ticket_band : Ticket band | Create the account",
            "ticket_band account task",
        ),
        first(
            skipped,
            lambda task: task.startswith("openbao_config : "),
            "openbao_config task",
        ),
        first(
            skipped,
            lambda task: task == "ticket_band : Ticket band | Read account UID",
            "ticket_band verify task",
        ),
        first(
            skipped,
            lambda task: task.startswith("tailscale_service : "),
            "tailscale_service task",
        ),
    ]
    assert order == sorted(order) and len(set(order)) == len(order), order
