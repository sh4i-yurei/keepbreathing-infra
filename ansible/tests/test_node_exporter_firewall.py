"""Tests for the node_exporter firewalld rule parser."""

from __future__ import annotations

import unittest

from ansible.errors import AnsibleFilterError
from filter_plugins.node_exporter_firewall import node_exporter_firewall_plan


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
        with self.assertRaises(AnsibleFilterError):
            node_exporter_firewall_plan([], 9100, ["not-an-address"])


if __name__ == "__main__":
    unittest.main()
