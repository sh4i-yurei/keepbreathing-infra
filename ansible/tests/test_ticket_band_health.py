"""The ticket band's own health reaches ntfy without the band (OpenBao on the hub 4.4 and 4.5).

Item 4.4's Alertmanager route for failed sends to the ticket receiver, the hub role's copy of the
band's port, Prometheus's scrape job for the receiver, and the two verify conditions decision 77
sets; item 4.5's route for the morning digest's failed unit (decision 79); and item 4.6's warning
route to the ticket receiver. amtool can't test a route's grouping or repeat interval, and the
verify conditions only run on the hub, so these read the files and evaluate them the way Ansible
does.
"""

from pathlib import Path
from typing import Any

from ansible.plugins.filter.core import FilterModule as CoreFilters
from ansible.plugins.filter.mathstuff import FilterModule as MathFilters
from ansible.plugins.test.core import TestModule as CoreTests
from jinja2 import Environment
import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
ROLE = ANSIBLE / "roles/hub"
LOCAL_POOLS = (
    "alertmanager",
    "gatus",
    "grafana",
    "node",
    "ntfy",
    "podman",
    "prometheus",
)
METRICS_TASK = (
    "alertmanager-verify | Every delivery counter carries its receiver's name"
)
SCRAPE_TASK = "prometheus-verify | Wait for every scrape target to be up"
OB44_AM_LINES = (
    'alertmanager_notifications_total{integration="webhook",receiver_name="ntfy-pages"} 0\n'
    'alertmanager_notifications_total{integration="webhook",receiver_name="ntfy-tickets"} 0\n'
)


def read(path: Path) -> Any:
    return yaml.safe_load(path.read_text())


def ansible_environment() -> Environment:
    environment = Environment()
    environment.filters.update(CoreFilters().filters())
    environment.filters.update(MathFilters().filters())
    environment.tests.update(CoreTests().tests())
    return environment


def verify_task(file_name: str, name: str) -> dict:
    block = read(ROLE / "tasks" / file_name)[0]["block"]
    matches = [task for task in block if task["name"] == name]
    assert len(matches) == 1, f"{file_name} must hold exactly one task named {name!r}"
    return matches[0]


def hub_ticket_receiver_port() -> int:
    host_vars = read(ANSIBLE / "host_vars/hub.yml")
    assert "hub_ticket_receiver_port" in host_vars
    return int(
        Environment()
        .from_string(host_vars["hub_ticket_receiver_port"])
        .render(host_vars)
    )


def test_failed_sends_to_the_ticket_receiver_route_to_tickets_before_the_severity_routes():
    routes = read(ROLE / "templates/alertmanager.yml.j2")["route"]["routes"]
    positions = [
        index
        for index, route in enumerate(routes)
        if route.get("matchers") == ['receiver_name="ticket"']
    ]
    assert len(positions) == 1, (
        'exactly one route must match only receiver_name="ticket"'
    )
    position = positions[0]
    band_health = next(
        index
        for index, route in enumerate(routes)
        if route.get("matchers") == ['band_health="true"']
    )
    first_severity = next(
        index
        for index, route in enumerate(routes)
        if any(matcher.startswith("severity") for matcher in route.get("matchers", []))
    )

    assert routes[position] == {
        "matchers": ['receiver_name="ticket"'],
        "receiver": "ntfy-tickets",
        "group_by": ["..."],
    }
    assert band_health < position < first_severity


def test_the_hub_role_copy_of_the_receiver_port_equals_the_band_port():
    host_vars = read(ANSIBLE / "host_vars/hub.yml")
    assert hub_ticket_receiver_port() == host_vars["ticket_band_receiver_port"]


def test_prometheus_scrapes_the_receiver_through_nginx_without_a_password():
    defaults = read(ROLE / "defaults/main.yml")
    port = hub_ticket_receiver_port()
    rendered = (
        ansible_environment()
        .from_string((ROLE / "templates/prometheus.yml.j2").read_text())
        .render(
            defaults
            | {
                "hub_ticket_receiver_port": port,
                "groups": {"droplets": []},
                "hostvars": {},
                "hub_podman_exporter_droplet_hosts": [],
                "hub_podman_exporter_tailnet_hosts": [],
                "hub_node_exporter_tailnet_hosts": [],
            }
        )
    )
    jobs = [
        job
        for job in yaml.safe_load(rendered)["scrape_configs"]
        if job["job_name"] == "ticket-receiver"
    ]

    assert jobs == [
        {
            "job_name": "ticket-receiver",
            "static_configs": [
                {"targets": [f"{defaults['hub_host_loopback']}:{port}"]}
            ],
        }
    ]
    assert jobs[0]["static_configs"][0]["targets"] == ["169.254.1.3:8083"]


def test_prometheus_verify_lists_the_receiver_pool_but_ignores_its_health():
    expression = ansible_environment().compile_expression(
        verify_task("prometheus-verify.yml", SCRAPE_TASK)["until"]
    )

    def passes(targets: dict[str, str]) -> bool:
        return bool(
            expression(
                hub_prometheus_targets={
                    "json": {
                        "data": {
                            "activeTargets": [
                                {"scrapePool": pool, "health": health}
                                for pool, health in targets.items()
                            ]
                        }
                    }
                },
                groups={"droplets": []},
                hub_node_exporter_tailnet_hosts=[],
                hub_podman_exporter_hosts=[],
            )
        )

    local_up = {pool: "up" for pool in LOCAL_POOLS}
    assert passes(local_up | {"ticket-receiver": "down"})
    assert passes(local_up | {"ticket-receiver": "up"})
    assert not passes(local_up)
    assert not passes(local_up | {"gatus": "down", "ticket-receiver": "up"})


def test_alertmanager_verify_requires_receiver_names_on_the_delivery_counters():
    expression = ansible_environment().compile_expression(
        verify_task("alertmanager-verify.yml", METRICS_TASK)["failed_when"]
    )

    def fails(status: int, content: str) -> bool:
        return bool(
            expression(hub_alertmanager_metrics={"status": status, "content": content})
        )

    assert not fails(200, OB44_AM_LINES)
    assert fails(200, 'alertmanager_notifications_total{integration="webhook"} 0\n')
    assert fails(401, OB44_AM_LINES)


def test_the_digest_failed_unit_routes_to_tickets_after_the_ticket_route():
    routes = read(ROLE / "templates/alertmanager.yml.j2")["route"]["routes"]
    positions = [
        index
        for index, route in enumerate(routes)
        if route.get("matchers") == ['name="ticket-digest.service"']
    ]
    assert len(positions) == 1, (
        'exactly one route must match only name="ticket-digest.service"'
    )
    position = positions[0]

    def where(matchers: list[str]) -> int:
        return next(
            index for index, route in enumerate(routes) if route.get("matchers") == matchers
        )

    first_severity = next(
        index
        for index, route in enumerate(routes)
        if any(matcher.startswith("severity") for matcher in route.get("matchers", []))
    )

    assert routes[position] == {
        "matchers": ['name="ticket-digest.service"'],
        "receiver": "ntfy-tickets",
        "group_by": ["..."],
    }
    assert (
        where(['band_health="true"'])
        < where(['receiver_name="ticket"'])
        < position
        < first_severity
    )


def test_warning_route_sends_one_ticket_per_alert_with_a_daily_repeat():
    routes = read(ROLE / "templates/alertmanager.yml.j2")["route"]["routes"]
    warnings = [
        route for route in routes if route.get("matchers") == ['severity="warning"']
    ]
    assert warnings == [
        {
            "matchers": ['severity="warning"'],
            "receiver": "ticket",
            "group_by": ["..."],
            "repeat_interval": "1d",
        }
    ]
    assert routes[-1] == warnings[0]
    assert [route["matchers"] for route in routes[:3]] == [
        ['band_health="true"'],
        ['receiver_name="ticket"'],
        ['name="ticket-digest.service"'],
    ]
    assert [route for route in routes if route.get("receiver") == "ticket"] == warnings
