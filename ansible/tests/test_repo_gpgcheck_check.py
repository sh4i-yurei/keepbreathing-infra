"""The DNF checker reports enabled repositories with disabled GPG checks."""

from __future__ import annotations

import sys
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest
from load_source import load_source

checker = load_source("ansible/roles/baseline/files/repo-gpgcheck-check.py")


@pytest.mark.parametrize(
    ("args", "repos", "status", "output"),
    [
        ([], [], 0, ""),
        ([], [("safe", True)], 0, ""),
        ([], [("z", False), ("a", False)], 1, "a\nz\n"),
        (
            ["--config", "/tmp/dnf.conf", "--reposdir", "/tmp/repos"],
            [("unsafe", False)],
            1,
            "unsafe\n",
        ),
    ],
)
def test_enabled_repository_report(
    monkeypatch, capsys, args, repos, status, output
) -> None:
    config = SimpleNamespace(config_file_path=None, reposdir=None, read=lambda: None)
    enabled = [SimpleNamespace(id=name, gpgcheck=checked) for name, checked in repos]
    base = SimpleNamespace(
        conf=config,
        repos=SimpleNamespace(iter_enabled=lambda: enabled),
        read_all_repos=lambda: None,
    )
    monkeypatch.setitem(sys.modules, "dnf", SimpleNamespace(Base=lambda: base))
    monkeypatch.setattr(sys, "argv", ["repo-gpgcheck-check.py", *args])
    assert checker.main() == status
    assert capsys.readouterr().out == output
    if args:
        assert config.config_file_path == "/tmp/dnf.conf"
        assert config.reposdir == ["/tmp/repos"]


def test_dnf_failure_is_reported(monkeypatch, capsys) -> None:
    def broken():
        raise RuntimeError("DNF unavailable")

    monkeypatch.setitem(sys.modules, "dnf", SimpleNamespace(Base=broken))
    monkeypatch.setattr(sys, "argv", ["repo-gpgcheck-check.py"])
    assert checker.main() == 2
    assert (
        capsys.readouterr().out
        == "Could not read effective DNF repository settings: DNF unavailable\n"
    )


def test_command_entrypoint_fails_closed_without_dnf() -> None:
    path = (
        Path(__file__).resolve().parents[1]
        / "roles/baseline/files/repo-gpgcheck-check.py"
    )
    result = subprocess.run(
        [sys.executable, str(path)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 2
    assert (
        result.stdout
        == "Could not read effective DNF repository settings: No module named 'dnf'\n"
    )
    assert result.stderr == ""


def test_help_describes_both_optional_paths(monkeypatch, capsys) -> None:
    monkeypatch.setattr(sys, "argv", ["repo-gpgcheck-check.py", "--help"])
    with pytest.raises(SystemExit) as raised:
        checker.arguments()
    assert raised.value.code == 0
    output = capsys.readouterr()
    assert output.err == ""
    assert "--config CONFIG      read this DNF configuration file\n" in output.out
    assert (
        "--reposdir REPOSDIR  read repository files from this directory\n" in output.out
    )
