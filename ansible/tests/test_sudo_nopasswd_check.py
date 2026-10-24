"""The sudo policy checker reports unsafe bindings and fails closed on bad JSON."""

from __future__ import annotations

import io
import json
import subprocess
import sys
from pathlib import Path

import pytest
from load_source import load_source

checker = load_source("ansible/roles/access/files/sudo-nopasswd-check.py")


@pytest.mark.parametrize(
    ("document", "status", "output"),
    [
        ({"Defaults": []}, 0, ""),
        (
            {
                "Defaults": [
                    {
                        "Options": [{"authenticate": False}],
                        "Binding": [{"username": "root"}],
                    }
                ]
            },
            0,
            "",
        ),
        ({"Defaults": [{"Options": [{"authenticate": True}]}]}, 0, ""),
        ({"Defaults": [{"Options": None}]}, 0, ""),
        ({"Defaults": [{"Options": [{}]}]}, 0, ""),
        (
            {
                "Defaults": [
                    {"Options": [{"authenticate": True}]},
                    {"Options": [{"authenticate": False}]},
                ]
            },
            1,
            "Defaults[1] sets authenticate=false for all users\n",
        ),
        (
            {"Defaults": [{"Options": [{"authenticate": False}]}]},
            1,
            "Defaults[0] sets authenticate=false for all users\n",
        ),
        (
            {
                "Defaults": [
                    {
                        "Options": [{"authenticate": False}],
                        "Binding": [{"username": "alice"}],
                    }
                ]
            },
            1,
            'Defaults[0] sets authenticate=false for [{"username":"alice"}]\n',
        ),
        (
            {"User_Specs": [{"User_List": [{"username": "root"}], "Cmnd_Specs": []}]},
            0,
            "",
        ),
        (
            {
                "User_Specs": [
                    {
                        "User_List": [{"username": "root"}],
                        "Cmnd_Specs": [{"Options": [{"authenticate": False}]}],
                    }
                ]
            },
            0,
            "",
        ),
        (
            {
                "User_Specs": [
                    {
                        "User_List": [{"username": "alice"}],
                        "Cmnd_Specs": [{"Options": [{"authenticate": False}]}],
                    }
                ]
            },
            1,
            'User_Specs[0] sets authenticate=false for [{"username":"alice"}]\n',
        ),
        (
            {
                "User_Specs": [
                    {
                        "User_List": [{"username": "alice"}],
                        "Cmnd_Specs": [{"Options": [{"authenticate": True}]}],
                    }
                ]
            },
            0,
            "",
        ),
        (
            {"Defaults": "bad"},
            2,
            "Could not parse cvtsudoers JSON safely: Defaults is not a list of objects\n",
        ),
        (
            {"Defaults": ["bad"]},
            2,
            "Could not parse cvtsudoers JSON safely: Defaults is not a list of objects\n",
        ),
        (
            {"Defaults": [{"Options": "bad"}]},
            2,
            "Could not parse cvtsudoers JSON safely: Options is not a list of objects\n",
        ),
        (
            {"Defaults": [{"Options": ["bad"]}]},
            2,
            "Could not parse cvtsudoers JSON safely: Options is not a list of objects\n",
        ),
        (
            {"User_Specs": [{"User_List": None, "Cmnd_Specs": []}]},
            2,
            "Could not parse cvtsudoers JSON safely: User_Specs[0].User_List is not a list\n",
        ),
        (
            {"User_Specs": [{"User_List": [], "Cmnd_Specs": None}]},
            2,
            "Could not parse cvtsudoers JSON safely: User_Specs[0].Cmnd_Specs is not a list of objects\n",
        ),
        (
            {"User_Specs": [{"User_List": [], "Cmnd_Specs": [None]}]},
            2,
            "Could not parse cvtsudoers JSON safely: User_Specs[0].Cmnd_Specs is not a list of objects\n",
        ),
        (
            {"User_Specs": [{"User_List": [], "Cmnd_Specs": [{"Options": "bad"}]}]},
            2,
            "Could not parse cvtsudoers JSON safely: Options is not a list of objects\n",
        ),
        (
            {},
            2,
            "Could not parse cvtsudoers JSON safely: the JSON has no Defaults or User_Specs section\n",
        ),
        (
            [],
            2,
            "Could not parse cvtsudoers JSON safely: the top-level JSON value is not an object\n",
        ),
    ],
)
def test_policy_status_and_output(
    monkeypatch, capsys, document, status, output
) -> None:
    monkeypatch.setattr(checker.sys, "stdin", io.StringIO(json.dumps(document)))
    assert checker.main() == status
    assert capsys.readouterr().out == output


def test_invalid_json_fails_closed(monkeypatch, capsys) -> None:
    monkeypatch.setattr(checker.sys, "stdin", io.StringIO("{"))
    assert checker.main() == 2
    assert capsys.readouterr().out == (
        "Could not parse cvtsudoers JSON safely: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)\n"
    )


def test_command_entrypoint_reports_unsafe_policy() -> None:
    path = (
        Path(__file__).resolve().parents[1]
        / "roles/access/files/sudo-nopasswd-check.py"
    )
    result = subprocess.run(
        [sys.executable, str(path)],
        input='{"Defaults":[{"Options":[{"authenticate":false}]}]}',
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stdout == "Defaults[0] sets authenticate=false for all users\n"
    assert result.stderr == ""


def test_binding_output_sorts_keys_and_has_no_extra_whitespace(
    monkeypatch, capsys
) -> None:
    document = {
        "Defaults": [
            {
                "Options": [{"authenticate": False}],
                "Binding": [{"username": "alice", "role": "ops"}],
            }
        ]
    }
    monkeypatch.setattr(checker.sys, "stdin", io.StringIO(json.dumps(document)))
    assert checker.main() == 1
    assert capsys.readouterr().out == (
        'Defaults[0] sets authenticate=false for [{"role":"ops","username":"alice"}]\n'
    )


def test_later_unsafe_entries_are_all_reported(monkeypatch, capsys) -> None:
    document = {
        "Defaults": [
            {"Options": [{"authenticate": False}], "Binding": [{"username": "root"}]},
            {"Options": [{"authenticate": False}], "Binding": [{"username": "alice"}]},
        ],
        "User_Specs": [
            {"User_List": [{"username": "root"}], "Cmnd_Specs": []},
            {
                "User_List": [{"username": "alice"}],
                "Cmnd_Specs": [{"Options": [{"authenticate": False}]}],
            },
        ],
    }
    monkeypatch.setattr(checker.sys, "stdin", io.StringIO(json.dumps(document)))
    assert checker.main() == 1
    assert capsys.readouterr().out == (
        'Defaults[1] sets authenticate=false for [{"username":"alice"}]\n'
        'User_Specs[1] sets authenticate=false for [{"username":"alice"}]\n'
    )
