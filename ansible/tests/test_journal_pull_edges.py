"""Fail-closed journal pull cases through returned values, errors, and files."""

from __future__ import annotations

import io
import json
import signal
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from types import SimpleNamespace

import pytest
from load_source import load_source

pull = load_source("ansible/roles/hub/files/journal-pull.py")


def entry(cursor: bytes = b"one") -> bytes:
    return b"__CURSOR=" + cursor + b"\n__REALTIME_TIMESTAMP=2000000\nMESSAGE=hello\n\n"


@pytest.mark.parametrize(
    ("data", "message"),
    [
        (b"X", "journal export field is too large or truncated"),
        (b"\n", "empty journal export entry"),
        (b"bad-name\n" + struct.pack("<Q", 1) + b"x\n\n", "invalid binary field name"),
        (b"X\n123", "truncated binary field length"),
        (
            b"X\n" + struct.pack("<Q", 256 * 1024 * 1024 + 1),
            "binary journal field exceeds the 256 MiB limit",
        ),
        (
            b"X\n" + struct.pack("<Q", 1 << 63),
            "binary journal field exceeds the 256 MiB limit",
        ),
    ],
)
def test_bad_export_input_fails_closed(data, message) -> None:
    with pytest.raises(pull.JournalPullError) as raised:
        pull.read_entry(io.BytesIO(data))
    assert str(raised.value) == message


def test_binary_export_with_short_reads_preserves_field_boundary() -> None:
    class ShortFirstRead(io.BytesIO):
        def __init__(self, data: bytes) -> None:
            super().__init__(data)
            self.short_next = False

        def read(self, size: int = -1) -> bytes:
            if self.short_next:
                self.short_next = False
                return super().read(min(size, 2))
            return super().read(size)

    stream = ShortFirstRead(b"X\n" + struct.pack("<Q", 4) + b"abcd\n\n")
    original_read = stream.read

    def read(size: int = -1) -> bytes:
        if size == 4:
            stream.short_next = True
        return original_read(size)

    stream.read = read
    parsed = pull.read_entry(stream)
    assert parsed is not None
    assert parsed.fields == (pull.Field(b"X", b"abcd"),)


def test_export_accepts_fields_at_configured_size_limit(monkeypatch) -> None:
    monkeypatch.setattr(pull, "MAX_FIELD_BYTES", 10)
    text_entry = pull.read_entry(io.BytesIO(b"X=1234567\n\n"))
    assert text_entry is not None
    assert text_entry.fields == (pull.Field(b"X", b"1234567"),)

    binary_entry = pull.read_entry(
        io.BytesIO(b"X\n" + struct.pack("<Q", 10) + b"0123456789\n\n")
    )
    assert binary_entry is not None
    assert binary_entry.fields == (pull.Field(b"X", b"0123456789"),)


def config(tmp_path: Path) -> dict[str, str]:
    return {
        "url": "https://example.test",
        "server_certificate": "/server.crt",
        "client_certificate": "/client.crt",
        "client_key": "$CREDENTIALS_DIRECTORY/client.key",
        "output_directory": str(tmp_path),
        "output_file": str(tmp_path / "source.journal"),
        "host": "mail",
        "gap_metric_file": str(tmp_path / "gaps.prom"),
    }


def test_run_stops_before_or_after_cursor_check(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    stopped = threading.Event()
    stopped.set()
    monkeypatch.setattr(pull, "last_committed_entry", lambda _path: None)
    assert pull.run(config(tmp_path), stopped) == 0
    stopped.clear()
    monkeypatch.setattr(
        pull, "last_committed_entry", lambda _path: pull.ResumePoint("one", 2000000)
    )
    monkeypatch.setattr(pull, "require_source_cursor", lambda *_args: stopped.set())
    assert pull.run(config(tmp_path), stopped) == 0


@pytest.mark.parametrize("point", [None, "one"])
def test_run_starts_from_head_or_saved_cursor(
    monkeypatch, tmp_path: Path, point
) -> None:
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    saved = None if point is None else pull.ResumePoint(point, 2000000)
    directories = []
    monkeypatch.setattr(
        pull, "last_committed_entry", lambda path: directories.append(path) or saved
    )
    monkeypatch.setattr(pull, "require_source_cursor", lambda *_args: None)
    commands = []
    monkeypatch.setattr(
        pull.subprocess,
        "Popen",
        lambda argv, **kwargs: commands.append((argv, kwargs)) or object(),
    )
    received = {}

    def supervise(curl, importer, stopped, **kwargs):
        received.update(curl=curl, importer=importer, stopped=stopped, **kwargs)
        return 0

    monkeypatch.setattr(pull, "supervise", supervise)
    assert pull.run(config(tmp_path), threading.Event()) == 0
    assert directories == [tmp_path]
    assert commands[0][0][-1] == "https://example.test/entries?follow"
    assert [
        value
        for flag, value in zip(commands[0][0], commands[0][0][1:])
        if flag == "--header" and value.startswith("Range:")
    ] == ([] if point is None else ["Range: entries=one"])
    assert commands[0][1] == {"stdout": subprocess.PIPE}
    assert commands[1] == (
        [
            "/usr/lib/systemd/systemd-journal-remote",
            f"--output={tmp_path / 'source.journal'}",
            "-",
        ],
        {"stdin": subprocess.PIPE},
    )
    assert received["recovery"] is None
    assert received["resume_cursor"] == point
    assert received["expected_first_cursor"] is None
    assert received["pending_gap_id"] is None
    assert received["metric_file"] == tmp_path / "gaps.prom"
    assert received["host"] == "mail"
    assert received["curl"] is not None
    assert received["importer"] is not None
    assert isinstance(received["stopped"], threading.Event)


def test_run_stops_curl_if_importer_cannot_start(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    monkeypatch.setattr(pull, "last_committed_entry", lambda _path: None)
    child = object()
    attempts = []

    def popen(_argv, **_kwargs):
        attempts.append(1)
        if len(attempts) == 1:
            return child
        raise OSError("importer unavailable")

    stopped = []
    monkeypatch.setattr(pull.subprocess, "Popen", popen)
    monkeypatch.setattr(pull, "stop_child", lambda process: stopped.append(process))
    with pytest.raises(OSError) as raised:
        pull.run(config(tmp_path), threading.Event())
    assert str(raised.value) == "importer unavailable"
    assert stopped == [child]


def test_main_reports_success_failure_and_requested_stop(
    monkeypatch, capsys, tmp_path: Path
) -> None:
    config_file = tmp_path / "pull.json"
    config_file.write_text(json.dumps(config(tmp_path)))
    monkeypatch.setattr(
        pull.sys, "argv", ["journal-pull.py", "--config", str(config_file)]
    )
    monkeypatch.setattr(pull.signal, "signal", lambda *_args: None)
    monkeypatch.setattr(pull, "run", lambda _config, _stopped: 0)
    assert pull.main() == 0
    assert capsys.readouterr().err == ""

    def fail(_config, _stopped):
        raise pull.JournalPullError("source unavailable")

    monkeypatch.setattr(pull, "run", fail)
    assert pull.main() == 1
    assert capsys.readouterr().err == "journal-pull: source unavailable\n"

    def stopped_failure(_config, stopped):
        stopped.set()
        raise pull.JournalPullError("interrupted")

    monkeypatch.setattr(pull, "run", stopped_failure)
    assert pull.main() == 0
    assert capsys.readouterr().err == ""


def test_command_entrypoint_reports_missing_config(tmp_path: Path) -> None:
    missing = tmp_path / "absent.json"
    path = Path(__file__).resolve().parents[1] / "roles/hub/files/journal-pull.py"
    result = subprocess.run(
        [sys.executable, str(path), "--config", str(missing)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert result.stdout == ""
    assert (
        result.stderr
        == f"journal-pull: [Errno 2] No such file or directory: '{missing}'\n"
    )


def test_missing_fields_and_bad_cursor_and_timestamp() -> None:
    sample = pull.read_entry(io.BytesIO(b"MESSAGE=hello\n\n"))
    assert sample is not None
    with pytest.raises(pull.JournalPullError) as raised:
        pull.one_field(sample, b"__CURSOR")
    assert str(raised.value) == "expected one __CURSOR field"
    duplicate = pull.read_entry(io.BytesIO(b"MESSAGE=one\nMESSAGE=two\n\n"))
    assert duplicate is not None
    with pytest.raises(pull.JournalPullError) as raised:
        pull.one_field(duplicate, b"MESSAGE")
    assert str(raised.value) == "expected one MESSAGE field"
    for value in (b"", b"bad cursor", b"\xff"):
        with pytest.raises(pull.JournalPullError) as raised:
            pull.cursor_text(value)
        assert str(raised.value) == "journal cursor contains invalid characters"
    assert pull.cursor_text(b"!") == "!"
    assert pull.cursor_text(b"~") == "~"
    for value in (b"\x7f",):
        with pytest.raises(pull.JournalPullError) as raised:
            pull.cursor_text(value)
        assert str(raised.value) == "journal cursor contains invalid characters"
    one = pull.read_entry(io.BytesIO(b"__REALTIME_TIMESTAMP=1\n\n"))
    assert one is not None
    assert pull.realtime_usec(one) == 1
    zero = pull.read_entry(io.BytesIO(b"__REALTIME_TIMESTAMP=0\n\n"))
    assert zero is not None
    with pytest.raises(pull.JournalPullError) as raised:
        pull.realtime_usec(zero)
    assert str(raised.value) == "invalid __REALTIME_TIMESTAMP field"


def test_missing_or_unreadable_imported_journal(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.setattr(
        pull.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=1, stdout=b""),
    )
    assert pull.last_committed_entry(tmp_path) is None
    (tmp_path / "one.journal").write_bytes(b"")
    with pytest.raises(pull.JournalPullError) as raised:
        pull.last_committed_entry(tmp_path)
    assert str(raised.value) == "journalctl could not read the imported journal"
    monkeypatch.setattr(
        pull.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=b""),
    )
    assert pull.last_committed_entry(tmp_path) is None


def test_discrete_cursor_requires_one_matching_entry(monkeypatch) -> None:
    config = {
        "url": "https://example.test",
        "server_certificate": "/server",
        "client_certificate": "/client",
        "client_key": "/key",
    }
    with pytest.raises(ValueError) as raised:
        pull.curl_command(config, cursor=None, discrete=True)
    assert str(raised.value) == "a discrete request needs a cursor"

    for result, error_type, message in [
        (
            SimpleNamespace(returncode=7, stdout=b""),
            pull.JournalPullError,
            "source cursor check could not reach the gateway",
        ),
        (
            SimpleNamespace(returncode=0, stdout=b""),
            pull.CursorLost,
            "saved source cursor has rotated away",
        ),
        (
            SimpleNamespace(returncode=0, stdout=entry(b"other")),
            pull.CursorLost,
            "saved source cursor has rotated away",
        ),
        (
            SimpleNamespace(returncode=0, stdout=entry() + entry(b"two")),
            pull.JournalPullError,
            "discrete cursor check returned more than one entry",
        ),
    ]:
        monkeypatch.setattr(
            pull.subprocess, "run", lambda *_args, result=result, **_kwargs: result
        )
        with pytest.raises(error_type) as raised:
            pull.require_source_cursor(config, "one")
        assert str(raised.value) == message
    monkeypatch.setattr(
        pull.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=entry()),
    )
    assert pull.require_source_cursor(config, "one") is None


def test_gap_counter_rejects_bad_input_and_removes_failed_pending_write(
    monkeypatch, tmp_path: Path
) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text("bad\n")
    with pytest.raises(pull.JournalPullError) as raised:
        pull.increment_gap_counter(metric, "mail", "gap")
    assert str(raised.value) == "invalid gap counter for mail"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')

    def fail_replace(_source, _target):
        raise OSError("replace failed")

    monkeypatch.setattr(pull.os, "replace", fail_replace)
    with pytest.raises(OSError) as raised:
        pull.increment_gap_counter(metric, "mail", "gap")
    assert str(raised.value) == "replace failed"
    assert sorted(path.name for path in tmp_path.iterdir()) == ["gaps.prom"]
    assert metric.read_text() == 'journal_pull_gaps_total{host="mail"} 0\n'


def test_gap_counter_preserves_tempfile_creation_error(
    monkeypatch, tmp_path: Path
) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')

    def unavailable(**_kwargs):
        raise OSError("temporary storage unavailable")

    monkeypatch.setattr(pull.tempfile, "NamedTemporaryFile", unavailable)
    with pytest.raises(OSError) as raised:
        pull.increment_gap_counter(metric, "mail", "gap")
    assert str(raised.value) == "temporary storage unavailable"
    assert metric.read_text() == 'journal_pull_gaps_total{host="mail"} 0\n'


def test_gap_counter_preserves_replace_error_after_pending_file_disappears(
    monkeypatch, tmp_path: Path
) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')

    def disappear_then_fail(source, _target):
        Path(source).unlink()
        raise OSError("replace failed after pending file disappeared")

    monkeypatch.setattr(pull.os, "replace", disappear_then_fail)
    with pytest.raises(OSError) as raised:
        pull.increment_gap_counter(metric, "mail", "gap")
    assert str(raised.value) == "replace failed after pending file disappeared"
    assert metric.read_text() == 'journal_pull_gaps_total{host="mail"} 0\n'


def test_gap_counter_atomically_replaces_metric_on_repository_filesystem() -> None:
    with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
        metric = Path(directory) / "gaps.prom"
        metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
        assert pull.increment_gap_counter(metric, "mail", "gap") == 1
        assert "# last_gap_id gap\n" in metric.read_text()


def test_pump_rejects_changed_first_cursor_and_bad_source() -> None:
    for source, kwargs, message in [
        (
            entry(b"different"),
            {"expected_first_cursor": "first"},
            "the first entry after a gap changed before replay",
        ),
        (b"MESSAGE=hello\n\n", {}, "expected one __CURSOR field"),
    ]:
        state = pull.PumpState(threading.Event())
        pull.pump_entries(io.BytesIO(source), io.BytesIO(), state, **kwargs)
        assert isinstance(state.error, pull.JournalPullError)
        assert str(state.error) == message
        assert state.done.is_set()


def test_pump_records_pending_and_recovered_gap_ids(tmp_path: Path) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    source = (
        b"__CURSOR=first\n__REALTIME_TIMESTAMP=2000000\n"
        b"__MONOTONIC_TIMESTAMP=123456\n_BOOT_ID=0123456789abcdef0123456789abcdef\n\n"
    )
    state = pull.PumpState(threading.Event())
    pull.pump_entries(
        io.BytesIO(source),
        io.BytesIO(),
        state,
        pending_gap_id="pending",
        metric_file=metric,
        host="mail",
    )
    assert state.error is None
    assert "# last_gap_id pending\n" in metric.read_text()

    state = pull.PumpState(threading.Event())
    pull.pump_entries(
        io.BytesIO(source),
        io.BytesIO(),
        state,
        recovery=pull.GapRecovery("mail", "lost", 1000000, metric),
    )
    assert state.error is None
    assert "# last_gap_id 91300576c5412883\n" in metric.read_text()


def test_pending_gap_needs_metric_file_and_host(tmp_path: Path) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    for kwargs in ({"metric_file": metric}, {"host": "mail"}):
        state = pull.PumpState(threading.Event())
        pull.pump_entries(
            io.BytesIO(entry()), io.BytesIO(), state, pending_gap_id="pending", **kwargs
        )
        assert isinstance(state.error, AssertionError)
    assert metric.read_text() == 'journal_pull_gaps_total{host="mail"} 0\n'


def test_pump_completes_even_when_sink_close_fails() -> None:
    class BrokenClose(io.BytesIO):
        fail_once = True

        def close(self):
            if self.fail_once:
                self.fail_once = False
                raise OSError("close failed")
            super().close()

    state = pull.PumpState(threading.Event())
    sink = BrokenClose()
    pull.pump_entries(io.BytesIO(entry()), sink, state)
    assert state.error is None
    assert state.done.is_set()
    assert sink.getvalue() == entry()[:-1] + b"REMOTE_SOURCE_CURSOR=one\n\n"


def test_stop_child_kills_after_termination_timeout() -> None:
    events = []

    class Child:
        def poll(self):
            return None

        def terminate(self):
            events.append("terminate")

        def wait(self, *, timeout):
            events.append(("wait", timeout))
            if len(events) == 2:
                raise subprocess.TimeoutExpired("child", timeout)

        def kill(self):
            events.append("kill")

    pull.stop_child(Child())
    assert events == ["terminate", ("wait", 5), "kill", ("wait", 5)]


def test_supervise_rejects_missing_pipes() -> None:
    with pytest.raises(pull.JournalPullError) as raised:
        pull.supervise(
            SimpleNamespace(stdout=None),
            SimpleNamespace(stdin=io.BytesIO()),
            threading.Event(),
        )
    assert str(raised.value) == "children did not provide their journal stream pipes"


def test_supervise_reports_pump_failure(monkeypatch) -> None:
    curl = SimpleNamespace(stdout=io.BytesIO(b"MESSAGE=hello\n\n"), poll=lambda: None)
    importer = SimpleNamespace(stdin=io.BytesIO(), poll=lambda: None)
    monkeypatch.setattr(pull, "stop_child", lambda _child: None)
    with pytest.raises(pull.JournalPullError) as raised:
        pull.supervise(curl, importer, threading.Event())
    assert str(raised.value) == "journal stream failed: expected one __CURSOR field"


def test_supervise_passes_resume_cursor_to_stream(monkeypatch) -> None:
    class RecordingSink(io.BytesIO):
        def close(self) -> None:
            pass

    sink = RecordingSink()
    curl = SimpleNamespace(
        stdout=io.BytesIO(entry() + entry(b"two")), poll=lambda: None
    )
    importer = SimpleNamespace(stdin=sink, poll=lambda: None)
    monkeypatch.setattr(pull, "stop_child", lambda _child: None)
    with pytest.raises(pull.JournalPullError) as raised:
        pull.supervise(curl, importer, threading.Event(), resume_cursor="one")
    assert str(raised.value) == "gateway journal stream ended without a stop request"
    assert sink.getvalue() == entry(b"two")[:-1] + b"REMOTE_SOURCE_CURSOR=two\n\n"


@pytest.mark.parametrize(
    ("exit_code", "message"),
    [
        (7, "curl exited with 7"),
        (0, "gateway journal stream ended without a stop request"),
    ],
)
def test_supervise_reports_curl_exit(monkeypatch, exit_code, message) -> None:
    class IdleThread:
        def __init__(self, **_kwargs):
            pass

        def start(self):
            pass

        def join(self, *, timeout):
            assert timeout == 5

    curl = SimpleNamespace(
        stdout=io.BytesIO(), poll=lambda: exit_code, returncode=exit_code
    )
    importer = SimpleNamespace(stdin=io.BytesIO(), poll=lambda: None)
    stopped = SimpleNamespace(wait=lambda _seconds: False, is_set=lambda: False)
    monkeypatch.setattr(pull.threading, "Thread", IdleThread)
    monkeypatch.setattr(pull, "stop_child", lambda _child: None)
    with pytest.raises(pull.JournalPullError) as raised:
        pull.supervise(curl, importer, stopped)
    assert str(raised.value) == message


def test_curl_request_arguments_are_exact() -> None:
    settings = {
        "url": "https://example.test:19531",
        "server_certificate": "/trust/server.crt",
        "client_certificate": "/identity/client.crt",
        "client_key": "/identity/client.key",
    }
    base = [
        "curl",
        "--silent",
        "--show-error",
        "--fail",
        "--no-buffer",
        "--connect-timeout",
        "10",
        "--noproxy",
        "*",
        "--cacert",
        "/trust/server.crt",
        "--cert",
        "/identity/client.crt",
        "--key",
        "/identity/client.key",
        "--header",
        "Accept: application/vnd.fdo.journal",
    ]
    assert pull.curl_command(settings, cursor=None, discrete=False) == [
        *base,
        "https://example.test:19531/entries?follow",
    ]
    assert pull.curl_command(settings, cursor="saved", discrete=False) == [
        *base,
        "--header",
        "Range: entries=saved",
        "https://example.test:19531/entries?follow",
    ]
    assert pull.curl_command(settings, cursor="saved", discrete=True) == [
        *base,
        "--max-time",
        "20",
        "--header",
        "Range: entries=saved",
        "https://example.test:19531/entries?discrete",
    ]


def test_gap_marker_is_an_exact_export_entry(tmp_path: Path) -> None:
    source = pull.read_entry(
        io.BytesIO(
            b"__CURSOR=first\n__REALTIME_TIMESTAMP=2000000\n"
            b"__MONOTONIC_TIMESTAMP=123456\n_BOOT_ID=0123456789abcdef0123456789abcdef\n"
            b"MESSAGE=hello\n\n"
        )
    )
    assert source is not None
    marker = pull.gap_marker(
        pull.GapRecovery("mail", "lost", 1000000, tmp_path / "gaps.prom"), source
    )
    assert marker == pull.GapMarker(
        b"__REALTIME_TIMESTAMP=1500000\n"
        b"_BOOT_ID=0123456789abcdef0123456789abcdef\n"
        b"__MONOTONIC_TIMESTAMP=123456\n"
        b"SYSLOG_IDENTIFIER=journal-pull\nPRIORITY=4\n"
        b"MESSAGE=Logs from mail were lost between 1970-01-01T00:00:01+00:00 "
        b"and 1970-01-01T00:00:02+00:00; the number of missing entries is unknown. "
        b"The hub resumed from the oldest available entry. gap_id=91300576c5412883\n"
        b"GAP_HOST=mail\nGAP_ID=91300576c5412883\nGAP_SAVED_CURSOR=lost\n"
        b"GAP_FIRST_CURSOR=first\nGAP_LAST_REALTIME_USEC=1000000\n"
        b"GAP_FIRST_REALTIME_USEC=2000000\nREMOTE_SOURCE_CURSOR=lost\n\n",
        "first",
        "91300576c5412883",
    )


def test_last_committed_entry_requests_exact_last_export(
    monkeypatch, tmp_path: Path
) -> None:
    requests = []

    def journalctl(command, **kwargs):
        requests.append((command, kwargs))
        return SimpleNamespace(
            returncode=0,
            stdout=b"REMOTE_SOURCE_CURSOR=saved\n__REALTIME_TIMESTAMP=2000000\n\n",
        )

    monkeypatch.setattr(pull.subprocess, "run", journalctl)
    assert pull.last_committed_entry(tmp_path) == pull.ResumePoint("saved", 2000000)
    assert requests == [
        (
            [
                "journalctl",
                f"--directory={tmp_path}",
                "--reverse",
                "--lines=1",
                "--output=export",
                "--no-pager",
                "--quiet",
            ],
            {"capture_output": True, "check": False},
        )
    ]


def test_discrete_cursor_check_uses_exact_curl_request(monkeypatch) -> None:
    settings = {
        "url": "https://example.test:19531",
        "server_certificate": "/trust/server.crt",
        "client_certificate": "/identity/client.crt",
        "client_key": "/identity/client.key",
    }
    requests = []

    def curl(command, **kwargs):
        requests.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout=entry(b"saved"))

    monkeypatch.setattr(pull.subprocess, "run", curl)
    assert pull.require_source_cursor(settings, "saved") is None
    assert requests == [
        (
            [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--no-buffer",
                "--connect-timeout",
                "10",
                "--noproxy",
                "*",
                "--cacert",
                "/trust/server.crt",
                "--cert",
                "/identity/client.crt",
                "--key",
                "/identity/client.key",
                "--header",
                "Accept: application/vnd.fdo.journal",
                "--max-time",
                "20",
                "--header",
                "Range: entries=saved",
                "https://example.test:19531/entries?discrete",
            ],
            {"capture_output": True, "check": False, "timeout": 25},
        )
    ]


def test_gap_counter_file_contains_exact_metric_and_is_private(tmp_path: Path) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    assert pull.increment_gap_counter(metric, "mail", "gap1") == 1
    assert metric.read_text() == (
        "# HELP journal_pull_gaps_total Number of source journal gaps recovered by the hub.\n"
        "# TYPE journal_pull_gaps_total counter\n"
        "# last_gap_id gap1\n"
        'journal_pull_gaps_total{host="mail"} 1\n'
    )
    assert metric.stat().st_mode & 0o777 == 0o640


@pytest.mark.parametrize("stop_signal", [signal.SIGTERM, signal.SIGINT])
def test_main_registers_both_stop_signals(
    monkeypatch, tmp_path: Path, stop_signal
) -> None:
    settings = config(tmp_path)
    settings_file = tmp_path / "pull.json"
    settings_file.write_text(json.dumps(settings))
    monkeypatch.setattr(
        pull.sys, "argv", ["journal-pull.py", "--config", str(settings_file)]
    )
    handlers = {}
    monkeypatch.setattr(
        pull.signal,
        "signal",
        lambda number, handler: handlers.__setitem__(number, handler),
    )

    def run(actual, stopped):
        assert actual == settings
        assert stopped.is_set() is False
        assert set(handlers) == {signal.SIGTERM, signal.SIGINT}
        handlers[stop_signal](stop_signal, None)
        assert stopped.is_set() is True
        return 0

    monkeypatch.setattr(pull, "run", run)
    assert pull.main() == 0


def test_main_requires_config_and_explains_it(monkeypatch, capsys) -> None:
    monkeypatch.setattr(pull.sys, "argv", ["journal-pull.py"])
    with pytest.raises(SystemExit) as raised:
        pull.main()
    assert raised.value.code == 2
    assert capsys.readouterr().err.splitlines()[-1] == (
        f"{pull.argparse.ArgumentParser().prog}: error: the following arguments are required: --config"
    )
    monkeypatch.setattr(pull.sys, "argv", ["journal-pull.py", "--help"])
    with pytest.raises(SystemExit) as raised:
        pull.main()
    assert raised.value.code == 0
    output = capsys.readouterr()
    assert output.err == ""
    assert " ".join(pull.__doc__.split()) in " ".join(output.out.split())


@pytest.mark.parametrize(
    ("last_usec", "marker_usec"),
    [(1999999, b"2000000"), (1999998, b"1999999")],
)
def test_gap_marker_uses_source_time_for_adjacent_entries(
    tmp_path: Path, last_usec: int, marker_usec: bytes
) -> None:
    source = pull.read_entry(
        io.BytesIO(
            b"__CURSOR=first\n__REALTIME_TIMESTAMP=2000000\n"
            b"__MONOTONIC_TIMESTAMP=123456\n_BOOT_ID=0123456789abcdef0123456789abcdef\n\n"
        )
    )
    assert source is not None
    marker = pull.gap_marker(
        pull.GapRecovery("mail", "lost", last_usec, tmp_path / "gaps.prom"), source
    )
    parsed = pull.read_entry(io.BytesIO(marker.data))
    assert parsed is not None
    assert pull.one_field(parsed, b"__REALTIME_TIMESTAMP") == marker_usec


def test_gap_marker_preserves_microseconds_near_large_second_boundary(
    tmp_path: Path,
) -> None:
    source = pull.read_entry(
        io.BytesIO(
            b"__CURSOR=first\n__REALTIME_TIMESTAMP=100000000000999999\n"
            b"__MONOTONIC_TIMESTAMP=123456\n_BOOT_ID=0123456789abcdef0123456789abcdef\n\n"
        )
    )
    assert source is not None
    marker = pull.gap_marker(
        pull.GapRecovery("mail", "lost", 100000000000000000, tmp_path / "gaps.prom"),
        source,
    )
    parsed = pull.read_entry(io.BytesIO(marker.data))
    assert parsed is not None
    assert pull.one_field(parsed, b"MESSAGE") == (
        b"Logs from mail were lost between 5138-11-16T09:46:40+00:00 "
        b"and 5138-11-16T09:46:40.999999+00:00; the number of missing entries is unknown. "
        b"The hub resumed from the oldest available entry. gap_id=91300576c5412883"
    )
