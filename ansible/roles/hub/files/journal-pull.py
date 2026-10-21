#!/usr/bin/python3
"""Pull one journal over mutual TLS and preserve source cursors during import."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from io import BytesIO
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import threading
from typing import BinaryIO


FIELD_NAME = re.compile(rb"[A-Z_][A-Z0-9_]*\Z")
MAX_FIELD_BYTES = 256 * 1024 * 1024
REMOTE_CURSOR_FIELD = b"REMOTE_SOURCE_CURSOR"
SOURCE_CURSOR_FIELD = b"__CURSOR"


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


def add_source_cursor(entry: Entry) -> bytes:
    """Keep the original entry byte-for-byte and insert its source cursor field."""
    if any(field.name == REMOTE_CURSOR_FIELD for field in entry.fields):
        raise JournalPullError("source tried to supply REMOTE_SOURCE_CURSOR")
    cursor = one_field(entry, SOURCE_CURSOR_FIELD)
    cursor_text(cursor)
    return entry.raw[:-1] + REMOTE_CURSOR_FIELD + b"=" + cursor + b"\n\n"


def last_committed_cursor(directory: Path) -> str | None:
    """Read the last imported entry, across the active and archived journal files."""
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
    return cursor_text(one_field(entry, REMOTE_CURSOR_FIELD))


def curl_command(
    config: dict[str, str], *, cursor: str | None, discrete: bool
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
            command.extend(["--header", f"Range: entries={cursor}:1:"])
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


def pump_entries(source: BinaryIO, sink: BinaryIO, state: PumpState) -> None:
    try:
        while (entry := read_entry(source)) is not None:
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
) -> int:
    if curl.stdout is None or importer.stdin is None:
        raise JournalPullError("children did not provide their journal stream pipes")
    state = PumpState(threading.Event())
    worker = threading.Thread(
        target=pump_entries, args=(curl.stdout, importer.stdin, state), daemon=True
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
    cursor = last_committed_cursor(directory)
    if stopped.is_set():
        return 0
    if cursor is not None:
        require_source_cursor(config, cursor)
    if stopped.is_set():
        return 0

    curl = subprocess.Popen(
        curl_command(config, cursor=cursor, discrete=False), stdout=subprocess.PIPE
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
    return supervise(curl, importer, stopped)


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
