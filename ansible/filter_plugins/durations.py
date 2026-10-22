"""Parse the duration grammar shared by Prometheus and Loki."""

from __future__ import annotations

from ansible.errors import AnsibleFilterError


# Prometheus model.ParseDuration defines this order and a 365-day year:
# https://github.com/prometheus/common/blob/main/model/time.go
_NANOSECONDS_PER_UNIT = {
    "y": 365 * 24 * 60 * 60 * 1_000_000_000,
    "w": 7 * 24 * 60 * 60 * 1_000_000_000,
    "d": 24 * 60 * 60 * 1_000_000_000,
    "h": 60 * 60 * 1_000_000_000,
    "m": 60 * 1_000_000_000,
    "s": 1_000_000_000,
    "ms": 1_000_000,
}
_UNIT_POSITION = {unit: position for position, unit in enumerate(_NANOSECONDS_PER_UNIT)}
_MAX_DURATION_NANOSECONDS = (1 << 63) - 1


def prometheus_duration_seconds(value: object) -> int | float:
    """Return seconds for a complete Prometheus duration string."""
    if value == "0":
        return 0
    if not isinstance(value, str) or not value:
        raise AnsibleFilterError(f"invalid Prometheus duration {value!r}")

    position = 0
    last_unit_position = -1
    total_nanoseconds = 0
    while position < len(value):
        number_start = position
        while position < len(value) and "0" <= value[position] <= "9":
            position += 1
        if position == number_start:
            raise AnsibleFilterError(f"invalid Prometheus duration {value!r}")

        unit_start = position
        while position < len(value) and not "0" <= value[position] <= "9":
            position += 1
        unit = value[unit_start:position]
        if unit not in _NANOSECONDS_PER_UNIT:
            raise AnsibleFilterError(
                f"invalid unit {unit!r} in Prometheus duration {value!r}"
            )
        unit_position = _UNIT_POSITION[unit]
        if unit_position <= last_unit_position:
            raise AnsibleFilterError(
                f"units out of order in Prometheus duration {value!r}"
            )
        last_unit_position = unit_position

        try:
            number = int(value[number_start:unit_start])
        except ValueError as error:
            raise AnsibleFilterError(
                f"invalid Prometheus duration {value!r}"
            ) from error
        total_nanoseconds += number * _NANOSECONDS_PER_UNIT[unit]
        if total_nanoseconds > _MAX_DURATION_NANOSECONDS:
            raise AnsibleFilterError(f"Prometheus duration out of range: {value!r}")

    seconds, remainder = divmod(total_nanoseconds, 1_000_000_000)
    return seconds if remainder == 0 else total_nanoseconds / 1_000_000_000


class FilterModule:
    """Expose the duration parser to Ansible."""

    def filters(self) -> dict[str, object]:
        return {"prometheus_duration_seconds": prometheus_duration_seconds}
