"""Tests for the node_exporter firewalld rule parser."""

from __future__ import annotations

import unittest

from ansible.errors import AnsibleFilterError
from load_source import load_source

firewall = load_source("ansible/filter_plugins/node_exporter_firewall.py")
node_exporter_firewall_plan = firewall.node_exporter_firewall_plan


class NodeExporterFirewallPlanTests(unittest.TestCase):
    def test_current_source_is_kept_and_stale_source_is_returned(self) -> None:
        current = 'rule family="ipv4" source address="100.95.89.6" port port="9100" protocol="tcp" accept'
        stale = 'rule family="ipv4" source address="192.0.2.40" port port="9100" protocol="tcp" accept'

        plan = node_exporter_firewall_plan([current, stale], "9100", ["100.95.89.6"])

        self.assertEqual(plan["allowed_sources"], ["100.95.89.6/32"])
        self.assertEqual(plan["managed_sources"], ["100.95.89.6/32", "192.0.2.40/32"])
        self.assertEqual(plan["stale_rules"], [stale])

    def test_equivalent_network_spelling_is_not_stale(self) -> None:
        rule = "rule family=ipv4 source address=192.0.2.1/32 port port=9100 protocol=tcp accept"

        plan = node_exporter_firewall_plan([rule], 9100, ["192.0.2.1"])

        self.assertEqual(plan["stale_rules"], [])

    def test_unrelated_rules_are_ignored(self) -> None:
        rules = [
            'rule family="ipv4" source address="192.0.2.1" port port="22" protocol="tcp" accept',
            'rule family="ipv4" source address="192.0.2.1" port port="9100" protocol="udp" accept',
            'rule family="ipv6" source address="2001:db8::1" port port="9100" protocol="tcp" accept',
            'rule family="ipv4" source address="192.0.2.1" port port="9100" protocol="tcp" drop',
        ]

        plan = node_exporter_firewall_plan(rules, 9100, [])

        self.assertEqual(plan["managed_sources"], [])
        self.assertEqual(plan["stale_rules"], [])

    def test_invalid_allowed_source_fails_closed(self) -> None:
        with self.assertRaises(AnsibleFilterError) as raised:
            node_exporter_firewall_plan([], 9100, ["not-an-address"])
        self.assertEqual(
            str(raised.exception),
            "invalid node_exporter firewall source 'not-an-address': 'not-an-address' does not appear to be an IPv4 or IPv6 network",
        )

    def test_malformed_rule_fails_closed(self) -> None:
        with self.assertRaises(AnsibleFilterError) as raised:
            node_exporter_firewall_plan(['rule "'], 9100, [])
        self.assertEqual(
            str(raised.exception),
            "cannot parse firewalld rich rule 'rule \"': No closing quotation",
        )

    def test_missing_source_and_unvalued_attribute_are_ignored(self) -> None:
        rules = [
            "rule family=ipv4 port port=9100 protocol=tcp accept",
            "rule family=ipv4 source nonsense address=192.0.2.1 port port=9100 protocol=tcp accept",
        ]
        self.assertEqual(
            node_exporter_firewall_plan(rules, 9100, []),
            {
                "allowed_sources": [],
                "managed_sources": ["192.0.2.1/32"],
                "stale_rules": [rules[1]],
            },
        )

    def test_filter_is_exposed(self) -> None:
        self.assertEqual(
            firewall.FilterModule().filters()["node_exporter_firewall_plan"](
                [], 9100, []
            ),
            {"allowed_sources": [], "managed_sources": [], "stale_rules": []},
        )

    def test_network_prefix_is_normalized_and_empty_rule_is_ignored(self) -> None:
        self.assertEqual(
            node_exporter_firewall_plan([""], 9100, ["192.0.2.1/24"]),
            {
                "allowed_sources": ["192.0.2.0/24"],
                "managed_sources": [],
                "stale_rules": [],
            },
        )

    def test_malformed_top_level_attribute_is_ignored(self) -> None:
        rule = "rule family=ipv4=extra source address=192.0.2.1 port port=9100 protocol=tcp accept"
        self.assertEqual(
            node_exporter_firewall_plan([rule], 9100, []),
            {"allowed_sources": [], "managed_sources": [], "stale_rules": []},
        )

    def test_rule_ending_with_source_element_is_ignored(self) -> None:
        rule = "rule family=ipv4 port port=9100 protocol=tcp accept source"
        self.assertEqual(
            node_exporter_firewall_plan([rule], 9100, []),
            {"allowed_sources": [], "managed_sources": [], "stale_rules": []},
        )


if __name__ == "__main__":
    unittest.main()
