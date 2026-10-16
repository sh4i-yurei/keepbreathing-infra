#!/usr/bin/python3
"""Report parsed sudo policy entries that disable password authentication."""

import json
import sys
from typing import Any


def section(document: dict[str, Any], name: str) -> list[dict[str, Any]]:
    """Return one cvtsudoers section, rejecting malformed input."""
    entries = document.get(name, [])
    if not isinstance(entries, list) or not all(
        isinstance(entry, dict) for entry in entries
    ):
        raise ValueError(f"{name} is not a list of objects")
    return entries


def disables_authentication(options: Any) -> bool:
    """Return whether an options list contains authenticate=false."""
    if options is None:
        return False
    if not isinstance(options, list) or not all(
        isinstance(option, dict) for option in options
    ):
        raise ValueError("Options is not a list of objects")
    return any(option.get("authenticate") is False for option in options)


def is_only_root(binding: Any) -> bool:
    """Return whether a binding names exactly the root user and nothing else."""
    return binding == [{"username": "root"}]


def compact(value: Any) -> str:
    """Render a policy binding on one stable output line."""
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


def findings(document: dict[str, Any]) -> list[str]:
    """Find policy entries that let anything other than root skip a password."""
    result: list[str] = []

    for index, entry in enumerate(section(document, "Defaults")):
        if not disables_authentication(entry.get("Options")):
            continue
        binding = entry.get("Binding")
        if not is_only_root(binding):
            applies_to = "all users" if binding is None else compact(binding)
            result.append(f"Defaults[{index}] sets authenticate=false for {applies_to}")

    for index, entry in enumerate(section(document, "User_Specs")):
        user_list = entry.get("User_List")
        command_specs = entry.get("Cmnd_Specs")
        if not isinstance(user_list, list):
            raise TypeError(f"User_Specs[{index}].User_List is not a list")
        if not isinstance(command_specs, list) or not all(
            isinstance(command_spec, dict) for command_spec in command_specs
        ):
            raise ValueError(f"User_Specs[{index}].Cmnd_Specs is not a list of objects")
        if is_only_root(user_list):
            continue
        if any(
            disables_authentication(command_spec.get("Options"))
            for command_spec in command_specs
        ):
            result.append(
                f"User_Specs[{index}] sets authenticate=false for {compact(user_list)}"
            )

    return result


def main() -> int:
    """Read cvtsudoers JSON from stdin and return a fail-closed status."""
    try:
        document = json.load(sys.stdin)
        if not isinstance(document, dict):
            raise TypeError("the top-level JSON value is not an object")
        if not any(name in document for name in ("Defaults", "User_Specs")):
            raise ValueError("the JSON has no Defaults or User_Specs section")
        unsafe_entries = findings(document)
    except (json.JSONDecodeError, OSError, TypeError, ValueError) as error:
        print(f"Could not parse cvtsudoers JSON safely: {error}")
        return 2

    for entry in unsafe_entries:
        print(entry)
    return 1 if unsafe_entries else 0


if __name__ == "__main__":
    sys.exit(main())
