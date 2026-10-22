"""Journal export fidelity, cursor resume and child failure tests."""

from __future__ import annotations

import importlib.util
import signal
import struct
import subprocess
import sys
import threading
from io import BytesIO
from pathlib import Path
from types import SimpleNamespace

import pytest

SCRIPT = Path(__file__).parents[1] / "roles/hub/files/journal-pull.py"
SPEC = importlib.util.spec_from_file_location("journal_pull", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
journal_pull = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = journal_pull
SPEC.loader.exec_module(journal_pull)


class InspectableBytesIO(BytesIO):
    def close(self) -> None:
        self.flush()


def export_entry(cursor: bytes = b"s=source;i=7") -> bytes:
    return b"__CURSOR=" + cursor + b"\n__REALTIME_TIMESTAMP=2000000\nMESSAGE=hello\n\n"


def test_text_fields_are_preserved_with_only_the_added_cursor() -> None:
    original = export_entry()
    parsed = journal_pull.read_entry(BytesIO(original))
    assert parsed is not None
    assert parsed.raw == original
    assert journal_pull.add_source_cursor(parsed) == (
        original[:-1] + b"REMOTE_SOURCE_CURSOR=s=source;i=7\n\n"
    )


def test_binary_field_with_newlines_is_preserved() -> None:
    value = b"line one\nline two\x00\xff"
    original = (
        b"__CURSOR=s=source;i=7\nMESSAGE\n"
        + struct.pack("<Q", len(value))
        + value
        + b"\n\n"
    )
    parsed = journal_pull.read_entry(BytesIO(original))
    assert parsed is not None
    assert journal_pull.one_field(parsed, b"MESSAGE") == value
    assert journal_pull.add_source_cursor(parsed) == (
        original[:-1] + b"REMOTE_SOURCE_CURSOR=s=source;i=7\n\n"
    )


@pytest.mark.parametrize(
    "data",
    [
        b"__CURSOR=s=source;i=7\nMESSAGE=unfinished\n",
        b"__CURSOR=s=source;i=7\nMESSAGE\n" + struct.pack("<Q", 4) + b"abc",
        b"__CURSOR=s=source;i=7\nMESSAGE\n" + struct.pack("<Q", 4) + b"abcdx\n",
    ],
)
def test_truncated_or_malformed_entries_fail(data: bytes) -> None:
    with pytest.raises(journal_pull.JournalPullError):
        journal_pull.read_entry(BytesIO(data))


def test_invalid_field_name_fails() -> None:
    with pytest.raises(journal_pull.JournalPullError):
        journal_pull.read_entry(BytesIO(b"bad-name=value\n\n"))


def test_source_cannot_inject_the_remote_cursor() -> None:
    parsed = journal_pull.read_entry(
        BytesIO(b"__CURSOR=s=source;i=7\nREMOTE_SOURCE_CURSOR=forged\n\n")
    )
    assert parsed is not None
    with pytest.raises(journal_pull.JournalPullError, match="tried to supply"):
        journal_pull.add_source_cursor(parsed)


def test_resume_reads_the_last_committed_remote_cursor(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    imported = b"__CURSOR=s=hub;i=99\n__REALTIME_TIMESTAMP=2000000\nREMOTE_SOURCE_CURSOR=s=source;i=7\nMESSAGE=hello\n\n"
    monkeypatch.setattr(
        journal_pull.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=imported),
    )
    assert journal_pull.last_committed_entry(tmp_path) == journal_pull.ResumePoint(
        "s=source;i=7", 2000000
    )
    config = {
        "url": "https://192.0.2.1:19531",
        "server_certificate": "/server.crt",
        "client_certificate": "/client.crt",
        "client_key": "/client.key",
    }
    command = journal_pull.curl_command(config, cursor="s=source;i=7", discrete=False)
    assert "Range: entries=s=source;i=7:1:" in command
    assert "Range: entries=" in journal_pull.curl_command(
        config, cursor=None, discrete=False, from_head=True
    )
    assert "Range: entries=s=source;i=7" in journal_pull.curl_command(
        config, cursor="s=source;i=7", discrete=False, include_cursor=True
    )


def test_lost_cursor_starts_at_head_with_gap_recovery(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    config = {
        "url": "https://192.0.2.1:19531",
        "server_certificate": "/server.crt",
        "client_certificate": "/client.crt",
        "client_key": "$CREDENTIALS_DIRECTORY/client.key",
        "output_directory": str(tmp_path),
        "output_file": str(tmp_path / "source.journal"),
        "host": "mail",
        "gap_metric_file": str(tmp_path / "gaps.prom"),
    }
    monkeypatch.setattr(
        journal_pull,
        "last_committed_entry",
        lambda _directory: journal_pull.ResumePoint("s=lost;i=1", 1000000),
    )
    monkeypatch.setattr(
        journal_pull.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=b""),
    )
    commands = []
    monkeypatch.setattr(
        journal_pull.subprocess,
        "Popen",
        lambda argv, **_kwargs: commands.append(argv) or object(),
    )
    captured = {}
    monkeypatch.setattr(
        journal_pull, "supervise", lambda *_args, **kwargs: captured.update(kwargs) or 0
    )
    assert journal_pull.run(config, threading.Event()) == 0
    assert "Range: entries=" in commands[0]
    assert captured["recovery"] == journal_pull.GapRecovery(
        "mail", "s=lost;i=1", 1000000, tmp_path / "gaps.prom"
    )


def test_pending_gap_marker_replays_its_first_source_entry(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    config = {
        "url": "https://192.0.2.1:19531",
        "server_certificate": "/server.crt",
        "client_certificate": "/client.crt",
        "client_key": "$CREDENTIALS_DIRECTORY/client.key",
        "output_directory": str(tmp_path),
        "output_file": str(tmp_path / "source.journal"),
        "host": "mail",
        "gap_metric_file": str(tmp_path / "gaps.prom"),
    }
    monkeypatch.setattr(
        journal_pull,
        "last_committed_entry",
        lambda _directory: journal_pull.ResumePoint("lost", 1000000, "first", "gap1"),
    )
    monkeypatch.setattr(journal_pull, "require_source_cursor", lambda *_args: None)
    commands = []
    monkeypatch.setattr(
        journal_pull.subprocess,
        "Popen",
        lambda argv, **_kwargs: commands.append(argv) or object(),
    )
    captured = {}
    monkeypatch.setattr(
        journal_pull,
        "supervise",
        lambda *_args, **kwargs: captured.update(kwargs) or 0,
    )
    assert journal_pull.run(config, threading.Event()) == 0
    assert "Range: entries=first" in commands[0]
    assert captured["expected_first_cursor"] == "first"
    assert captured["pending_gap_id"] == "gap1"


def test_realtime_timestamp_and_pending_marker(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    entry = journal_pull.read_entry(BytesIO(export_entry()))
    assert entry is not None
    assert journal_pull.realtime_usec(entry) == 2000000
    with pytest.raises(journal_pull.JournalPullError, match="invalid"):
        journal_pull.realtime_usec(
            journal_pull.read_entry(BytesIO(b"__REALTIME_TIMESTAMP=no\n\n"))
        )
    marker = (
        b"__REALTIME_TIMESTAMP=1500000\nREMOTE_SOURCE_CURSOR=lost\n"
        b"GAP_FIRST_CURSOR=first\nGAP_ID=gap1\nGAP_LAST_REALTIME_USEC=1000000\n\n"
    )
    monkeypatch.setattr(
        journal_pull.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=marker),
    )
    assert journal_pull.last_committed_entry(tmp_path) == journal_pull.ResumePoint(
        "lost", 1000000, "first", "gap1"
    )


def test_gap_marker_contains_recovery_fields_and_midpoint(tmp_path: Path) -> None:
    first = journal_pull.read_entry(BytesIO(export_entry(b"first")))
    assert first is not None
    marker = journal_pull.gap_marker(
        journal_pull.GapRecovery("mail", "lost", 1000000, tmp_path / "gaps.prom"), first
    )
    entry = journal_pull.read_entry(BytesIO(marker.data))
    assert entry is not None
    assert journal_pull.one_field(entry, b"__REALTIME_TIMESTAMP") == b"1500000"
    for name, value in {
        b"SYSLOG_IDENTIFIER": b"journal-pull",
        b"PRIORITY": b"4",
        b"GAP_HOST": b"mail",
        b"GAP_SAVED_CURSOR": b"lost",
        b"GAP_FIRST_CURSOR": b"first",
        b"REMOTE_SOURCE_CURSOR": b"lost",
    }.items():
        assert journal_pull.one_field(entry, name) == value
    assert b"mail" in journal_pull.one_field(entry, b"MESSAGE")
    assert b"unknown" in journal_pull.one_field(entry, b"MESSAGE")


def test_counter_atomic_write_persists_and_deduplicates(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    original_replace = journal_pull.os.replace
    calls = []

    def replace(source, target):
        assert metric.read_text().endswith(f" {len(calls)}\n")
        calls.append((source, target))
        original_replace(source, target)

    monkeypatch.setattr(journal_pull.os, "replace", replace)
    assert journal_pull.increment_gap_counter(metric, "mail", "gap1") == 1
    assert calls and calls[0][1] == metric
    assert journal_pull.increment_gap_counter(metric, "mail", "gap1") == 1
    assert journal_pull.increment_gap_counter(metric, "mail", "gap2") == 2
    assert metric.read_text().endswith('journal_pull_gaps_total{host="mail"} 2\n')


@pytest.mark.parametrize(
    ("cursors", "expected"),
    [
        ([b"saved", b"next"], [b"next"]),
        ([b"other", b"saved"], [b"other", b"saved"]),
        ([b"saved", b"saved"], [b"saved"]),
    ],
)
def test_pump_only_drops_matching_leading_cursor(cursors, expected) -> None:
    source = BytesIO(b"".join(export_entry(cursor) for cursor in cursors))
    sink = InspectableBytesIO()
    state = journal_pull.PumpState(threading.Event())
    journal_pull.pump_entries(source, sink, state, resume_cursor="saved")
    assert state.error is None
    output = BytesIO(sink.getvalue())
    found = []
    while (entry := journal_pull.read_entry(output)) is not None:
        found.append(journal_pull.one_field(entry, b"REMOTE_SOURCE_CURSOR"))
    assert found == expected


def test_pump_recovery_writes_marker_before_first_entry(tmp_path: Path) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    sink = InspectableBytesIO()
    state = journal_pull.PumpState(threading.Event())
    recovery = journal_pull.GapRecovery("mail", "lost", 1000000, metric)
    journal_pull.pump_entries(
        BytesIO(export_entry(b"first")), sink, state, recovery=recovery
    )
    assert state.error is None
    stream = BytesIO(sink.getvalue())
    marker = journal_pull.read_entry(stream)
    first = journal_pull.read_entry(stream)
    assert marker is not None and first is not None
    assert journal_pull.one_field(marker, b"GAP_FIRST_CURSOR") == b"first"
    assert journal_pull.one_field(first, b"REMOTE_SOURCE_CURSOR") == b"first"
    assert 'journal_pull_gaps_total{host="mail"} 1' in metric.read_text()


def test_pump_pending_marker_replays_first_and_reconciles_counter(
    tmp_path: Path,
) -> None:
    metric = tmp_path / "gaps.prom"
    metric.write_text('journal_pull_gaps_total{host="mail"} 0\n')
    sink = InspectableBytesIO()
    state = journal_pull.PumpState(threading.Event())
    journal_pull.pump_entries(
        BytesIO(export_entry(b"first")),
        sink,
        state,
        resume_cursor="lost",
        expected_first_cursor="first",
        pending_gap_id="gap1",
        metric_file=metric,
        host="mail",
    )
    assert state.error is None
    assert b"REMOTE_SOURCE_CURSOR=first" in sink.getvalue()
    assert 'journal_pull_gaps_total{host="mail"} 1' in metric.read_text()


def test_client_key_only_resolves_from_systemd_credential(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    config = {"client_key": "$CREDENTIALS_DIRECTORY/client.key"}
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(tmp_path))
    assert journal_pull.with_client_credential(config)["client_key"] == str(
        tmp_path / "client.key"
    )
    monkeypatch.delenv("CREDENTIALS_DIRECTORY")
    with pytest.raises(journal_pull.JournalPullError, match="did not provide"):
        journal_pull.with_client_credential(config)
    with pytest.raises(journal_pull.JournalPullError, match="must come"):
        journal_pull.with_client_credential(
            {"client_key": "/etc/journal_pull/client.key"}
        )


def python_child(code: str, *, stdin: bool = False) -> subprocess.Popen[bytes]:
    return subprocess.Popen(
        [sys.executable, "-c", code],
        stdin=subprocess.PIPE if stdin else None,
        stdout=None if stdin else subprocess.PIPE,
    )


def test_importer_failure_is_nonzero_and_closes_curl() -> None:
    curl = python_child("import time; time.sleep(20)")
    importer = python_child("raise SystemExit(7)", stdin=True)
    with pytest.raises(journal_pull.JournalPullError, match="journal-remote exited"):
        journal_pull.supervise(curl, importer, threading.Event())
    assert curl.poll() is not None
    assert importer.returncode == 7


def test_stream_end_is_nonzero_and_closes_importer() -> None:
    curl = python_child(
        "import sys; sys.stdout.buffer.write(b'__CURSOR=s=x;i=1\\nMESSAGE=end\\n\\n')"
    )
    importer = python_child("import sys; sys.stdin.buffer.read()", stdin=True)
    with pytest.raises(journal_pull.JournalPullError, match="stream ended"):
        journal_pull.supervise(curl, importer, threading.Event())
    assert curl.poll() is not None
    assert importer.poll() is not None


def test_stop_signal_is_clean_and_closes_both_children() -> None:
    curl = python_child("import time; time.sleep(20)")
    importer = python_child("import sys; sys.stdin.buffer.read()", stdin=True)
    stopped = threading.Event()
    old_handler = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, lambda _number, _frame: stopped.set())
    try:
        timer = threading.Timer(0.2, lambda: signal.raise_signal(signal.SIGTERM))
        timer.start()
        assert journal_pull.supervise(curl, importer, stopped) == 0
        timer.join(timeout=2)
    finally:
        signal.signal(signal.SIGTERM, old_handler)
    assert curl.poll() is not None
    assert importer.poll() is not None
