"""Keep the gap counter's writers and readers on the same safe path."""

import json
from pathlib import Path

from jinja2 import Environment, Template
import yaml


ROLE = Path(__file__).parents[1] / "roles/hub"
SETUP = yaml.safe_load((ROLE / "tasks/journals-setup.yml").read_text())


def task(name: str) -> dict:
    return next(item for item in SETUP if item["name"] == name)


def test_gap_counter_paths_align_across_setup_puller_and_collector() -> None:
    expected = "/var/lib/journal_pull/mail/gaps.prom"
    item = {"name": "mail", "address": "127.0.0.1"}
    config = json.loads(
        Template((ROLE / "templates/journal-pull-host.json.j2").read_text()).render(
            item=item
        )
    )
    unit = (ROLE / "templates/journal-pull@.service.j2").read_text()
    link = task("journals-setup | Link each gap counter into node exporter's collector")
    initialize = task("journals-setup | Initialize each persistent gap counter once")

    assert "owner" not in link["ansible.builtin.file"]
    assert "group" not in link["ansible.builtin.file"]
    assert config["gap_metric_file"] == expected
    assert "ReadWritePaths=/var/lib/journal_pull/%i" in unit
    assert (
        Template(link["ansible.builtin.file"]["src"]).render(item={"item": item})
        == expected
    )
    assert (
        Template(initialize["ansible.builtin.copy"]["dest"]).render(item=item)
        == expected
    )


def test_gap_counter_directories_allow_puller_and_exporter_access() -> None:
    parent = task("journals-setup | Make the gap counter parent directory")
    host = task("journals-setup | Make each puller's private gap counter directory")
    parent_args = parent["ansible.builtin.file"]
    host_args = host["ansible.builtin.file"]

    assert parent_args["path"] == "/var/lib/journal_pull"
    assert parent_args["mode"] == "0755"
    assert host_args["owner"] == "systemd-journal-remote"
    assert host_args["group"] == "node_exporter"
    assert host_args["mode"] == "2750"


def test_gap_counter_migration_preserves_existing_values() -> None:
    pause = task("journals-setup | Pause pullers whose counters need migration")
    migration = task(
        "journals-setup | Preserve existing gap counts in the new location"
    )
    copy = migration["ansible.builtin.copy"]
    assert SETUP.index(pause) < SETUP.index(migration)
    assert pause["ansible.builtin.systemd_service"]["state"] == "stopped"
    assert copy["remote_src"] is True
    assert copy["force"] is False
    assert copy["dest"].startswith("/var/lib/journal_pull/")


def test_symlink_tasks_cannot_change_target_ownership() -> None:
    for item in SETUP:
        file_args = item.get("ansible.builtin.file", {})
        if file_args.get("state") == "link":
            assert (
                file_args.get("follow") is False
                or not {"owner", "group"} & file_args.keys()
            )


def test_journal_verify_checks_counter_access_as_the_puller() -> None:
    checks = yaml.safe_load((ROLE / "tasks/journals-verify.yml").read_text())[0][
        "block"
    ]
    check = next(item for item in checks if item["name"].endswith("read its counter"))
    assert check["become_user"] == "systemd-journal-remote"
    script = check["ansible.builtin.command"]["argv"][2]
    assert "NamedTemporaryFile(dir=folder" in script
    assert '(folder / "gaps.prom").read_text' in script


def test_prometheus_verify_requires_every_source_host() -> None:
    checks = yaml.safe_load((ROLE / "tasks/prometheus-verify.yml").read_text())[0][
        "block"
    ]
    check = next(
        item
        for item in checks
        if item["name"].endswith("journal gap counters in Prometheus")
    )
    expression = Environment().compile_expression(check["until"])
    sources = [
        {"name": name} for name in ("web", "mail", "control", "vaultserv", "almaserv")
    ]

    def visible(hosts: tuple[str, ...]) -> bool:
        return expression(
            hub_journal_sources=sources,
            hub_prometheus_journal_gap_metrics={
                "json": {
                    "status": "success",
                    "data": {"result": [{"metric": {"host": host}} for host in hosts]},
                }
            },
        )

    assert visible(("almaserv", "control", "mail", "vaultserv", "web"))
    assert not visible(("control", "mail", "vaultserv", "web"))
    assert not visible(("almaserv", "control", "mail", "vaultserv", "web", "extra"))
