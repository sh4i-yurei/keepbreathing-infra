"""The hub container account's DNS drop-in and Gatus task order (decision 56)."""

import os
from pathlib import Path
import re
import subprocess
import tomllib

import pytest
import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
HUB = ANSIBLE / "roles" / "hub"
DOMAIN = yaml.safe_load((ANSIBLE / "group_vars" / "all.yml").read_text())[
    "tailnet_domain"
]
EXPECTED = (
    "# Managed by Ansible (roles/hub). Edits here are overwritten.\n"
    "# Every container in this account asks Tailscale's resolver first and falls back to pasta's DNS\n"
    "# forwarder, whatever /etc/resolv.conf held when the container started (Ansible configuration\n"
    "# management decision 56).\n"
    "[containers]\n"
    'dns_servers = ["100.100.100.100", "169.254.1.1"]\n'
    f'dns_searches = ["{DOMAIN}"]\n'
)


def program_environment(*, config=False):
    environment = {key: os.environ[key] for key in ("PATH", "HOME")}
    environment["ANSIBLE_NOCOLOR"] = "1"
    if config:
        environment["ANSIBLE_CONFIG"] = str(ANSIBLE / "ansible.cfg")
    return environment


@pytest.fixture(scope="module")
def rendered(tmp_path_factory):
    folder = tmp_path_factory.mktemp("hub-dns")
    output = folder / "tailnet-dns.conf"
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
            f"src={HUB / 'templates' / 'tailnet-dns.conf.j2'} dest={output}",
            "-e",
            f"hub_tailnet_domain={DOMAIN}",
        ],
        cwd=folder,
        env=program_environment(),
        capture_output=True,
        text=True,
    )
    return result, output


def test_template_renders_exact_drop_in(rendered):
    result, output = rendered
    assert result.returncode == 0, result.stdout + result.stderr
    assert output.read_text() == EXPECTED


def test_rendered_drop_in_is_valid_toml(rendered):
    result, output = rendered
    assert result.returncode == 0, result.stdout + result.stderr
    assert tomllib.loads(output.read_text()) == {
        "containers": {
            "dns_servers": ["100.100.100.100", "169.254.1.1"],
            "dns_searches": [DOMAIN],
        }
    }


def play_tasks(output, name):
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


def test_hub_lists_dns_tasks_around_gatus():
    result = subprocess.run(
        ["ansible-playbook", "playbooks/hub.yml", "--list-tasks"],
        cwd=ANSIBLE,
        env=program_environment(config=True),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    tasks = play_tasks(result.stdout, "Hub services")
    setup = [
        "hub : container-dns-setup | Create the folders the container account's Podman drop-in lives in",
        "hub : container-dns-setup | Write the container account's Podman DNS drop-in",
    ]
    verify = [
        "hub : container-dns-verify | Read the running Gatus container",
        "hub : container-dns-verify | Read Gatus's resolv.conf",
        "hub : container-dns-verify | Gatus asks Tailscale's resolver first",
    ]
    first_gatus = next(
        i for i, task in enumerate(tasks) if task.startswith("hub : gatus-setup | ")
    )
    last_gatus = max(
        i for i, task in enumerate(tasks) if task.startswith("hub : gatus-setup | ")
    )
    first_verify = next(
        i for i, task in enumerate(tasks) if task.startswith("hub : gatus-verify | ")
    )
    assert tasks[first_gatus - len(setup) : first_gatus] == setup, (
        "the drop-in's first task is not listed"
    )
    assert tasks[last_gatus + 1 : last_gatus + 1 + len(verify)] == verify
    assert first_verify == last_gatus + 1 + len(verify)


def test_dns_setup_task_file_and_handler():
    tasks = yaml.safe_load((HUB / "tasks" / "container-dns-setup.yml").read_text())
    assert len(tasks) == 2
    assert tasks[0]["ansible.builtin.file"] == {
        "path": "/home/{{ hub_container_user }}/{{ item }}",
        "state": "directory",
        "owner": "{{ hub_container_user }}",
        "group": "{{ hub_container_user }}",
        "mode": "0700",
    }
    assert tasks[0]["loop"] == [
        ".config",
        ".config/containers",
        ".config/containers/containers.conf.d",
    ]
    assert tasks[1]["ansible.builtin.template"] == {
        "src": "tailnet-dns.conf.j2",
        "dest": "/home/{{ hub_container_user }}/.config/containers/containers.conf.d/tailnet-dns.conf",
        "owner": "{{ hub_container_user }}",
        "group": "{{ hub_container_user }}",
        "mode": "0644",
    }
    assert tasks[1]["notify"] == "Restart gatus"
    handlers = yaml.safe_load((HUB / "handlers" / "main.yml").read_text())
    assert "Restart gatus" in [handler["name"] for handler in handlers]
