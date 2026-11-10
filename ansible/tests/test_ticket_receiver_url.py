"""The ticket receiver's URL in Alertmanager's config (OpenBao on the hub decision 76).

CI's hub-rules job checks alertmanager.yml.j2 unrendered with amtool, which rejects an Ansible
variable in a URL, so the template writes the URL out. The loopback address and the band's port
each live in two places, and this test keeps the literal equal to the variables.
"""

from pathlib import Path

import yaml


ANSIBLE = Path(__file__).resolve().parents[1]


def read(path):
    return yaml.safe_load((ANSIBLE / path).read_text())


def ticket_receiver_urls():
    config = read("roles/hub/templates/alertmanager.yml.j2")
    return [
        webhook["url"]
        for receiver in config["receivers"]
        if receiver["name"] == "ticket"
        for webhook in receiver.get("webhook_configs", [])
    ]


def test_the_ticket_receiver_url_is_built_from_the_loopback_address_and_the_band_port():
    loopback = read("roles/hub/defaults/main.yml")["hub_host_loopback"]
    port = read("host_vars/hub.yml").get("ticket_band_receiver_port")
    assert ticket_receiver_urls() == [f"http://{loopback}:{port}/v1/webhook"]
