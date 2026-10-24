"""Prometheus and Loki duration parsing tests."""

from __future__ import annotations

import pytest
from ansible.errors import AnsibleFilterError

from load_source import load_source

durations = load_source("ansible/filter_plugins/durations.py")
FilterModule = durations.FilterModule
prometheus_duration_seconds = durations.prometheus_duration_seconds


@pytest.mark.parametrize(
    ("value", "seconds"),
    [
        ("90d", 7_776_000),
        ("2160h", 7_776_000),
        ("12w6d", 7_776_000),
        ("1d", 86_400),
        ("24h", 86_400),
        ("1h30m", 5_400),
        ("1h05m", 3_900),
        ("1h9m", 4_140),
        ("500ms", 0.5),
        ("0", 0),
        ("1y", 31_536_000),
        ("1y2w3d4h5m6s7ms", 33_019_506.007),
    ],
)
def test_valid_durations(value: str, seconds: int | float) -> None:
    assert prometheus_duration_seconds(value) == seconds


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("", "invalid Prometheus duration ''"),
        ("90", "invalid unit '' in Prometheus duration '90'"),
        ("00", "invalid unit '' in Prometheus duration '00'"),
        ("1x", "invalid unit 'x' in Prometheus duration '1x'"),
        ("1H", "invalid unit 'H' in Prometheus duration '1H'"),
        ("1m1d", "units out of order in Prometheus duration '1m1d'"),
        ("1h2h", "units out of order in Prometheus duration '1h2h'"),
        ("1ms1s", "units out of order in Prometheus duration '1ms1s'"),
        ("1.5h", "invalid unit '.' in Prometheus duration '1.5h'"),
        ("-1h", "invalid Prometheus duration '-1h'"),
        ("1h ", "invalid unit 'h ' in Prometheus duration '1h '"),
        (" 1h", "invalid Prometheus duration ' 1h'"),
        ("1h30", "invalid unit '' in Prometheus duration '1h30'"),
        ("293y", "Prometheus duration out of range: '293y'"),
        (0, "invalid Prometheus duration 0"),
    ],
)
def test_invalid_durations_raise_ansible_filter_error(
    value: object, message: str
) -> None:
    with pytest.raises(AnsibleFilterError) as raised:
        prometheus_duration_seconds(value)
    assert str(raised.value) == message


def test_excessive_integer_digits_are_rejected() -> None:
    value = "9" * 4301 + "s"
    with pytest.raises(AnsibleFilterError) as raised:
        prometheus_duration_seconds(value)
    assert str(raised.value) == (
        f"invalid Prometheus duration {value!r}: Exceeds the limit (4300 digits) "
        "for integer string conversion: value has 4301 digits; use "
        "sys.set_int_max_str_digits() to increase the limit"
    )


def test_ansible_exposes_the_duration_filter() -> None:
    assert FilterModule().filters()["prometheus_duration_seconds"]("24h") == 86_400


def test_whole_seconds_keep_integer_type() -> None:
    assert type(prometheus_duration_seconds("1s")) is int
    assert type(prometheus_duration_seconds("500ms")) is float
