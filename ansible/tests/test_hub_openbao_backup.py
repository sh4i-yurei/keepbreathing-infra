"""The hub as a backup machine of its own, for OpenBao's snapshot (Backups decisions 72 and 74)."""

from pathlib import Path

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
ITEM = "'rclone hub (hub)'"


def read(path):
    return yaml.safe_load((ANSIBLE / path).read_text())


def test_the_hub_backs_up_into_its_own_repository_and_bucket():
    hub = read("host_vars/hub.yml")
    assert [entry for entry in hub["b2_buckets"] if entry["machine"] == "hub"] == [
        {"machine": "hub", "name": "keepbreathing-hub-backup"}
    ]
    assert [
        login for login in hub["backup_server_logins"] if login["name"] == "hub"
    ] == [
        {
            "name": "hub",
            "bcrypt": f"{{{{ lookup('vault_secret', {ITEM}, field='bcrypt') }}}}",
        }
    ]
    assert hub["b2_copy_passwords"]["hub"] == {
        "hub": f"{{{{ lookup('vault_secret', {ITEM}, field='restic') }}}}",
        "b2": f"{{{{ lookup('vault_secret', {ITEM}, field='b2_restic') }}}}",
    }


def test_the_snapshot_approle_and_the_backup_role_use_the_backup_account():
    hub = read("host_vars/hub.yml")
    snapshot = [
        approle
        for approle in hub["openbao_approles"]
        if approle["name"] == "openbao-snapshot"
    ]
    assert [approle["account"] for approle in snapshot] == ["{{ backup_server_user }}"]
    assert hub.get("openbao_backup_user") == "{{ backup_server_user }}"


def test_the_backup_role_signs_in_as_the_hub_with_the_hub_items_passwords():
    hub = read("host_vars/hub.yml")
    names = [
        "openbao_backup_login",
        "openbao_backup_password",
        "openbao_backup_restic_password",
    ]
    assert {name: hub.get(name) for name in names} == {
        "openbao_backup_login": "hub",
        "openbao_backup_password": f"{{{{ lookup('vault_secret', {ITEM}) }}}}",
        "openbao_backup_restic_password": (
            f"{{{{ lookup('vault_secret', {ITEM}, field='restic') }}}}"
        ),
    }
