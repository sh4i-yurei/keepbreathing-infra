"""Filters for reconciling node_exporter's firewalld rich rules."""

from __future__ import annotations

import ipaddress
import shlex

from ansible.errors import AnsibleFilterError


_ELEMENTS = frozenset(
    {
        "source",
        "destination",
        "service",
        "port",
        "protocol",
        "icmp-block",
        "icmp-type",
        "masquerade",
        "forward-port",
        "source-port",
        "log",
        "nflog",
        "audit",
        "accept",
        "reject",
        "drop",
        "mark",
        "limit",
    }
)


def _attributes_after(tokens: list[str], element: str) -> dict[str, str]:
    """Return key/value attributes belonging to one rich-rule element."""
    try:
        position = tokens.index(element) + 1
    except ValueError:
        return {}

    attributes: dict[str, str] = {}
    while position < len(tokens) and tokens[position] not in _ELEMENTS:
        key, separator, value = tokens[position].partition("=")
        if separator:
            attributes[key] = value
        position += 1
    return attributes


def _network(value: object) -> str:
    try:
        return str(ipaddress.ip_network(str(value), strict=False))
    except ValueError as error:
        raise AnsibleFilterError(
            f"invalid node_exporter firewall source {value!r}: {error}"
        ) from error


def _managed_source(rule: object, port: object) -> str | None:
    """Return the normalized source when a rule has the shape this role owns."""
    try:
        tokens = shlex.split(str(rule), posix=True)
    except ValueError as error:
        raise AnsibleFilterError(
            f"cannot parse firewalld rich rule {rule!r}: {error}"
        ) from error

    if not tokens or tokens[0] != "rule" or "accept" not in tokens:
        return None

    top_level = {
        key: value
        for token in tokens[1:]
        if "=" in token
        for key, value in [token.split("=", 1)]
    }
    source = _attributes_after(tokens, "source")
    destination_port = _attributes_after(tokens, "port")
    if (
        top_level.get("family") != "ipv4"
        or "address" not in source
        or destination_port.get("port") != str(port)
        or destination_port.get("protocol") != "tcp"
    ):
        return None
    return _network(source["address"])


def node_exporter_firewall_plan(
    rules: list[object] | tuple[object, ...] | None,
    port: object,
    allowed_sources: list[object] | tuple[object, ...] | None,
) -> dict[str, list[str]]:
    """Describe the node_exporter rich rules present and those that are stale."""
    allowed = sorted({_network(source) for source in (allowed_sources or [])})
    allowed_set = set(allowed)
    managed_sources: set[str] = set()
    stale_rules: list[str] = []

    for rule in rules or []:
        source = _managed_source(rule, port)
        if source is None:
            continue
        managed_sources.add(source)
        if source not in allowed_set:
            stale_rules.append(str(rule))

    return {
        "allowed_sources": allowed,
        "managed_sources": sorted(managed_sources),
        "stale_rules": stale_rules,
    }


class FilterModule:
    """Expose node_exporter's firewall reconciliation filter to Ansible."""

    def filters(self) -> dict[str, object]:
        return {"node_exporter_firewall_plan": node_exporter_firewall_plan}
