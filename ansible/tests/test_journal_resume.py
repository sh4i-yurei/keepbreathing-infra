"""Checks for the live resume helper's lost-cursor verification."""

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest
from load_source import load_source

resume = load_source("ansible/roles/hub/files/journal-resume-test.py")

INVALID_HOST_ERROR = (
    "argument --host: invalid choice: 'wrong' (choose from almaserv, control, mail, vaultserv, web)"
    if sys.version_info < (3, 14)
    else "argument --host: invalid choice: 'wrong' (choose from 'almaserv', 'control', 'mail', 'vaultserv', 'web')"
)


def test_source_vacuum_reports_recovery(
    monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    calls = []
    monkeypatch.setattr(resume, "command", lambda *args: calls.append(args))
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    with pytest.raises(RuntimeError) as raised:
        resume.source_vacuum(False)
    assert str(raised.value) == (
        "source-vacuum deletes archived journals; pass --confirm-delete-archived-journals"
    )
    resume.source_vacuum(True)
    assert calls == [("journalctl", "--rotate"), ("journalctl", "--vacuum-time=1s")]
    assert capsys.readouterr().out == (
        "Archived source journals were vacuumed. Verify recovery on the hub.\n"
    )


def test_gap_counter_reads_one_host_sample(monkeypatch: pytest.MonkeyPatch) -> None:
    paths: list[Path] = []

    def read_text(path: Path, *_args, **_kwargs) -> str:
        paths.append(path)
        return 'journal_pull_gaps_total{host="mail"} 3\n'

    monkeypatch.setattr(
        resume.Path,
        "read_text",
        read_text,
    )
    assert resume.gap_counter("mail") == 3
    with pytest.raises(RuntimeError, match="cannot read"):
        resume.gap_counter("web")
    assert paths == [
        Path("/var/lib/journal_pull/mail/gaps.prom"),
        Path("/var/lib/journal_pull/web/gaps.prom"),
    ]


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
    assert capsys.readouterr().out == (
        "journal-pull@mail.service is active; a new gap marker reached the imported "
        "journal and Loki, and the gap counter increased.\n"
    )


def test_command_and_source_markers(monkeypatch) -> None:
    calls = []
    monkeypatch.setattr(
        resume.subprocess,
        "run",
        lambda *args, **kwargs: (
            calls.append((args, kwargs)) or SimpleNamespace(returncode=0)
        ),
    )
    monkeypatch.setattr(
        resume.time, "sleep", lambda seconds: calls.append(("sleep", seconds))
    )
    assert resume.command("true") == SimpleNamespace(returncode=0)
    resume.source_markers("trial", 2, 0.5)
    assert calls == [
        ((("true",),), {"check": True, "capture_output": True, "text": True}),
        (
            (("logger", "--tag", "journal-resume-test", "run=trial seq=0001"),),
            {"check": True, "capture_output": True, "text": True},
        ),
        ("sleep", 0.5),
        (
            (("logger", "--tag", "journal-resume-test", "run=trial seq=0002"),),
            {"check": True, "capture_output": True, "text": True},
        ),
        ("sleep", 0.5),
    ]


def test_journal_lines_and_wait_for_count(monkeypatch) -> None:
    monkeypatch.setattr(
        resume,
        "command",
        lambda *_args, **_kwargs: SimpleNamespace(
            returncode=0, stdout="run=x seq=0001\nnoise\nrun=y seq=0002\n"
        ),
    )
    assert resume.journal_lines("mail", "x") == ["run=x seq=0001"]
    monkeypatch.setattr(
        resume,
        "command",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=1, stdout=""),
    )
    with pytest.raises(RuntimeError) as raised:
        resume.journal_lines("mail", "x")
    assert str(raised.value) == "cannot read mail's imported journal"
    monkeypatch.setattr(resume, "journal_lines", lambda *_args: ["run=x seq=0001"])
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0, 1]).__next__)
    assert resume.wait_for_count("mail", "x", 1, 1) == 1
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0, 1]).__next__)
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    with pytest.raises(RuntimeError) as raised:
        resume.wait_for_count("mail", "x", 2, 1)
    assert str(raised.value) == "only 1 of 2 markers arrived"


def test_hub_cycle_stops_and_restarts_at_each_point(monkeypatch) -> None:
    calls = []
    monkeypatch.setattr(
        resume,
        "wait_for_count",
        lambda host, run_id, count: (
            calls.append(("wait", host, run_id, count)) or count
        ),
    )
    monkeypatch.setattr(resume, "command", lambda *args: calls.append(args))
    monkeypatch.setattr(
        resume.time, "sleep", lambda seconds: calls.append(("sleep", seconds))
    )
    resume.hub_cycle("mail", "trial", 24)
    assert calls == [
        ("wait", "mail", "trial", 4),
        ("systemctl", "stop", "journal-pull@mail.service"),
        ("sleep", 2),
        ("systemctl", "start", "journal-pull@mail.service"),
        ("wait", "mail", "trial", 8),
        ("systemctl", "stop", "journal-pull@mail.service"),
        ("sleep", 2),
        ("systemctl", "start", "journal-pull@mail.service"),
        ("wait", "mail", "trial", 16),
        ("systemctl", "stop", "journal-pull@mail.service"),
        ("sleep", 2),
        ("systemctl", "start", "journal-pull@mail.service"),
        ("wait", "mail", "trial", 24),
    ]
    with pytest.raises(ValueError) as raised:
        resume.hub_cycle("mail", "trial", 3)
    assert (
        str(raised.value)
        == "at least six markers are needed for three interruption points"
    )
    monkeypatch.setattr(resume, "wait_for_count", lambda *_args: 24)
    with pytest.raises(RuntimeError) as raised:
        resume.hub_cycle("mail", "trial", 24)
    assert str(raised.value) == "the source finished before a mid-stream interruption"


def test_marker_counts_and_loki_lines(monkeypatch) -> None:
    assert resume.marker_counts(
        ["run=x seq=0001", "run=x seq=0001", "run=y seq=0002", "bad"], "x"
    ) == {1: 2}

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    monkeypatch.setattr(
        resume,
        "urlopen",
        lambda *_args, **_kwargs: Response(
            b'{"status":"success","data":{"result":[{"values":[["1","one"],["2","two"]]}]}}'
        ),
    )
    assert resume.loki_lines("mail", "x") == ["one", "two"]
    monkeypatch.setattr(
        resume, "urlopen", lambda *_args, **_kwargs: Response(b'{"status":"error"}')
    )
    with pytest.raises(RuntimeError) as raised:
        resume.loki_lines("mail", "x")
    assert str(raised.value) == "Loki did not complete the marker query"


def test_verify_reports_exact_count_or_timeout(monkeypatch, capsys) -> None:
    monkeypatch.setattr(resume, "journal_lines", lambda *_args: ["run=x seq=0001"])
    monkeypatch.setattr(resume, "loki_lines", lambda *_args: ["run=x seq=0001"])
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0]).__next__)
    resume.verify("mail", "x", 1)
    assert (
        capsys.readouterr().out
        == "All 1 markers occur exactly once in the imported journal and Loki.\n"
    )
    monkeypatch.setattr(resume, "loki_lines", lambda *_args: [])
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0, 120]).__next__)

    def advance_clock(seconds):
        if seconds is None:
            raise TypeError("sleep duration must be numeric")

    monkeypatch.setattr(resume.time, "sleep", advance_clock)
    with pytest.raises(RuntimeError) as raised:
        resume.verify("mail", "x", 1)
    assert (
        str(raised.value)
        == "markers differ: imported=Counter({1: 1}); loki=Counter(); expected=Counter({1: 1})"
    )


def test_prepare_loss_and_gap_query_failures(monkeypatch, capsys) -> None:
    calls = []
    monkeypatch.setattr(
        resume,
        "command",
        lambda *args, **_kwargs: calls.append(args) or SimpleNamespace(returncode=1),
    )
    resume.prepare_cursor_loss("mail")
    assert calls == [("systemctl", "stop", "journal-pull@mail.service")]
    assert (
        capsys.readouterr().out
        == "Puller stopped. On the source, run source-vacuum only after confirming archive deletion.\n"
    )
    with pytest.raises(RuntimeError) as raised:
        resume.imported_gap_ids("mail")
    assert str(raised.value) == "cannot read mail's imported gap markers"

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    monkeypatch.setattr(
        resume, "urlopen", lambda *_args, **_kwargs: Response(b'{"status":"error"}')
    )
    with pytest.raises(RuntimeError) as raised:
        resume.loki_has_gap("mail", "gap")
    assert str(raised.value) == "Loki did not complete the gap marker query"


def test_verify_loss_fails_for_failed_unit_and_timeout(monkeypatch) -> None:
    monkeypatch.setattr(resume, "gap_counter", lambda _host: 0)
    monkeypatch.setattr(resume, "imported_gap_ids", lambda _host: set())
    monkeypatch.setattr(
        resume, "command", lambda *_args, **_kwargs: SimpleNamespace(stdout="failed\n")
    )
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0]).__next__)
    with pytest.raises(RuntimeError) as raised:
        resume.verify_cursor_loss("mail")
    assert str(raised.value) == "journal-pull@mail.service failed instead of recovering"
    monkeypatch.setattr(
        resume,
        "command",
        lambda *_args, **_kwargs: SimpleNamespace(stdout="activating\n"),
    )
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0, 300]).__next__)

    def advance_clock(seconds):
        if seconds is None:
            raise TypeError("sleep duration must be numeric")

    monkeypatch.setattr(resume.time, "sleep", advance_clock)
    with pytest.raises(RuntimeError) as raised:
        resume.verify_cursor_loss("mail")
    assert (
        str(raised.value)
        == "journal-pull@mail.service did not show complete gap recovery within five minutes"
    )


@pytest.mark.parametrize(
    ("argv", "operation"),
    [
        (
            [
                "source-markers",
                "--run-id",
                "trial",
                "--count",
                "6",
                "--interval",
                "0.5",
            ],
            "source_markers",
        ),
        (
            ["hub-cycle", "--host", "mail", "--run-id", "trial", "--count", "6"],
            "hub_cycle",
        ),
        (["verify", "--host", "mail", "--run-id", "trial", "--count", "6"], "verify"),
        (["prepare-loss", "--host", "mail"], "prepare_cursor_loss"),
        (["source-vacuum", "--confirm-delete-archived-journals"], "source_vacuum"),
        (["verify-loss", "--host", "mail"], "verify_cursor_loss"),
    ],
)
def test_main_dispatches_selected_mode(monkeypatch, capsys, argv, operation) -> None:
    expected = {
        "source_markers": ("trial", 6, 0.5),
        "hub_cycle": ("mail", "trial", 6),
        "verify": ("mail", "trial", 6),
        "prepare_cursor_loss": ("mail",),
        "source_vacuum": (True,),
        "verify_cursor_loss": ("mail",),
    }[operation]

    def emit(*args):
        print(repr(args))

    monkeypatch.setattr(resume, operation, emit)
    monkeypatch.setattr(resume.sys, "argv", ["journal-resume-test.py", *argv])
    assert resume.main() == 0
    assert capsys.readouterr().out == f"{expected!r}\n"


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        (
            ["verify", "--host", "mail", "--run-id", "bad!"],
            "--run-id must contain 1-40 letters, digits or hyphens",
        ),
        (
            ["verify", "--host", "mail", "--run-id", "trial", "--count", "5"],
            "--count must be between 6 and 5000",
        ),
        (
            ["source-markers", "--run-id", "trial", "--interval", "0"],
            "--interval must be positive",
        ),
        (
            ["source-markers", "--run-id", "bad!"],
            "--run-id must contain 1-40 letters, digits or hyphens",
        ),
        (
            ["hub-cycle", "--host", "mail", "--run-id", "bad!"],
            "--run-id must contain 1-40 letters, digits or hyphens",
        ),
        (
            ["hub-cycle", "--host", "mail", "--run-id", "trial", "--count", "5"],
            "--count must be between 6 and 5000",
        ),
        (
            ["verify", "--host", "mail", "--run-id", "trial", "--count", "5001"],
            "--count must be between 6 and 5000",
        ),
    ],
)
def test_main_rejects_invalid_arguments(monkeypatch, capsys, argv, message) -> None:
    monkeypatch.setattr(resume.sys, "argv", ["journal-resume-test.py", *argv])
    with pytest.raises(SystemExit) as raised:
        resume.main()
    assert raised.value.code == 2
    assert (
        capsys.readouterr().err.splitlines()[-1]
        == f"{resume.argparse.ArgumentParser().prog}: error: {message}"
    )


def test_main_reports_operation_failure(monkeypatch, capsys) -> None:
    def fail(*_args):
        raise RuntimeError("journal unavailable")

    monkeypatch.setattr(resume, "verify_cursor_loss", fail)
    monkeypatch.setattr(
        resume.sys, "argv", ["journal-resume-test.py", "verify-loss", "--host", "mail"]
    )
    assert resume.main() == 1
    assert capsys.readouterr().err == "journal-resume-test: journal unavailable\n"


def test_command_entrypoint_rejects_unconfirmed_vacuum() -> None:
    path = (
        Path(__file__).resolve().parents[1] / "roles/hub/files/journal-resume-test.py"
    )
    result = subprocess.run(
        [sys.executable, str(path), "source-vacuum"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stdout == ""
    assert result.stderr == (
        "journal-resume-test: source-vacuum deletes archived journals; "
        "pass --confirm-delete-archived-journals\n"
    )


def test_journal_queries_use_exact_external_arguments(monkeypatch) -> None:
    calls = []

    def command(*args, **kwargs):
        calls.append((args, kwargs))
        return SimpleNamespace(
            returncode=0,
            stdout='{"GAP_HOST":"mail","GAP_ID":"gap1"}\n'
            if "--output=json" in args
            else "run=x seq=0001\n",
        )

    monkeypatch.setattr(resume, "command", command)
    assert resume.journal_lines("mail", "x") == ["run=x seq=0001"]
    assert resume.imported_gap_ids("mail") == {"gap1"}
    assert calls == [
        (
            (
                "journalctl",
                "--directory=/var/log/journal/remote/mail",
                "--identifier",
                "journal-resume-test",
                "--output=cat",
                "--no-pager",
                "--quiet",
            ),
            {"check": False},
        ),
        (
            (
                "journalctl",
                "--directory=/var/log/journal/remote/mail",
                "--identifier=journal-pull",
                "--output=json",
                "--no-pager",
                "--quiet",
            ),
            {"check": False},
        ),
    ]


def test_loki_queries_use_exact_urls(monkeypatch) -> None:
    urls = []

    class Response(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.close()

    def open_url(url, *, timeout):
        urls.append((url, timeout))
        return Response(b'{"status":"success","data":{"result":[]}}')

    monkeypatch.setattr(resume, "urlopen", open_url)
    assert resume.loki_lines("mail", "x") == []
    assert resume.loki_has_gap("mail", "gap1") is False
    assert urls == [
        (
            "http://127.0.0.1:3100/loki/api/v1/query_range?query=%7Bhost%3D%22mail%22%2Cidentifier%3D%22journal-resume-test%22%7D+%7C%3D+%22run%3Dx%22&since=1h&limit=5000&direction=forward",
            20,
        ),
        (
            "http://127.0.0.1:3100/loki/api/v1/query_range?query=%7Bhost%3D%22mail%22%2Cidentifier%3D%22journal-pull%22%7D+%7C%3D+%22gap_id%3Dgap1%22&since=90d&limit=100&direction=forward",
            20,
        ),
    ]


def test_main_uses_documented_defaults(monkeypatch, capsys) -> None:
    monkeypatch.setattr(
        resume.sys,
        "argv",
        ["journal-resume-test.py", "source-markers", "--run-id", "trial"],
    )
    monkeypatch.setattr(resume, "source_markers", lambda *args: print(repr(args)))
    assert resume.main() == 0
    assert capsys.readouterr().out == "('trial', 24, 1.0)\n"
    monkeypatch.setattr(
        resume.sys,
        "argv",
        ["journal-resume-test.py", "verify", "--host", "mail", "--run-id", "trial"],
    )
    monkeypatch.setattr(resume, "verify", lambda *args: print(repr(args)))
    assert resume.main() == 0
    assert capsys.readouterr().out == "('mail', 'trial', 24)\n"


def test_main_accepts_uppercase_run_id_and_maximum_count(monkeypatch, capsys) -> None:
    monkeypatch.setattr(
        resume.sys,
        "argv",
        [
            "journal-resume-test.py",
            "source-markers",
            "--run-id",
            "TRIAL",
            "--count",
            "5000",
        ],
    )
    monkeypatch.setattr(resume, "source_markers", lambda *args: print(repr(args)))
    assert resume.main() == 0
    assert capsys.readouterr().out == "('TRIAL', 5000, 1.0)\n"


@pytest.mark.parametrize(
    ("argv", "message"),
    [
        ([], "the following arguments are required: mode"),
        (["source-markers"], "the following arguments are required: --run-id"),
        (
            ["hub-cycle", "--host", "mail"],
            "the following arguments are required: --run-id",
        ),
        (
            ["hub-cycle", "--run-id", "trial"],
            "the following arguments are required: --host",
        ),
        (["prepare-loss"], "the following arguments are required: --host"),
        (
            ["hub-cycle", "--host", "wrong", "--run-id", "trial"],
            INVALID_HOST_ERROR,
        ),
        (
            ["verify-loss", "--host", "wrong"],
            INVALID_HOST_ERROR,
        ),
    ],
)
def test_main_requires_modes_and_arguments(monkeypatch, capsys, argv, message) -> None:
    monkeypatch.setattr(resume.sys, "argv", ["journal-resume-test.py", *argv])
    with pytest.raises(SystemExit) as raised:
        resume.main()
    assert raised.value.code == 2
    assert capsys.readouterr().err.splitlines()[-1] == (
        f"{resume.argparse.ArgumentParser().prog}{' ' + argv[0] if argv else ''}: error: {message}"
    )


def test_main_help_explains_the_live_check(monkeypatch, capsys) -> None:
    monkeypatch.setattr(resume.sys, "argv", ["journal-resume-test.py", "--help"])
    with pytest.raises(SystemExit) as raised:
        resume.main()
    assert raised.value.code == 0
    output = capsys.readouterr()
    assert output.err == ""
    assert " ".join(resume.__doc__.split()) in " ".join(output.out.split())


@pytest.mark.parametrize(
    ("state", "count", "ids", "in_loki"),
    [
        ("activating", 1, {"gap1"}, True),
        ("active", 0, {"gap1"}, True),
        ("active", 1, set(), True),
        ("active", 1, {"gap1"}, False),
    ],
)
def test_verify_loss_requires_each_recovery_signal(
    monkeypatch, state, count, ids, in_loki
) -> None:
    observed = []
    counts = iter([0, count])
    markers = iter([set(), ids])

    def gap_counter(host):
        observed.append(("counter", host))
        return next(counts)

    def imported(host):
        observed.append(("markers", host))
        return next(markers)

    def loki(host, gap_id):
        observed.append(("loki", host, gap_id))
        return in_loki

    def command(*args, **kwargs):
        observed.append(("command", args, kwargs))
        return SimpleNamespace(stdout=state + "\n")

    monkeypatch.setattr(resume, "gap_counter", gap_counter)
    monkeypatch.setattr(resume, "imported_gap_ids", imported)
    monkeypatch.setattr(resume, "loki_has_gap", loki)
    monkeypatch.setattr(resume, "command", command)
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0, 300]).__next__)
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    with pytest.raises(RuntimeError) as raised:
        resume.verify_cursor_loss("mail")
    assert str(raised.value) == (
        "journal-pull@mail.service did not show complete gap recovery within five minutes"
    )
    assert observed[:4] == [
        ("counter", "mail"),
        ("markers", "mail"),
        (
            "command",
            ("systemctl", "start", "journal-pull@mail.service"),
            {"check": False},
        ),
        (
            "command",
            ("systemctl", "is-active", "journal-pull@mail.service"),
            {"check": False},
        ),
    ]
    assert ("markers", "mail") in observed[4:]
    if state == "active":
        assert ("counter", "mail") in observed[4:]
    if state == "active" and count > 0 and ids:
        assert ("loki", "mail", "gap1") in observed


def test_verify_queries_the_requested_host_and_run(monkeypatch, capsys) -> None:
    calls = []

    def imported(host, run_id):
        calls.append(("journal", host, run_id))
        return ["run=trial seq=0001"]

    def stored(host, run_id):
        calls.append(("loki", host, run_id))
        return ["run=trial seq=0001"]

    monkeypatch.setattr(resume, "journal_lines", imported)
    monkeypatch.setattr(resume, "loki_lines", stored)
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 0]).__next__)
    resume.verify("mail", "trial", 1)
    assert calls == [("journal", "mail", "trial"), ("loki", "mail", "trial")]
    assert capsys.readouterr().out == (
        "All 1 markers occur exactly once in the imported journal and Loki.\n"
    )


@pytest.mark.parametrize(
    ("count", "expected"),
    [(5, [1, 2, 3, 5]), (6, [1, 2, 4, 6]), (7, [1, 2, 4, 7])],
)
def test_hub_cycle_uses_three_distinct_small_run_points(
    monkeypatch, count, expected
) -> None:
    points = []
    monkeypatch.setattr(
        resume,
        "wait_for_count",
        lambda _host, _run_id, minimum: points.append(minimum) or minimum,
    )
    monkeypatch.setattr(resume, "command", lambda *_args: None)
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    resume.hub_cycle("mail", "trial", count)
    assert points == expected


def test_gap_counter_finds_sample_among_metric_metadata(monkeypatch) -> None:
    monkeypatch.setattr(
        resume.Path,
        "read_text",
        lambda _path, **_kwargs: (
            "# HELP journal_pull_gaps_total Recovered gaps.\n"
            "# TYPE journal_pull_gaps_total counter\n"
            'journal_pull_gaps_total{host="mail"} 3\n'
        ),
    )
    assert resume.gap_counter("mail") == 3


def test_gap_counter_reads_real_utf8_metric_file(monkeypatch, tmp_path) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 3\n', encoding="utf-8")
    monkeypatch.setattr(resume, "Path", lambda _path: metric)
    assert resume.gap_counter("mail") == 3


def test_source_vacuum_completes_with_its_wait(monkeypatch, capsys) -> None:
    commands = []
    monkeypatch.setattr(resume, "command", lambda *args: commands.append(args))
    resume.source_vacuum(True)
    assert commands == [("journalctl", "--rotate"), ("journalctl", "--vacuum-time=1s")]
    assert capsys.readouterr().out == (
        "Archived source journals were vacuumed. Verify recovery on the hub.\n"
    )


def test_wait_for_count_returns_after_a_delayed_marker(monkeypatch) -> None:
    samples = iter([[], ["run=trial seq=0001"]])
    monkeypatch.setattr(resume, "journal_lines", lambda _host, _id: next(samples))
    assert resume.wait_for_count("mail", "trial", 1, 5) == 1


def test_wait_for_count_uses_default_three_minute_limit(monkeypatch) -> None:
    monkeypatch.setattr(resume, "journal_lines", lambda _host, _id: [])
    monkeypatch.setattr(resume.time, "monotonic", iter([0, 179, 180]).__next__)
    monkeypatch.setattr(resume.time, "sleep", lambda _seconds: None)
    with pytest.raises(RuntimeError) as raised:
        resume.wait_for_count("mail", "trial", 1)
    assert str(raised.value) == "only 0 of 1 markers arrived"
