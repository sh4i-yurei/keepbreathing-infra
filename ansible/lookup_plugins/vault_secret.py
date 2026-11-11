"""Read one value from a vault item through the controller's Bitwarden CLI."""

import json
import os
from pathlib import Path
import subprocess

from ansible.errors import AnsibleLookupError
from ansible.plugins.lookup import LookupBase


def _message(name, field, source):
    target = f"item {name!r}"
    if field is not None:
        target += f" field {field!r}"
    if source is not None:
        target += f" using {source}"
    return f"Vault lookup failed for {target}; run vu."


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        field = kwargs.get("field")
        login = kwargs.get("login", "password")
        selected_field = "field" in kwargs
        selected_login = "login" in kwargs
        values = []
        for name in terms:
            source = None
            session = os.environ.get("BW_SESSION")
            if session:
                source = "inherited BW_SESSION"
            else:
                runtime = (
                    os.environ.get("XDG_RUNTIME_DIR") or f"/run/user/{os.getuid()}"
                )
                try:
                    session = (Path(runtime) / "bw-session").read_text()
                except OSError:
                    session = None
                if session:
                    source = "runtime session file"

            message = _message(name, field if selected_field else None, source)
            if (selected_field and selected_login) or login not in (
                "username",
                "password",
            ):
                raise AnsibleLookupError(message)
            if selected_field and (not isinstance(field, str) or not field):
                raise AnsibleLookupError(message)
            if not session:
                raise AnsibleLookupError(message)

            environment = os.environ.copy()
            environment["BW_SESSION"] = session
            environment["BW_NOINTERACTION"] = "true"
            try:
                result = subprocess.run(
                    ["bw", "list", "items", "--search", name],
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    check=False,
                )
            except OSError:
                result = None

            found = None
            if result is not None and result.returncode == 0:
                try:
                    found = json.loads(result.stdout)
                except (TypeError, ValueError):
                    pass
            matches = (
                [
                    entry
                    for entry in found
                    if isinstance(entry, dict) and entry.get("name") == name
                ]
                if isinstance(found, list)
                else []
            )
            if len(matches) != 1:
                raise AnsibleLookupError(message)
            item = matches[0]

            if selected_field:
                fields = item.get("fields")
                matches = (
                    [
                        entry
                        for entry in fields
                        if isinstance(entry, dict) and entry.get("name") == field
                    ]
                    if isinstance(fields, list)
                    else []
                )
                if len(matches) != 1 or matches[0].get("value") is None:
                    raise AnsibleLookupError(message)
                value = matches[0]["value"]
            else:
                login_data = item.get("login")
                value = login_data.get(login) if isinstance(login_data, dict) else None
                if value is None:
                    raise AnsibleLookupError(message)
            values.append(value)
        return values
