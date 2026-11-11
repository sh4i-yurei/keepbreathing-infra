"""The journal gateway socket binds before its configured address exists."""

import os
from pathlib import Path
import subprocess

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
ROLE = ANSIBLE / "roles" / "journal_gateway"
LISTEN_ADDRESS = yaml.safe_load((ANSIBLE / "host_vars" / "vaultserv.yml").read_text())[
    "journal_gateway_listen_address"
]
EXPECTED = (
    "# Managed by Ansible (roles/journal_gateway). Edits here are overwritten.\n"
    "[Socket]\n"
    "ListenStream=\n"
    "ListenStream=100.65.221.62:19531\n"
    "FreeBind=yes\n"
)


def test_socket_template_renders_freebind(tmp_path):
    environment = {key: os.environ[key] for key in ("PATH", "HOME")}
    environment["ANSIBLE_NOCOLOR"] = "1"
    output = tmp_path / "10-listen-address.conf"
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
            f"src={ROLE / 'templates' / 'systemd-journal-gatewayd.socket.conf.j2'} dest={output}",
            "-e",
            f"journal_gateway_listen_address={LISTEN_ADDRESS}",
        ],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert output.read_text() == EXPECTED


def test_verify_requires_freebind():
    tasks = yaml.safe_load((ROLE / "tasks" / "verify.yml").read_text())
    socket_check = next(
        task
        for task in tasks[0]["block"]
        if task["name"]
        == "verify | Require the gateway socket to be active and enabled"
    )
    assert socket_check["ansible.builtin.assert"]["that"] == [
        "journal_gateway_socket_status.status.ActiveState == 'active'",
        "journal_gateway_socket_status.status.UnitFileState == 'enabled'",
        "journal_gateway_socket_status.status.FreeBind == 'yes'",
    ]
