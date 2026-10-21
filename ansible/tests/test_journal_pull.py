"""Journal export fidelity, cursor resume and child failure tests."""

from __future__ import annotations

from io import BytesIO
import importlib.util
from pathlib import Path
import signal
import struct
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

import pytest


SCRIPT = Path(__file__).parents[1] / "roles/hub/files/journal-pull.py"
SPEC = importlib.util.spec_from_file_location("journal_pull", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
journal_pull = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = journal_pull
SPEC.loader.exec_module(journal_pull)


def export_entry(cursor: bytes = b"s=source;i=7") -> bytes:
    return b"__CURSOR=" + cursor + b"\nMESSAGE=hello\n\n"


def test_text_fields_are_preserved_with_only_the_added_cursor() -> None:
    original = export_entry()
    parsed = journal_pull.read_entry(BytesIO(original))
    assert parsed is not None
    assert parsed.raw == original
    assert journal_pull.add_source_cursor(parsed) == (
        b"__CURSOR=s=source;i=7\nMESSAGE=hello\nREMOTE_SOURCE_CURSOR=s=source;i=7\n\n"
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
    imported = (
        b"__CURSOR=s=hub;i=99\nREMOTE_SOURCE_CURSOR=s=source;i=7\nMESSAGE=hello\n\n"
    )
    monkeypatch.setattr(
        journal_pull.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=imported),
    )
    assert journal_pull.last_committed_cursor(tmp_path) == "s=source;i=7"
    config = {
        "url": "https://192.0.2.1:19531",
        "server_certificate": "/server.crt",
        "client_certificate": "/client.crt",
        "client_key": "/client.key",
    }
    command = journal_pull.curl_command(config, cursor="s=source;i=7", discrete=False)
    assert "Range: entries=s=source;i=7:1:" in command


def test_lost_cursor_fails_before_starting_children(
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
    }
    monkeypatch.setattr(
        journal_pull, "last_committed_cursor", lambda _directory: "s=lost;i=1"
    )
    monkeypatch.setattr(
        journal_pull.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=b""),
    )
    monkeypatch.setattr(
        journal_pull.subprocess,
        "Popen",
        lambda *args, **kwargs: pytest.fail("the children started with a lost cursor"),
    )
    with pytest.raises(journal_pull.CursorLost):
        journal_pull.run(config, threading.Event())


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
