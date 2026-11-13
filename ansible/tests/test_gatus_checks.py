"""Gatus ticket inputs and the hub's deployed-readings check."""

from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from ansible.errors import AnsibleFilterError
from ansible.plugins.filter.core import FilterModule as CoreFilters
from ansible.plugins.filter.mathstuff import FilterModule as MathFilters
from ansible.plugins.test.core import TestModule as CoreTests
from jinja2 import Environment
import pytest
import yaml

from load_source import load_source


ANSIBLE = Path(__file__).resolve().parents[1]
ROLE = ANSIBLE / "roles/hub"
DOMAINS = ["tail4cf2f3.ts.net", "keepbreath.ing"]


def plugin():
    return load_source("ansible/filter_plugins/gatus_checks.py")


def rendered_config(domain="keepbreath.ing"):
    source = (ROLE / "templates/gatus-config.yaml.j2").read_text()
    template = Environment().from_string(source)
    rendered = template.render(
        hub_site_domain=domain, lookup=lambda *args, **kwargs: "fixture-token"
    )
    return rendered, yaml.safe_load(rendered)


def certificate_results(checks):
    return [
        {
            "metric": {
                "group": check["group"],
                "name": check["name"],
                "key": f"{check['group']}_{check['name']}",
                "certificate_ticket": "true",
            }
        }
        for check in checks
        if check["labels"].get("certificate_ticket") == "true"
        and any(
            check["host"] == domain or check["host"].endswith("." + domain)
            for domain in DOMAINS
        )
    ]


def success_results(config):
    return [
        {
            "metric": {
                "group": entry["group"],
                "name": entry["name"],
                "key": f"{entry['group']}_{entry['name']}",
                "type": "STARTTLS" if entry["url"].startswith("starttls:") else "HTTP",
            },
            "value": [1794342513, "1"],
        }
        for entry in config["endpoints"]
    ]


def test_summary_has_only_safe_fields_in_template_order():
    rendered, config = rendered_config()
    checks = plugin().gatus_check_summary(config)
    assert [entry["name"] for entry in checks] == [
        "ntfy",
        "grafana",
        "openbao",
        "apex",
        "www",
        "domain-expiration",
        "contact-form",
        "mail-submission",
        "password-vault",
        "last-deploy",
        "deploy-queue",
        "runner",
    ]
    assert all(set(entry) == {"name", "group", "host", "labels"} for entry in checks)
    assert checks[7]["host"] == "mail.keepbreath.ing"
    assert [
        entry["name"]
        for entry in checks
        if entry["labels"] == {"certificate_ticket": "true"}
    ] == [
        "ntfy",
        "grafana",
        "openbao",
        "apex",
        "www",
        "mail-submission",
        "password-vault",
    ]
    assert "fixture-token" not in repr(checks)


def test_summary_ignores_non_certificate_schemes():
    _, config = rendered_config()
    config["endpoints"].extend(
        [
            {"name": "ping", "group": "site", "url": "icmp://keepbreath.ing"},
            {"name": "clear", "group": "site", "url": "http://keepbreath.ing/"},
        ]
    )
    assert plugin().gatus_check_summary(config)[-1]["name"] == "runner"


@pytest.mark.parametrize("config", [{"metrics": True}, {"endpoints": {"a": 1}}, None])
def test_bad_config_has_a_precise_error(config):
    with pytest.raises(
        AnsibleFilterError, match="^Gatus's configuration has no endpoints list$"
    ):
        plugin().gatus_check_summary(config)


def test_each_domain_host_must_have_a_labelled_check():
    _, config = rendered_config()
    module = plugin()
    assert (
        module.gatus_unlabelled_hosts(module.gatus_check_summary(config), DOMAINS) == []
    )
    for name, expected in [
        ("apex", ["keepbreath.ing"]),
        ("www", ["www.keepbreath.ing"]),
    ]:
        copy = yaml.safe_load(yaml.safe_dump(config))
        next(entry for entry in copy["endpoints"] if entry["name"] == name).pop(
            "extra-labels"
        )
        assert (
            module.gatus_unlabelled_hosts(module.gatus_check_summary(copy), DOMAINS)
            == expected
        )
    for entry in config["endpoints"]:
        entry.pop("extra-labels", None)
    assert module.gatus_unlabelled_hosts(
        module.gatus_check_summary(config), DOMAINS
    ) == [
        "grafana.tail4cf2f3.ts.net",
        "keepbreath.ing",
        "mail.keepbreath.ing",
        "ntfy.tail4cf2f3.ts.net",
        "openbao.tail4cf2f3.ts.net",
        "vault.tail4cf2f3.ts.net",
        "www.keepbreath.ing",
    ]
    config["endpoints"].append(
        {"name": "external", "group": "site", "url": "https://notkeepbreath.ing/"}
    )
    assert "notkeepbreath.ing" not in module.gatus_unlabelled_hosts(
        module.gatus_check_summary(config), DOMAINS
    )


def test_certificate_reading_checks_group_name_and_label():
    _, config = rendered_config()
    module = plugin()
    checks = module.gatus_check_summary(config)
    one = [
        {
            "metric": {
                "group": "hub",
                "name": "openbao",
                "key": "hub_openbao",
                "type": "HTTP",
                "certificate_ticket": "true",
            }
        }
    ]
    missing = [
        "hub/grafana",
        "hub/ntfy",
        "mail/mail-submission",
        "site/apex",
        "site/www",
        "vault/password-vault",
    ]
    assert module.gatus_checks_without_reading(checks, DOMAINS, one) == missing
    all_readings = certificate_results(checks)
    assert module.gatus_checks_without_reading(checks, DOMAINS, all_readings) == []
    next(row for row in all_readings if row["metric"]["key"] == "site_apex")[
        "metric"
    ].pop("certificate_ticket")
    assert module.gatus_checks_without_reading(checks, DOMAINS, all_readings) == [
        "site/apex"
    ]
    config["endpoints"].append(
        {
            "name": "external",
            "group": "site",
            "url": "https://notkeepbreath.ing/",
            "extra-labels": {"certificate_ticket": "true"},
        }
    )
    assert module.gatus_checks_without_reading(
        module.gatus_check_summary(config), DOMAINS, all_readings
    ) == ["site/apex"]


def test_rule_keys_and_success_readings():
    module = plugin()
    rules = yaml.safe_load((ROLE / "files/prometheus-rules.yml").read_text())
    keys = module.gatus_rule_keys(rules)
    assert keys == [
        "github_deploy-queue",
        "github_last-deploy",
        "github_runner",
        "hub_openbao",
    ]
    assert (
        module.gatus_rule_keys(
            yaml.safe_load((ROLE / "files/node-mixin-rules.yml").read_text())
        )
        == []
    )
    _, config = rendered_config()
    readings = success_results(config)
    assert module.gatus_keys_without_reading(keys, readings) == []
    assert module.gatus_keys_without_reading(
        keys, [row for row in readings if row["metric"]["key"] != "github_runner"]
    ) == ["github_runner"]


def test_template_keeps_availability_alerts_and_uses_site_variable():
    all_vars = yaml.safe_load((ANSIBLE / "group_vars/all.yml").read_text())
    assert all_vars["site_domain"] == "keepbreath.ing"
    source = (ROLE / "templates/gatus-config.yaml.j2").read_text()
    assert "keepbreath.ing" not in source
    _, config = rendered_config()
    entries = {entry["name"]: entry for entry in config["endpoints"]}
    assert all(
        not any(
            "[CERTIFICATE_EXPIRATION]" in condition
            for condition in entry.get("conditions", [])
        )
        for entry in entries.values()
    )
    assert all(
        "alerts" not in entries[name]
        for name in ("last-deploy", "deploy-queue", "runner")
    )
    assert all(
        entries[name]["alerts"] == [{"type": "ntfy"}]
        for name in (
            "ntfy",
            "grafana",
            "apex",
            "www",
            "domain-expiration",
            "contact-form",
            "mail-submission",
            "password-vault",
        )
    )
    _, example = rendered_config("example.test")
    urls = {entry["name"]: entry["url"] for entry in example["endpoints"]}
    assert urls["apex"] == "https://example.test/"
    assert urls["mail-submission"] == "starttls://mail.example.test:587"


def tasks():
    return yaml.safe_load((ROLE / "tasks/gatus-readings-verify.yml").read_text())[0][
        "block"
    ]


def task(name):
    def walk(entries):
        for entry in entries:
            yield entry
            yield from walk(entry.get("block", []))
            yield from walk(entry.get("rescue", []))

    return next(
        entry
        for entry in walk(tasks())
        if entry["name"] == "gatus-readings-verify | " + name
    )


def ansible_environment():
    env = Environment()
    env.filters.update(CoreFilters().filters())
    env.filters.update(MathFilters().filters())
    env.filters.update(plugin().FilterModule().filters())
    env.tests.update(CoreTests().tests())
    return env


def evaluate(expression, **variables):
    if expression.startswith("{{") and expression.endswith("}}"):
        expression = expression[2:-2]
    return (
        ansible_environment()
        .from_string("{{ " + expression + " }}")
        .render(**variables)
    )


def test_secret_config_is_hidden_and_summary_expression_runs():
    verify = tasks()
    slurp = task("Read the deployed Gatus configuration")
    summary = task("Summarize the deployed checks")
    assert slurp["no_log"] is True and summary["no_log"] is True
    registered = slurp["register"]
    assert all(
        registered not in repr(entry)
        for entry in verify
        if entry["name"] not in {summary["name"], slurp["name"]}
    )
    rendered, config = rendered_config()
    variables = {registered: {"content": base64.b64encode(rendered.encode()).decode()}}
    expression = summary["ansible.builtin.set_fact"]["hub_gatus_checks"]
    result = yaml.safe_load(evaluate(expression, **variables))
    assert result == plugin().gatus_check_summary(config)
    assertion = task("Require a labelled check for every domain host")[
        "ansible.builtin.assert"
    ]["that"][0]
    assert (
        evaluate(
            assertion,
            hub_gatus_checks=result,
            hub_tailnet_domain=DOMAINS[0],
            hub_site_domain=DOMAINS[1],
        )
        == "True"
    )
    next(entry for entry in result if entry["name"] == "apex")["labels"] = {}
    assert (
        evaluate(
            assertion,
            hub_gatus_checks=result,
            hub_tailnet_domain=DOMAINS[0],
            hub_site_domain=DOMAINS[1],
        )
        == "False"
    )


def test_wait_expressions_and_rescue_messages():
    rendered, config = rendered_config()
    checks = plugin().gatus_check_summary(config)
    rules = (ROLE / "files/prometheus-rules.yml").read_text()
    base = {
        "hub_gatus_checks": checks,
        "hub_tailnet_domain": DOMAINS[0],
        "hub_site_domain": DOMAINS[1],
        "hub_gatus_rules": {"content": base64.b64encode(rules.encode()).decode()},
    }
    for name, good, bad in [
        (
            "Query certificate readings",
            certificate_results(checks),
            certificate_results(checks)[2:3],
        ),
        (
            "Query rule key readings",
            success_results(config),
            [
                r
                for r in success_results(config)
                if r["metric"]["key"] != "github_runner"
            ],
        ),
    ]:
        wait = task(name)
        variable = wait["register"]
        expression = wait["until"]
        assert (
            evaluate(
                expression,
                **base,
                **{variable: {"json": {"status": "success", "data": {"result": good}}}},
            )
            == "True"
        )
        assert (
            evaluate(
                expression,
                **base,
                **{variable: {"json": {"status": "success", "data": {"result": bad}}}},
            )
            == "False"
        )
        assert (
            evaluate(
                expression,
                **base,
                **{variable: {"json": {"status": "error", "data": {"result": good}}}},
            )
            == "False"
        )

    one = [
        {"metric": {"group": "hub", "name": "openbao", "certificate_ticket": "true"}}
    ]
    certificate_message = task("Report missing certificate readings")[
        "ansible.builtin.fail"
    ]["msg"]
    assert ansible_environment().from_string(certificate_message).render(
        **base, hub_gatus_cert_query={"json": {"data": {"result": one}}}
    ) == (
        "Gatus's labelled checks have no certificate reading with certificate_ticket in "
        "Prometheus: ['hub/grafana', 'hub/ntfy', 'mail/mail-submission', 'site/apex', "
        "'site/www', 'vault/password-vault']."
    )
    key_message = task("Report missing rule key readings")["ansible.builtin.fail"][
        "msg"
    ]
    readings = [
        row
        for row in success_results(config)
        if row["metric"]["key"] != "github_runner"
    ]
    assert ansible_environment().from_string(key_message).render(
        **base, hub_gatus_key_query={"json": {"data": {"result": readings}}}
    ) == (
        "These gatus_key annotations in Prometheus's rules have no Gatus reading: "
        "['github_runner']."
    )


def run_play(tmp_path, *, check=False, missing_label=False):
    rendered, config = rendered_config()
    if missing_label:
        next(entry for entry in config["endpoints"] if entry["name"] == "apex").pop(
            "extra-labels"
        )
        rendered = yaml.safe_dump(config)
    home = tmp_path / "home"
    (home / ".config/gatus").mkdir(parents=True)
    (home / ".config/prometheus").mkdir(parents=True)
    (home / ".config/gatus/config.yaml").write_text(rendered)
    (home / ".config/prometheus/rules.yml").write_text(
        (ROLE / "files/prometheus-rules.yml").read_text()
    )
    playbook = tmp_path / "play.yml"
    playbook.write_text(
        "---\n- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n    - ansible.builtin.import_role:\n        name: hub\n        tasks_from: gatus-readings-verify\n"
    )

    class Prometheus(BaseHTTPRequestHandler):
        def do_GET(self):
            query = parse_qs(urlsplit(self.path).query).get("query", [""])[0]
            rows = (
                certificate_results(plugin().gatus_check_summary(config))
                if "certificate_expiration" in query
                else success_results(config)
            )
            body = json.dumps(
                {"status": "success", "data": {"resultType": "vector", "result": rows}}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    with ThreadingHTTPServer(("127.0.0.1", 0), Prometheus) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        env = {key: os.environ[key] for key in ("PATH", "HOME")}
        env.update(ANSIBLE_CONFIG=str(ANSIBLE / "ansible.cfg"), ANSIBLE_NOCOLOR="1")
        user = "gatus-readings-absent" if check else "../" + str(home).lstrip("/")
        command = [
            "ansible-playbook",
            str(playbook),
            "-i",
            "localhost,",
            "-e",
            "ansible_become=false",
            "-e",
            f"hub_container_user={user}",
            "-e",
            f"hub_prometheus_port={server.server_port}",
            "-e",
            f"tailnet_domain={DOMAINS[0]}",
            "-e",
            f"site_domain={DOMAINS[1]}",
        ]
        if check:
            command.append("--check")
        result = subprocess.run(
            command, cwd=ANSIBLE, env=env, text=True, capture_output=True, timeout=40
        )
        server.shutdown()
        worker.join()
    return result


def test_check_mode_skips_all_tasks(tmp_path):
    result = run_play(tmp_path, check=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.search(
        r"localhost\s+: ok=0\s+changed=0\s+unreachable=0\s+failed=0", result.stdout
    )


def test_live_task_with_local_prometheus(tmp_path):
    result = run_play(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.search(
        r"localhost\s+: ok=6\s+changed=0\s+unreachable=0\s+failed=0", result.stdout
    )
    assert "fixture-token" not in result.stdout + result.stderr


def test_live_task_rejects_unlabelled_host_without_printing_tokens(tmp_path):
    result = run_play(tmp_path, missing_label=True)
    assert result.returncode == 2, result.stdout + result.stderr
    assert (
        "Every host under tail4cf2f3.ts.net and keepbreath.ing that a Gatus check reaches over"
        ' HTTPS or STARTTLS needs a check labelled certificate_ticket: \\"true\\".'
        " Hosts without one: ['keepbreath.ing']."
    ) in result.stdout
    assert "fixture-token" not in result.stdout + result.stderr
