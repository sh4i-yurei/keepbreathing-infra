"""Prometheus and Loki duration parsing tests."""

from __future__ import annotations

import pytest
from ansible.errors import AnsibleFilterError

from filter_plugins.durations import FilterModule, prometheus_duration_seconds


@pytest.mark.parametrize(
    ("value", "seconds"),
    [
        ("90d", 7_776_000),
        ("2160h", 7_776_000),
        ("12w6d", 7_776_000),
        ("1d", 86_400),
        ("24h", 86_400),
        ("1h30m", 5_400),
        ("500ms", 0.5),
        ("0", 0),
        ("1y", 31_536_000),
        ("1y2w3d4h5m6s7ms", 33_019_506.007),
    ],
)
def test_valid_durations(value: str, seconds: int | float) -> None:
    assert prometheus_duration_seconds(value) == seconds


@pytest.mark.parametrize(
    "value",
    [
        "",
        "90",
        "00",
        "1x",
        "1m1d",
        "1h2h",
        "1ms1s",
        "1.5h",
        "-1h",
        "1h ",
        " 1h",
        "1h30",
        "293y",
        0,
    ],
)
def test_invalid_durations_raise_ansible_filter_error(value: object) -> None:
    with pytest.raises(AnsibleFilterError):
        prometheus_duration_seconds(value)


def test_ansible_exposes_the_duration_filter() -> None:
    assert FilterModule().filters()["prometheus_duration_seconds"]("24h") == 86_400
