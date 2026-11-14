"""The hub gives Grafana an OpenBao consumer for its cloud data sources."""

from pathlib import Path

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]


def test_grafana_has_its_own_approle():
    hub = yaml.safe_load((ANSIBLE / "host_vars/hub.yml").read_text())
    assert [
        entry for entry in hub["openbao_approles"] if entry["name"] == "grafana"
    ] == [{"name": "grafana", "account": "{{ hub_container_user }}"}]


def test_grafana_uses_its_own_consumer_by_default():
    defaults = yaml.safe_load((ANSIBLE / "roles/hub/defaults/main.yml").read_text())
    assert defaults.get("hub_grafana_keys_consumer") == "grafana"
