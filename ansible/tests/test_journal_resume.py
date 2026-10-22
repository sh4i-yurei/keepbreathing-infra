"""Checks for the live resume helper's lost-cursor verification."""

from __future__ import annotations

import importlib.util
import io
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).parents[1] / "roles/hub/files/journal-resume-test.py"
SPEC = importlib.util.spec_from_file_location("journal_resume_test", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
resume = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = resume
SPEC.loader.exec_module(resume)


def test_source_vacuum_reports_recovery(
    monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    calls = []
    monkeypatch.setattr(resume, "command", lambda *args: calls.append(args))
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    with pytest.raises(RuntimeError, match="confirm"):
        resume.source_vacuum(False)
    resume.source_vacuum(True)
    assert calls == [("journalctl", "--rotate"), ("journalctl", "--vacuum-time=1s")]
    assert "Verify recovery" in capsys.readouterr().out


def test_gap_counter_reads_one_host_sample(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(
        resume.Path,
        "read_text",
        lambda *_args, **_kwargs: 'journal_pull_gaps_total{host="mail"} 3\n',
    )
    assert resume.gap_counter("mail") == 3
    with pytest.raises(RuntimeError, match="cannot read"):
        resume.gap_counter("web")


def test_imported_gap_ids_filters_host(monkeypatch: pytest.MonkeyPatch) -> None:
    data = '{"GAP_HOST":"mail","GAP_ID":"one"}\n{"GAP_HOST":"web","GAP_ID":"two"}\n'
    monkeypatch.setattr(
        resume,
        "command",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=data),
    )
    assert resume.imported_gap_ids("mail") == {"one"}


def test_loki_has_gap_matches_marker(monkeypatch: pytest.MonkeyPatch) -> None:
    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    monkeypatch.setattr(
        resume,
        "urlopen",
        lambda *_args, **_kwargs: Response(
            b'{"status":"success","data":{"result":[{"values":[["1","gap_id=one"]]}]}}'
        ),
    )
    assert resume.loki_has_gap("mail", "one")
    assert not resume.loki_has_gap("mail", "two")


def test_verify_loss_requires_active_marker_loki_and_increment(
    monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    counts = iter([0, 1])
    markers = iter([set(), {"gap1"}])
    monkeypatch.setattr(resume, "gap_counter", lambda _host: next(counts))
    monkeypatch.setattr(resume, "imported_gap_ids", lambda _host: next(markers))
    monkeypatch.setattr(resume, "loki_has_gap", lambda _host, gap_id: gap_id == "gap1")
    calls = []

    def command(*args, **_kwargs):
        calls.append(args)
        return SimpleNamespace(stdout="active\n")

    monkeypatch.setattr(resume, "command", command)
    resume.verify_cursor_loss("mail")
    assert ("systemctl", "start", "journal-pull@mail.service") in calls
    assert "gap counter increased" in capsys.readouterr().out
