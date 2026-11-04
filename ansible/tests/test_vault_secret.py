"""Vault lookup behaviour with a private fake CLI and session file."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import traceback
import types

import pytest
import yaml
from ansible.errors import AnsibleLookupError
from ansible.parsing.dataloader import DataLoader
import ansible
from ansible.plugins.loader import PluginLoader, lookup_loader
from ansible.plugins.lookup import LookupBase
from ansible.template import Templar
from jinja2 import ChainableUndefined, Environment
from jinja2.nativetypes import NativeEnvironment


ANSIBLE = Path(__file__).resolve().parents[1]
ITEM = "keepbreath0 sudo (hub)"
HASH = "$y$j9T$madeupsalt$madeuphash"


@pytest.fixture
def vault(tmp_path, monkeypatch):
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "calls.jsonl"
    fake = bin_dir / "bw"
    fake.write_text(
        """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

with Path(os.environ['FAKE_BW_LOG']).open('a') as log:
    log.write(json.dumps({'argv': sys.argv[1:], 'session': os.environ.get('BW_SESSION'),
                          'nointeraction': os.environ.get('BW_NOINTERACTION')}) + '\\n')
failure = os.environ.get('FAKE_BW_FAILURE')
if failure:
    if failure == 'hostile':
        print('HOSTILE-STDOUT')
        print('HOSTILE-STDERR', file=sys.stderr)
    else:
        print(failure, file=sys.stderr)
    sys.exit(1)
if os.environ.get('FAKE_BW_BAD_JSON'):
    print('HOSTILE-STDOUT')
    sys.exit(0)
items = json.loads(os.environ['FAKE_BW_ITEMS'])
item = items[sys.argv[3]]
if sys.argv[1:3] == ['get', 'item']:
    print(json.dumps(item))
elif sys.argv[1:3] == ['get', 'password']:
    print(item['login']['password'])
else:
    sys.exit(1)
"""
    )
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir) + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(runtime))
    monkeypatch.setenv("FAKE_BW_LOG", str(log))
    monkeypatch.delenv("BW_SESSION", raising=False)
    monkeypatch.delenv("BW_NOINTERACTION", raising=False)
    monkeypatch.delenv("FAKE_BW_FAILURE", raising=False)
    item = {
        "object": "item",
        "name": ITEM,
        "login": {"username": "prom-user-1", "password": "pw-hub-1"},
        "fields": [
            {"name": "hash", "value": HASH, "type": 1},
            {"name": "token", "value": "token-1", "type": 1},
        ],
    }
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    lookup_loader.add_directory(str(ANSIBLE / "lookup_plugins"))
    return {"runtime": runtime, "log": log, "item": item}


def call(item=ITEM, **options):
    package = "ansible.lookup_plugins"
    if package not in sys.modules:
        namespace = types.ModuleType(package)
        namespace.__file__ = str(ANSIBLE / "lookup_plugins" / "__init__.py")
        namespace.__path__ = [str(ANSIBLE / "lookup_plugins")]
        namespace.LookupBase = LookupBase
        sys.modules[package] = namespace
        ansible.lookup_plugins = namespace
    plugin_loader = PluginLoader(
        "LookupModule",
        package,
        "DEFAULT_LOOKUP_PLUGIN_PATH",
        "lookup_plugins",
        required_base_class="LookupBase",
    )
    plugin_loader.add_directory(str(ANSIBLE / "lookup_plugins"))
    loader = DataLoader()
    plugin = plugin_loader.get(
        "vault_secret", loader=loader, templar=Templar(loader=loader)
    )
    assert plugin is not None
    return plugin.run([item], variables={}, **options)[0]


def calls(vault):
    return (
        [json.loads(line) for line in vault["log"].read_text().splitlines()]
        if vault["log"].exists()
        else []
    )


def session_file(vault, value="key-file-1"):
    (vault["runtime"] / "bw-session").write_text(value)


def test_password_from_session_file(vault):
    session_file(vault)
    assert call() == "pw-hub-1"
    assert calls(vault) == [
        {
            "argv": ["get", "item", ITEM],
            "session": "key-file-1",
            "nointeraction": "true",
        }
    ]
    assert "key-file-1" not in repr(calls(vault)[0]["argv"])


def test_hash_field(vault):
    session_file(vault)
    assert call(field="hash") == HASH


def test_token_field_is_selected_exactly(vault):
    session_file(vault)
    assert call(field="token") == "token-1"


def test_environment_session_precedes_file(vault, monkeypatch):
    session_file(vault)
    monkeypatch.setenv("BW_SESSION", "key-env-1")
    assert call() == "pw-hub-1"
    assert calls(vault) == [
        {"argv": ["get", "item", ITEM], "session": "key-env-1", "nointeraction": "true"}
    ]


def test_stale_environment_session_does_not_retry_file(vault, monkeypatch):
    session_file(vault)
    monkeypatch.setenv("BW_SESSION", "key-env-1")
    monkeypatch.setenv("FAKE_BW_FAILURE", "Vault is locked.")
    with pytest.raises(AnsibleLookupError) as error:
        call()
    shown = str(error.value) + "\n" + "".join(traceback.format_exception(error.value))
    assert str(error.value) == (
        f"Vault lookup failed for item {ITEM!r} using inherited BW_SESSION; run vu."
    )
    assert "key-env-1" not in shown and "key-file-1" not in shown
    assert calls(vault) == [
        {"argv": ["get", "item", ITEM], "session": "key-env-1", "nointeraction": "true"}
    ]


def test_no_session_fails_before_cli(vault):
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert str(error.value) == f"Vault lookup failed for item {ITEM!r}; run vu."
    assert calls(vault) == []


@pytest.mark.parametrize(
    "failure",
    [
        "Not found.",
        "More than one result was found. Try getting a specific object by `id` instead. ",
    ],
)
def test_cli_refusals_are_redacted(vault, monkeypatch, failure):
    session_file(vault)
    monkeypatch.setenv("FAKE_BW_FAILURE", failure)
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert ITEM in str(error.value) and "run vu" in str(error.value)
    assert failure not in str(error.value)
    assert len(calls(vault)) == 1


@pytest.mark.parametrize(
    "fields",
    [
        [],
        [
            {"name": "hash", "value": "first-secret", "type": 1},
            {"name": "hash", "value": "second-secret", "type": 1},
        ],
    ],
)
def test_missing_or_duplicate_field(vault, monkeypatch, fields):
    session_file(vault)
    item = vault["item"] | {"fields": fields}
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    with pytest.raises(AnsibleLookupError) as error:
        call(field="hash")
    assert ITEM in str(error.value) and "hash" in str(error.value)
    assert all(
        value not in str(error.value)
        for value in ["pw-hub-1", "first-secret", "second-secret"]
    )


def test_field_lookup_when_item_omits_fields(vault, monkeypatch):
    session_file(vault)
    item = {key: value for key, value in vault["item"].items() if key != "fields"}
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    with pytest.raises(AnsibleLookupError) as error:
        call(field="hash")
    assert str(error.value) == (
        f"Vault lookup failed for item {ITEM!r} field 'hash' "
        "using runtime session file; run vu."
    )
    assert "pw-hub-1" not in str(error.value)
    assert len(calls(vault)) == 1


def test_missing_password(vault, monkeypatch):
    session_file(vault)
    item = vault["item"] | {"login": {"username": "prom-user-1"}}
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert ITEM in str(error.value)


def test_malformed_login_is_a_safe_lookup_error(vault, monkeypatch):
    session_file(vault)
    item = vault["item"] | {"login": "malformed-login"}
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert str(error.value) == (
        f"Vault lookup failed for item {ITEM!r} using runtime session file; run vu."
    )


def test_login_username(vault):
    session_file(vault)
    assert call(login="username") == "prom-user-1"
    assert len(calls(vault)) == 1


def test_missing_login_username(vault, monkeypatch):
    session_file(vault)
    item = vault["item"] | {"login": {"password": "pw-hub-1"}}
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps({ITEM: item}))
    with pytest.raises(AnsibleLookupError) as error:
        call(login="username")
    assert (
        ITEM in str(error.value)
        and "pw-hub-1" not in str(error.value)
        and HASH not in str(error.value)
    )


def test_conflicting_selectors_do_not_call_cli(vault):
    session_file(vault)
    with pytest.raises(AnsibleLookupError) as error:
        call(login="username", field="hash")
    assert ITEM in str(error.value)
    assert calls(vault) == []


def test_hostile_cli_output_and_traceback_are_redacted(vault, monkeypatch, capfd):
    session_file(vault)
    monkeypatch.setenv("FAKE_BW_FAILURE", "hostile")
    with pytest.raises(AnsibleLookupError) as error:
        call()
    shown = str(error.value) + "\n" + "".join(traceback.format_exception(error.value))
    captured = capfd.readouterr()
    assert all(
        value not in shown
        for value in ["HOSTILE-STDOUT", "HOSTILE-STDERR", "key-file-1"]
    )
    assert "HOSTILE-STDERR" not in captured.out + captured.err


def test_runtime_session_source_is_named_on_failure(vault, monkeypatch):
    session_file(vault)
    monkeypatch.setenv("FAKE_BW_FAILURE", "hostile")
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert str(error.value) == (
        f"Vault lookup failed for item {ITEM!r} using runtime session file; run vu."
    )


def test_empty_field_is_rejected_before_cli(vault):
    session_file(vault)
    with pytest.raises(AnsibleLookupError) as error:
        call(field="")
    assert ITEM in str(error.value) and "run vu" in str(error.value)
    assert calls(vault) == []


def test_missing_cli_is_a_safe_lookup_error(vault, monkeypatch, tmp_path):
    session_file(vault)
    empty_path = tmp_path / "empty-path"
    empty_path.mkdir()
    monkeypatch.setenv("PATH", str(empty_path))
    with pytest.raises(AnsibleLookupError) as error:
        call()
    assert ITEM in str(error.value) and "run vu" in str(error.value)
    assert "key-file-1" not in "".join(traceback.format_exception(error.value))
    assert calls(vault) == []


def test_invalid_item_json_is_a_safe_lookup_error(vault, monkeypatch):
    session_file(vault)
    monkeypatch.setenv("FAKE_BW_BAD_JSON", "1")
    with pytest.raises(AnsibleLookupError) as error:
        call()
    shown = str(error.value) + "".join(traceback.format_exception(error.value))
    assert ITEM in shown and "run vu" in shown
    assert "HOSTILE-STDOUT" not in shown and "key-file-1" not in shown
    assert len(calls(vault)) == 1


def run_become_play(vault, tmp_path, monkeypatch, *, verbose=False):
    inventory_dir = tmp_path / "inventory"
    inventory_dir.mkdir()
    (inventory_dir / "hosts.ini").write_text(
        "alpha ansible_connection=local\nbeta ansible_connection=local\n"
    )
    (inventory_dir / "group_vars").mkdir()
    (inventory_dir / "group_vars" / "all.yml").write_text(
        (ANSIBLE / "group_vars" / "all.yml").read_text()
    )
    items = {}
    for host in ("alpha", "beta"):
        name = f"keepbreath0 sudo ({host})"
        items[name] = {
            "object": "item",
            "name": name,
            "login": {"username": "admin", "password": f"pw-{host}-1"},
            "fields": [{"name": "hash", "value": "hash-1", "type": 1}],
        }
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps(items))
    play = tmp_path / "play.yml"
    play.write_text(
        f"- import_playbook: {ANSIBLE / 'playbooks' / 'become-password.yml'}\n"
        "- hosts: all\n"
        "  gather_facts: false\n"
        "  become: false\n"
        "  tasks:\n"
        "    - name: Read the stored password three times\n"
        "      ansible.builtin.assert:\n"
        "        that:\n"
        "          - ansible_become_password == ('pw-' ~ inventory_hostname ~ '-1')\n"
        "          - ansible_become_password == ('pw-' ~ inventory_hostname ~ '-1')\n"
        "          - ansible_become_password == ('pw-' ~ inventory_hostname ~ '-1')\n"
        "      no_log: true\n"
    )
    environment = os.environ.copy()
    # The play is a child process; mutmut records lookup hits in this pytest process.
    environment.pop("MUTANT_UNDER_TEST", None)
    environment["ANSIBLE_CONFIG"] = str(ANSIBLE / "ansible.cfg")
    environment["ANSIBLE_NOCOLOR"] = "1"
    command = ["ansible-playbook", "-i", str(inventory_dir / "hosts.ini"), str(play)]
    if verbose:
        command += ["-vvv", "--check", "--diff"]
    return subprocess.run(
        command, cwd=ANSIBLE, env=environment, capture_output=True, text=True
    )


@pytest.mark.parametrize("verbose", [False, True])
def test_become_play_reads_once_per_host_and_redacts(
    vault, tmp_path, monkeypatch, verbose
):
    session_file(vault)
    result = run_become_play(vault, tmp_path, monkeypatch, verbose=verbose)
    shown = result.stdout + result.stderr
    assert result.returncode == 0, shown
    assert "failed=0" in shown
    assert all(
        value not in shown for value in ["pw-alpha-1", "pw-beta-1", "key-file-1"]
    )
    assert sorted(entry["argv"] for entry in calls(vault)) == [
        ["get", "item", "keepbreath0 sudo (alpha)"],
        ["get", "item", "keepbreath0 sudo (beta)"],
    ]


def test_become_play_stops_on_missing_session(vault, tmp_path, monkeypatch):
    result = run_become_play(vault, tmp_path, monkeypatch)
    shown = result.stdout + result.stderr
    assert result.returncode != 0
    assert "keepbreath0 sudo (alpha)" in shown and "run vu" in shown
    assert "Read the stored password three times" not in shown
    assert calls(vault) == []


def test_every_vault_read_uses_the_repository_lookup():
    legacy = [
        str(path.relative_to(ANSIBLE))
        for path in ANSIBLE.rglob("*")
        if path.is_file()
        and path.suffix in {".yml", ".j2"}
        and (
            ("ansible.builtin.pipe'" + ", 'bw ") in path.read_text()
            or ("bw" + " unlock") in path.read_text()
        )
    ]
    assert legacy == []


VAULT_VALUES = {
    "group_vars/all.yml": ["ansible_become_password", "access_admin_password_hash"],
    "group_vars/droplets.yml": [
        "node_exporter_basic_auth_password",
        "node_exporter_basic_auth_hash",
        "podman_exporter_basic_auth_password",
        "podman_exporter_basic_auth_hash",
    ],
    "host_vars/vaultserv.yml": [
        "node_exporter_basic_auth_password",
        "node_exporter_basic_auth_hash",
        "podman_exporter_basic_auth_password",
        "podman_exporter_basic_auth_hash",
        "vaultwarden_backup_password",
        "vaultwarden_backup_restic_password",
    ],
    "host_vars/hub.yml": [
        "backup_server_logins",
        "backup_server_verify_password",
        "backup_server_verify_restic_password",
        "b2_master_key_id",
        "b2_master_key",
    ],
    "roles/hub/tasks/alertmanager-verify.yml": ["hub_alertmanager_login"],
    "roles/hub/tasks/grafana-verify.yml": [
        "hub_grafana_admin_password",
        "hub_grafana_metrics_password",
    ],
    "roles/hub/tasks/ntfy-verify.yml": ["hub_ntfy_fields"],
    "roles/hub/tasks/prometheus-setup.yml": ["content"],
}
VAULT_TEMPLATES = [
    "roles/hub/templates/alertmanager-web.yml.j2",
    "roles/hub/templates/alertmanager-ntfy-token.j2",
    "roles/hub/templates/gatus-config.yaml.j2",
    "roles/hub/templates/grafana-admin-password.j2",
    "roles/hub/templates/grafana-datasources.yml.j2",
    "roles/hub/templates/grafana-prometheus-password.j2",
    "roles/hub/templates/ntfy-server.yml.j2",
    "roles/hub/templates/prometheus-alertmanager-password.j2",
]


def fixture_items():
    names = [
        "keepbreath0 sudo (alpha)",
        "node_exporter prometheus (alpha)",
        "podman_exporter prometheus (alpha)",
        "alertmanager prometheus (hub)",
        "grafana admin (hub)",
        "grafana prometheus (hub)",
        "github app grafana (hub)",
        "ntfy gatus (hub)",
        "github gatus (hub)",
        "ntfy alertmanager (hub)",
        "ntfy mark (hub)",
        "ntfy laptop (hub)",
        "ntfy alpha (hub)",
        "rclone verify (hub)",
        "rclone vaultserv (hub)",
        "Backblaze master key",
    ]
    return {
        name: {
            "object": "item",
            "name": name,
            "login": {
                "username": "fixture-user-" + str(index),
                "password": "fixture-password-" + str(index),
            },
            "fields": [
                {"name": field, "value": f"fixture-{field}-{index}", "type": 1}
                for field in [
                    "hash",
                    "bcrypt",
                    "token",
                    "app_id",
                    "installation_id",
                    "private_key",
                    "restic",
                ]
            ],
        }
        for index, name in enumerate(names)
    }


def _render_context(vault, monkeypatch):
    session_file(vault)
    monkeypatch.setenv("FAKE_BW_ITEMS", json.dumps(fixture_items()))

    def lookup(plugin, term, **options):
        if plugin == "ansible.builtin.pipe":
            result = subprocess.run(
                shlex.split(term), capture_output=True, text=True, check=True
            )
            return result.stdout.rstrip("\n")
        assert plugin == "vault_secret"
        return call(term, **options)

    users = [
        {"name": "mark", "access": ["pages:ro", "tickets:ro"]},
        {"name": "laptop", "access": ["pages:wo"], "token": True},
        {"name": "gatus", "access": ["pages:wo"], "token": True},
        {"name": "alertmanager", "access": ["pages:wo"], "token": True},
    ]
    variables = {
        "lookup": lookup,
        "inventory_hostname": "alpha",
        "ansible_become": True,
        "item": {"name": "alpha"},
        "hub_ntfy_users": users,
        "hub_host_loopback": "127.0.0.1",
        "hub_prometheus_port": 9090,
        "hub_loki_port": 3100,
        "hub_alertmanager_port": 9093,
    }
    return variables


def _environment(native=False):
    kind = NativeEnvironment if native else Environment
    env = kind(
        undefined=ChainableUndefined, trim_blocks=True, keep_trailing_newline=True
    )
    env.filters["quote"] = shlex.quote
    env.filters["from_json"] = json.loads
    env.filters["items2dict"] = lambda entries, key_name, value_name: {
        entry[key_name]: entry[value_name] for entry in entries
    }
    env.filters["to_json"] = json.dumps
    env.filters["bool"] = bool
    return env


def _find_values(node, key):
    if isinstance(node, dict):
        for name, value in node.items():
            if name == key:
                yield value
            yield from _find_values(value, key)
    elif isinstance(node, list):
        for value in node:
            yield from _find_values(value, key)


def render_vault_file(path, source, variables):
    if path.endswith(".j2"):
        return _environment().from_string(source).render(variables)
    data = yaml.safe_load(source)
    env = _environment(native=True)

    def render_value(value):
        if isinstance(value, str):
            return env.from_string(value).render(variables)
        if isinstance(value, dict):
            return {key: render_value(item) for key, item in value.items()}
        if isinstance(value, list):
            return [render_value(item) for item in value]
        return value

    def has_lookup(value):
        if isinstance(value, str):
            return "bw get" in value or "vault_secret" in value
        if isinstance(value, dict):
            return any(has_lookup(item) for item in value.values())
        if isinstance(value, list):
            return any(has_lookup(item) for item in value)
        return False

    if path == "roles/hub/tasks/ntfy-verify.yml":
        fields = render_value(next(_find_values(data, "hub_ntfy_fields")))
        context = variables | {"hub_ntfy_fields": fields}
        return {
            "Authorization": env.from_string(
                next(_find_values(data, "Authorization"))
            ).render(context)
        }
    if path == "roles/hub/tasks/alertmanager-verify.yml":
        login = render_value(next(_find_values(data, "hub_alertmanager_login")))
        context = variables | {"hub_alertmanager_login": login}
        return {
            key: [
                env.from_string(value).render(context)
                for value in _find_values(data, key)
            ]
            for key in ("url_username", "url_password")
        }
    if path == "roles/hub/tasks/grafana-verify.yml":
        context = variables | {
            key: render_value(next(_find_values(data, key)))
            for key in VAULT_VALUES[path]
        }
        return {
            key: [
                env.from_string(value).render(context)
                for value in _find_values(data, key)
            ]
            for key in ("url_password", "stdin")
        }

    return {
        key: [
            render_value(value)
            for value in _find_values(data, key)
            if has_lookup(value)
        ]
        for key in VAULT_VALUES[path]
    }


@pytest.mark.parametrize("path", list(VAULT_VALUES) + VAULT_TEMPLATES)
def test_converted_file_preserves_baseline_render(path, vault, monkeypatch):
    variables = _render_context(vault, monkeypatch)
    expected = json.loads(
        (Path(__file__).parent / "expected_vault_render.json").read_text()
    )
    actual = render_vault_file(path, (ANSIBLE / path).read_text(), variables)
    assert actual == expected[path]
