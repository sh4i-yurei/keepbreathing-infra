"""The droplets the hub pulls: one inventory group, the hub's list and mail's tar export (Backups decision 70)."""

import os
from pathlib import Path
import re
import subprocess

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
MAIL_PATHS = [
    "etc/postfix",
    "etc/dovecot",
    "root/.secrets",
    "etc/letsencrypt/cli.ini",
    "etc/letsencrypt/renewal",
    "etc/letsencrypt/renewal-hooks",
]


def ansible_environment():
    environment = {key: os.environ[key] for key in ("PATH", "HOME")}
    environment.update(ANSIBLE_CONFIG=str(ANSIBLE / "ansible.cfg"), ANSIBLE_NOCOLOR="1")
    return environment


def run(argv):
    result = subprocess.run(
        argv, cwd=ANSIBLE, env=ansible_environment(), capture_output=True, text=True
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def listed_hosts(block):
    lines = block.splitlines()
    index = next(i for i, line in enumerate(lines) if re.match(r"^\s*hosts \(\d+\):$", line))
    count = int(re.search(r"\((\d+)\)", lines[index]).group(1))
    names = []
    for line in lines[index + 1 :]:
        if not line.strip():
            break
        names.append(line.strip())
    assert len(names) == count, block
    return set(names)


def read(path):
    return yaml.safe_load((ANSIBLE / path).read_text())


def hub_entry(key, machine):
    return [
        entry for entry in read("host_vars/hub.yml")[key] if entry["machine"] == machine
    ]


def test_the_export_group_lists_exactly_the_hubs_pull_machines():
    group = listed_hosts(
        run(["ansible", "-i", "inventory.ini", "hub_exports", "--list-hosts"])
    )
    machines = {
        entry["host"] for entry in read("host_vars/hub.yml")["hub_pull_machines"]
    }
    assert group == {"web", "mail"}
    assert machines == {"web", "mail"}
    assert group == machines


def test_mail_exports_its_configuration_as_a_tar():
    mail = read("host_vars/mail.yml")
    assert mail.get("hub_export_kind") == "tar"
    assert mail.get("hub_export_from") == "10.128.0.5"
    assert mail.get("hub_export_tar_paths") == MAIL_PATHS
    assert "hub_export_container_user" not in mail
    assert "hub_export_container" not in mail


def test_the_tar_test_vars_hold_only_the_tar_kinds_settings():
    assert set(read("tests/hub_pull/tar-export.yml")) == {
        "hub_export_kind",
        "hub_export_tar_paths",
    }


def test_the_hub_pulls_mail_into_its_own_repository_and_bucket():
    hub = read("host_vars/hub.yml")
    item = "'rclone mail (hub)'"
    assert hub_entry("hub_pull_machines", "mail") == [
        {
            "machine": "mail",
            "host": "mail",
            "address": "10.128.0.4",
            "stream": "mail-config.tar",
        }
    ]
    assert hub_entry("b2_buckets", "mail") == [
        {"machine": "mail", "name": "keepbreathing-mail-backup"}
    ]
    assert [
        login for login in hub["backup_server_logins"] if login["name"] == "mail"
    ] == [
        {
            "name": "mail",
            "bcrypt": f"{{{{ lookup('vault_secret', {item}, field='bcrypt') }}}}",
        }
    ]
    assert hub["b2_copy_passwords"]["mail"] == {
        "hub": f"{{{{ lookup('vault_secret', {item}, field='restic') }}}}",
        "b2": f"{{{{ lookup('vault_secret', {item}, field='b2_restic') }}}}",
    }
    assert hub["hub_pull_logins"]["mail"] == f"{{{{ lookup('vault_secret', {item}) }}}}"


def test_hub_pull_playbook_reaches_every_export_droplet():
    output = run(["ansible-playbook", "playbooks/hub-pull.yml", "--list-hosts"])
    blocks = re.split(r"(?=^  play #\d+ )", output, flags=re.MULTILINE)[1:]
    plays = [
        (
            re.search(r"^  play #\d+ \([^)]*\): ([^\t\n]+)", block).group(1),
            listed_hosts(block),
        )
        for block in blocks
    ]
    assert plays[0] == ("Fetch the become password", {"hub", "web", "mail"})
    assert [hosts for _, hosts in plays[1:]] == [
        {"hub"},
        {"web", "mail"},
        {"web", "mail"},
        {"hub"},
    ]
