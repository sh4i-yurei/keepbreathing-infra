#!/usr/bin/python3
"""Pull one journal over mutual TLS and preserve source cursors during import."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import signal
import struct
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path
from typing import BinaryIO

FIELD_NAME = re.compile(rb"[A-Z_][A-Z0-9_]*\Z")
MAX_FIELD_BYTES = 256 * 1024 * 1024
REMOTE_CURSOR_FIELD = b"REMOTE_SOURCE_CURSOR"
SOURCE_CURSOR_FIELD = b"__CURSOR"
REALTIME_FIELD = b"__REALTIME_TIMESTAMP"
GAP_IDENTIFIER = b"journal-pull"


class JournalPullError(Exception):
    """The source or importer cannot be continued without losing fidelity."""


class CursorLost(JournalPullError):
    """The saved cursor is no longer in the source journal."""


@dataclass(frozen=True)
class Field:
    name: bytes
    value: bytes


@dataclass(frozen=True)
class Entry:
    fields: tuple[Field, ...]
    raw: bytes


@dataclass(frozen=True)
class ResumePoint:
    cursor: str
    realtime_usec: int
    pending_first_cursor: str | None = None
    pending_gap_id: str | None = None


@dataclass(frozen=True)
class GapRecovery:
    host: str
    saved_cursor: str
    last_realtime_usec: int
    metric_file: Path


@dataclass(frozen=True)
class GapMarker:
    data: bytes
    first_cursor: str
    gap_id: str


def read_entry(stream: BinaryIO) -> Entry | None:
    """Read one complete Journal Export Format entry, including binary fields."""
    fields: list[Field] = []
    raw = bytearray()
    while True:
        line = stream.readline(MAX_FIELD_BYTES + 1)
        if not line:
            if raw:
                raise JournalPullError("truncated journal export entry")
            return None
        if len(line) > MAX_FIELD_BYTES or not line.endswith(b"\n"):
            raise JournalPullError("journal export field is too large or truncated")
        raw.extend(line)
        if line == b"\n":
            if not fields:
                raise JournalPullError("empty journal export entry")
            return Entry(tuple(fields), bytes(raw))

        body = line[:-1]
        if b"=" in body:
            name, value = body.split(b"=", 1)
            if not FIELD_NAME.fullmatch(name):
                raise JournalPullError("invalid text field name")
            fields.append(Field(name, value))
            continue

        name = body
        if not FIELD_NAME.fullmatch(name):
            raise JournalPullError("invalid binary field name")
        length_bytes = read_exactly(stream, 8)
        if len(length_bytes) != 8:
            raise JournalPullError("truncated binary field length")
        length = struct.unpack("<Q", length_bytes)[0]
        if length > MAX_FIELD_BYTES:
            raise JournalPullError("binary journal field exceeds the 256 MiB limit")
        value = read_exactly(stream, length)
        separator = read_exactly(stream, 1)
        if len(value) != length or separator != b"\n":
            raise JournalPullError("truncated or malformed binary journal field")
        raw.extend(length_bytes)
        raw.extend(value)
        raw.extend(separator)
        fields.append(Field(name, value))


def read_exactly(stream: BinaryIO, length: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < length:
        chunk = stream.read(length - len(chunks))
        if not chunk:
            break
        chunks.extend(chunk)
    return bytes(chunks)


def one_field(entry: Entry, name: bytes) -> bytes:
    values = [field.value for field in entry.fields if field.name == name]
    if len(values) != 1:
        raise JournalPullError(f"expected one {name.decode('ascii')} field")
    return values[0]


def cursor_text(value: bytes) -> str:
    if not value or any(byte < 33 or byte > 126 for byte in value):
        raise JournalPullError("journal cursor contains invalid characters")
    return value.decode("ascii")


def realtime_usec(entry: Entry, field: bytes = REALTIME_FIELD) -> int:
    value = one_field(entry, field)
    if not value.isdigit():
        raise JournalPullError(f"invalid {field.decode('ascii')} field")
    timestamp = int(value)
    if timestamp <= 0:
        raise JournalPullError(f"invalid {field.decode('ascii')} field")
    return timestamp


def add_source_cursor(entry: Entry) -> bytes:
    """Keep the original entry byte-for-byte and insert its source cursor field."""
    if any(field.name == REMOTE_CURSOR_FIELD for field in entry.fields):
        raise JournalPullError("source tried to supply REMOTE_SOURCE_CURSOR")
    cursor = one_field(entry, SOURCE_CURSOR_FIELD)
    cursor_text(cursor)
    return entry.raw[:-1] + REMOTE_CURSOR_FIELD + b"=" + cursor + b"\n\n"


def last_committed_entry(directory: Path) -> ResumePoint | None:
    """Read the last imported source cursor, including a pending gap marker."""
    command = [
        "journalctl",
        f"--directory={directory}",
        "--reverse",
        "--lines=1",
        "--output=export",
        "--no-pager",
        "--quiet",
    ]
    result = subprocess.run(command, capture_output=True, check=False)
    if result.returncode != 0:
        if not list(directory.glob("*.journal*")):
            return None
        raise JournalPullError("journalctl could not read the imported journal")
    entry = read_entry(BytesIO(result.stdout))
    if entry is None:
        return None
    cursor = cursor_text(one_field(entry, REMOTE_CURSOR_FIELD))
    if any(field.name == b"GAP_FIRST_CURSOR" for field in entry.fields):
        return ResumePoint(
            cursor,
            realtime_usec(entry, b"GAP_LAST_REALTIME_USEC"),
            cursor_text(one_field(entry, b"GAP_FIRST_CURSOR")),
            cursor_text(one_field(entry, b"GAP_ID")),
        )
    return ResumePoint(cursor, realtime_usec(entry))


def curl_command(
    config: dict[str, str],
    *,
    cursor: str | None,
    discrete: bool,
    include_cursor: bool = False,
    from_head: bool = False,
) -> list[str]:
    command = [
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
        config["server_certificate"],
        "--cert",
        config["client_certificate"],
        "--key",
        config["client_key"],
        "--header",
        "Accept: application/vnd.fdo.journal",
    ]
    if discrete:
        if cursor is None:
            raise ValueError("a discrete request needs a cursor")
        command.extend(["--max-time", "20", "--header", f"Range: entries={cursor}"])
        command.append(config["url"] + "/entries?discrete")
    else:
        if cursor is not None:
            suffix = "" if include_cursor else ":1:"
            command.extend(["--header", f"Range: entries={cursor}{suffix}"])
        elif from_head:
            command.extend(["--header", "Range: entries="])
        command.append(config["url"] + "/entries?follow")
    return command


def require_source_cursor(config: dict[str, str], cursor: str) -> None:
    """A discrete seek must return the exact saved entry, never a nearby one."""
    result = subprocess.run(
        curl_command(config, cursor=cursor, discrete=True),
        capture_output=True,
        check=False,
        timeout=25,
    )
    if result.returncode != 0:
        raise JournalPullError("source cursor check could not reach the gateway")
    entry = read_entry(BytesIO(result.stdout))
    if entry is None or cursor_text(one_field(entry, SOURCE_CURSOR_FIELD)) != cursor:
        raise CursorLost("saved source cursor has rotated away")
    if read_entry(BytesIO(result.stdout[len(entry.raw) :])) is not None:
        raise JournalPullError("discrete cursor check returned more than one entry")


@dataclass
class PumpState:
    done: threading.Event
    error: Exception | None = None


def gap_marker(recovery: GapRecovery, first: Entry) -> GapMarker:
    """Build one dated journal entry before the oldest available source entry."""
    first_cursor = cursor_text(one_field(first, SOURCE_CURSOR_FIELD))
    first_usec = realtime_usec(first)
    last_usec = recovery.last_realtime_usec
    # journal-remote imports __REALTIME_TIMESTAMP. A gap of at least two
    # microseconds permits a strict midpoint; adjacent timestamps use the
    # first entry's time and keep the marker before it in import order.
    marker_usec = (
        last_usec + (first_usec - last_usec) // 2
        if first_usec - last_usec >= 2
        else first_usec
    )

    def utc_text(usec: int) -> str:
        return (
            datetime.fromtimestamp(usec // 1_000_000, timezone.utc)
            .replace(microsecond=usec % 1_000_000)
            .isoformat()
        )

    gap_id = hashlib.sha256(
        f"{recovery.host}\0{recovery.saved_cursor}\0{first_cursor}".encode()
    ).hexdigest()[:16]
    message = (
        f"Logs from {recovery.host} were lost between {utc_text(last_usec)} "
        f"and {utc_text(first_usec)}; the number of missing entries is unknown. "
        f"The hub resumed from the oldest available entry. gap_id={gap_id}"
    )
    fields = (
        (b"__REALTIME_TIMESTAMP", str(marker_usec).encode("ascii")),
        (b"SYSLOG_IDENTIFIER", GAP_IDENTIFIER),
        (b"PRIORITY", b"4"),
        (b"MESSAGE", message.encode("utf-8")),
        (b"GAP_HOST", recovery.host.encode("ascii")),
        (b"GAP_ID", gap_id.encode("ascii")),
        (b"GAP_SAVED_CURSOR", recovery.saved_cursor.encode("ascii")),
        (b"GAP_FIRST_CURSOR", first_cursor.encode("ascii")),
        (b"GAP_LAST_REALTIME_USEC", str(last_usec).encode("ascii")),
        (b"GAP_FIRST_REALTIME_USEC", str(first_usec).encode("ascii")),
        # This is the last source cursor committed before the marker. If the
        # importer stops here, the next run can find and replay first_cursor.
        (REMOTE_CURSOR_FIELD, recovery.saved_cursor.encode("ascii")),
    )
    data = b"".join(name + b"=" + value + b"\n" for name, value in fields) + b"\n"
    return GapMarker(data, first_cursor, gap_id)


def increment_gap_counter(metric_file: Path, host: str, gap_id: str) -> int:
    """Atomically replace one host's persistent textfile counter."""
    sample = f'journal_pull_gaps_total{{host="{host}"}}'
    lines = metric_file.read_text(encoding="utf-8").splitlines()
    values = [
        line.removeprefix(sample + " ")
        for line in lines
        if line.startswith(sample + " ")
    ]
    if len(values) != 1 or not values[0].isdigit():
        raise JournalPullError(f"invalid gap counter for {host}")
    if f"# last_gap_id {gap_id}" in lines:
        return int(values[0])
    count = int(values[0]) + 1
    pending: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=metric_file.parent,
            prefix=".journal-pull-gaps-",
            delete=False,
        ) as temporary:
            pending = Path(temporary.name)
            temporary.write(
                "# HELP journal_pull_gaps_total Number of source journal gaps recovered by the hub.\n"
                "# TYPE journal_pull_gaps_total counter\n"
                f"# last_gap_id {gap_id}\n"
                f"{sample} {count}\n"
            )
            temporary.flush()
            os.fchmod(temporary.fileno(), 0o640)
            os.fsync(temporary.fileno())
        os.replace(pending, metric_file)
        pending = None
        directory_fd = os.open(metric_file.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if pending is not None:
            pending.unlink(missing_ok=True)
    return count


def pump_entries(
    source: BinaryIO,
    sink: BinaryIO,
    state: PumpState,
    *,
    resume_cursor: str | None = None,
    recovery: GapRecovery | None = None,
    expected_first_cursor: str | None = None,
    pending_gap_id: str | None = None,
    metric_file: Path | None = None,
    host: str | None = None,
) -> None:
    try:
        first = True
        while (entry := read_entry(source)) is not None:
            if first:
                first = False
                source_cursor = cursor_text(one_field(entry, SOURCE_CURSOR_FIELD))
                if recovery is not None:
                    marker = gap_marker(recovery, entry)
                    sink.write(marker.data)
                    sink.flush()
                    increment_gap_counter(
                        recovery.metric_file, recovery.host, marker.gap_id
                    )
                elif (
                    expected_first_cursor is not None
                    and source_cursor != expected_first_cursor
                ):
                    raise JournalPullError(
                        "the first entry after a gap changed before replay"
                    )
                elif pending_gap_id is not None:
                    assert metric_file is not None and host is not None
                    increment_gap_counter(metric_file, host, pending_gap_id)
                elif resume_cursor is not None and source_cursor == resume_cursor:
                    continue
            sink.write(add_source_cursor(entry))
            sink.flush()
    except Exception as error:
        state.error = error
    finally:
        try:
            sink.close()
        except OSError:
            pass
        state.done.set()


def stop_child(child: subprocess.Popen[bytes]) -> None:
    if child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)


def supervise(
    curl: subprocess.Popen[bytes],
    importer: subprocess.Popen[bytes],
    stopped: threading.Event,
    *,
    resume_cursor: str | None = None,
    recovery: GapRecovery | None = None,
    expected_first_cursor: str | None = None,
    pending_gap_id: str | None = None,
    metric_file: Path | None = None,
    host: str | None = None,
) -> int:
    if curl.stdout is None or importer.stdin is None:
        raise JournalPullError("children did not provide their journal stream pipes")
    state = PumpState(threading.Event())
    worker = threading.Thread(
        target=pump_entries,
        args=(curl.stdout, importer.stdin, state),
        kwargs={
            "resume_cursor": resume_cursor,
            "recovery": recovery,
            "expected_first_cursor": expected_first_cursor,
            "pending_gap_id": pending_gap_id,
            "metric_file": metric_file,
            "host": host,
        },
        daemon=True,
    )
    worker.start()
    try:
        while not stopped.wait(0.1):
            if (
                state.done.is_set()
                or curl.poll() is not None
                or importer.poll() is not None
            ):
                break
        if stopped.is_set():
            return 0
        if state.error is not None:
            raise JournalPullError(f"journal stream failed: {state.error}")
        if state.done.is_set():
            raise JournalPullError(
                "gateway journal stream ended without a stop request"
            )
        if importer.poll() is not None:
            raise JournalPullError(f"journal-remote exited with {importer.returncode}")
        if curl.poll() is not None and curl.returncode != 0:
            raise JournalPullError(f"curl exited with {curl.returncode}")
        raise JournalPullError("gateway journal stream ended without a stop request")
    finally:
        stop_child(curl)
        stop_child(importer)
        worker.join(timeout=5)
        curl.stdout.close()


def with_client_credential(config: dict[str, str]) -> dict[str, str]:
    """Resolve the only secret path from systemd's private credential directory."""
    credential_prefix = "$CREDENTIALS_DIRECTORY/"
    if not config["client_key"].startswith(credential_prefix):
        raise JournalPullError("client key must come from a systemd credential")
    credentials_directory = os.environ.get("CREDENTIALS_DIRECTORY")
    if not credentials_directory:
        raise JournalPullError("systemd did not provide CREDENTIALS_DIRECTORY")
    resolved = dict(config)
    resolved["client_key"] = str(
        Path(credentials_directory) / config["client_key"][len(credential_prefix) :]
    )
    return resolved


def run(config: dict[str, str], stopped: threading.Event) -> int:
    config = with_client_credential(config)
    directory = Path(config["output_directory"])
    point = last_committed_entry(directory)
    if stopped.is_set():
        return 0
    cursor = point.cursor if point is not None else None
    recovery: GapRecovery | None = None
    expected_first_cursor: str | None = None
    if point is not None:
        wanted_cursor = point.pending_first_cursor or point.cursor
        try:
            require_source_cursor(config, wanted_cursor)
        except CursorLost:
            recovery = GapRecovery(
                config["host"],
                point.cursor,
                point.realtime_usec,
                Path(config["gap_metric_file"]),
            )
            cursor = None
        else:
            if point.pending_first_cursor is not None:
                cursor = point.pending_first_cursor
                expected_first_cursor = cursor
    if stopped.is_set():
        return 0

    curl = subprocess.Popen(
        curl_command(
            config,
            cursor=cursor,
            discrete=False,
            include_cursor=expected_first_cursor is not None,
            from_head=recovery is not None,
        ),
        stdout=subprocess.PIPE,
    )
    try:
        importer = subprocess.Popen(
            [
                "/usr/lib/systemd/systemd-journal-remote",
                f"--output={config['output_file']}",
                "-",
            ],
            stdin=subprocess.PIPE,
        )
    except Exception:
        stop_child(curl)
        raise
    return supervise(
        curl,
        importer,
        stopped,
        resume_cursor=point.cursor if point is not None and recovery is None else None,
        recovery=recovery,
        expected_first_cursor=expected_first_cursor,
        pending_gap_id=point.pending_gap_id
        if point is not None and recovery is None
        else None,
        metric_file=Path(config["gap_metric_file"]),
        host=config["host"],
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args()
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda _number, _frame: stopped.set())
    signal.signal(signal.SIGINT, lambda _number, _frame: stopped.set())
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        return run(config, stopped)
    except (
        JournalPullError,
        OSError,
        ValueError,
        KeyError,
        subprocess.TimeoutExpired,
    ) as error:
        if stopped.is_set():
            return 0
        print(f"journal-pull: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
