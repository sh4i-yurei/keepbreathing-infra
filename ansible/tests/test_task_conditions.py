"""Catch conditions YAML turns into mappings before a verify task runs on a real machine.

An unquoted condition containing ": " loads as a mapping. ansible-core refuses
conditions that are not strings only when the affected task runs.
"""

from pathlib import Path

import pytest
import yaml


ANSIBLE = Path(__file__).resolve().parents[1]
FILES = sorted(ANSIBLE.rglob("*.yml"))
CONDITION_KEYS = {"when", "failed_when", "changed_when", "until", "that"}


def offending_conditions(value, where="document"):
    offenses = []
    if isinstance(value, dict):
        for key, child in value.items():
            location = f"{where}.{key}"
            if key in CONDITION_KEYS:
                entries = child if isinstance(child, list) else [child]
                for index, entry in enumerate(entries):
                    entry_location = (
                        f"{location}[{index}]" if isinstance(child, list) else location
                    )
                    if not isinstance(entry, (str, bool)):
                        offenses.append((entry_location, entry))
            offenses.extend(offending_conditions(child, location))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            offenses.extend(offending_conditions(child, f"{where}[{index}]"))
    return offenses


def test_conditions_scan_covers_ansible_yaml_files():
    assert len(FILES) > 200


@pytest.mark.parametrize("path", FILES, ids=lambda path: str(path.relative_to(ANSIBLE)))
def test_every_task_condition_is_a_string_or_boolean(path):
    offenses = []
    with path.open() as source:
        for index, document in enumerate(yaml.safe_load_all(source)):
            offenses.extend(offending_conditions(document, f"document[{index}]"))
    assert offenses == []
