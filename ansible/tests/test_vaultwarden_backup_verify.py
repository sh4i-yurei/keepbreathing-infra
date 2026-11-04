"""Exercise the restore verifier through its command-line interface."""

import io
import json
import os
import sqlite3
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import pytest
from load_source import load_source

verifier = load_source("ansible/roles/vaultwarden_backup/files/verify-restore.py")
SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "roles/vaultwarden_backup/files/verify-restore.py"
)


def run(*args: object) -> tuple[int, str, str]:
    output = io.StringIO()
    errors = io.StringIO()
    with redirect_stdout(output), redirect_stderr(errors):
        status = verifier.main([str(arg) for arg in args])
    return status, output.getvalue(), errors.getvalue()


def database(path: Path, *, items: int = 2) -> None:
    with sqlite3.connect(path) as db:
        for name in ("users", "ciphers", "attachments"):
            db.execute(f"CREATE TABLE {name} (id INTEGER)")
        db.execute("INSERT INTO users VALUES (1)")
        db.executemany("INSERT INTO ciphers VALUES (?)", [(i,) for i in range(items)])
        db.execute("INSERT INTO attachments VALUES (1)")


@pytest.fixture
def restore(tmp_path: Path) -> tuple[Path, Path, Path, Path, dict[str, int]]:
    live = tmp_path / "live"
    restored = tmp_path / "restored"
    live.mkdir()
    restored.mkdir()
    database(live / "db.sqlite3")
    database(restored / "db_20260101_123456.sqlite3")
    for root in (live, restored):
        (root / "attachments").mkdir()
        (root / "attachments" / "file.bin").write_bytes(b"attachment\x00contents")
        (root / "rsa_key.pem").write_text("key\n")
    live_quadlet = tmp_path / "live.container"
    restored_quadlet = tmp_path / "restored.container"
    live_quadlet.write_text("[Container]\nImage=example@sha256:abc\n")
    restored_quadlet.write_bytes(live_quadlet.read_bytes())
    return (
        live,
        restored,
        live_quadlet,
        restored_quadlet,
        {"users": 1, "ciphers": 2, "attachments": 1},
    )


def compare(
    case: tuple[Path, Path, Path, Path, dict[str, int]],
) -> tuple[int, str, str]:
    live, restored, live_quadlet, restored_quadlet, expected = case
    return run(
        "compare", live, restored, live_quadlet, restored_quadlet, json.dumps(expected)
    )


def test_counts_returns_exact_database_counts(restore) -> None:
    result = run("counts", restore[0] / "db.sqlite3")
    assert result == (
        0,
        '{"attachments": 1, "ciphers": 2, "users": 1}\n',
        "",
    )


def test_script_entrypoint_returns_counts(restore) -> None:
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "counts", str(restore[0] / "db.sqlite3")],
        capture_output=True,
        text=True,
        check=False,
    )
    assert (result.returncode, result.stdout, result.stderr) == (
        0,
        '{"attachments": 1, "ciphers": 2, "users": 1}\n',
        "",
    )


def test_compare_accepts_identical_restore(restore) -> None:
    result = compare(restore)
    assert result == (
        0,
        "restore files and counts match\n",
        "",
    )


@pytest.mark.parametrize("copies", [0, 2])
def test_compare_requires_one_database_copy(restore, copies: int) -> None:
    restored = restore[1]
    if copies == 0:
        (restored / "db_20260101_123456.sqlite3").unlink()
    else:
        database(restored / "db_20260102_123456.sqlite3")
    result = compare(restore)
    assert result == (
        1,
        "",
        f"counts check failed: expected one database copy, found {copies}\n",
    )


def test_compare_rejects_stale_database_counts(restore) -> None:
    restore[4]["ciphers"] = 3
    result = compare(restore)
    assert result[0] == 1
    assert result[1] == ""
    assert result[2] == (
        "counts check failed: live counts {'users': 1, 'ciphers': 3, 'attachments': 1}, "
        "restored counts {'users': 1, 'ciphers': 2, 'attachments': 1}; "
        "the vault may have changed between checks, so rerun the play\n"
    )


@pytest.mark.parametrize("name", ["db.sqlite3", "db.sqlite3-wal", "db.sqlite3-shm"])
def test_compare_rejects_restored_live_database_files(restore, name: str) -> None:
    (restore[1] / name).write_bytes(b"excluded")
    result = compare(restore)
    assert result == (
        1,
        "",
        "attachments and files check failed: an excluded path was restored\n",
    )


@pytest.mark.parametrize("name", ["icon_cache", "tmp"])
def test_compare_rejects_restored_excluded_file(restore, name: str) -> None:
    folder = restore[1] / name
    folder.mkdir()
    (folder / "file").write_bytes(b"excluded")
    result = compare(restore)
    assert result == (
        1,
        "",
        "attachments and files check failed: an excluded path was restored\n",
    )


@pytest.mark.parametrize(
    "change, expected",
    [
        (
            "missing",
            "attachments and files check failed: missing ['attachments/file.bin'], extra []\n",
        ),
        (
            "extra",
            "attachments and files check failed: missing [], extra ['extra.txt']\n",
        ),
    ],
)
def test_compare_rejects_missing_or_extra_file(
    restore, change: str, expected: str
) -> None:
    path = restore[1] / ("attachments/file.bin" if change == "missing" else "extra.txt")
    if change == "missing":
        path.unlink()
    else:
        path.write_text("extra")
    result = compare(restore)
    assert result == (1, "", expected)


def test_compare_rejects_attachment_byte_difference(restore) -> None:
    live = restore[0] / "attachments/file.bin"
    changed = restore[1] / "attachments/file.bin"
    changed.write_bytes(b"attachment\x00contentX")
    source_stat = live.stat()
    os.utime(changed, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
    result = compare(restore)
    assert result == (
        1,
        "",
        "attachments and files check failed: attachments/file.bin differs\n",
    )


def test_compare_rejects_quadlet_byte_difference(restore) -> None:
    restore[3].write_text("[Container]\nImage=example@sha256:abd\n")
    source_stat = restore[2].stat()
    os.utime(restore[3], ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
    result = compare(restore)
    assert result == (
        1,
        "",
        "attachments and files check failed: Quadlet differs\n",
    )


@pytest.mark.parametrize(
    "contents,expected",
    [
        ("Image=example@sha256:abc\n", "example@sha256:abc\n"),
        (
            "[Container]\n",
            "restored server check failed: Quadlet has no single Image= line\n",
        ),
        (
            "Image=\n",
            "restored server check failed: Quadlet has no single Image= line\n",
        ),
        (
            "Image=one\nImage=two\n",
            "restored server check failed: Quadlet has no single Image= line\n",
        ),
    ],
)
def test_image_reports_one_image_or_error(
    tmp_path: Path, contents: str, expected: str
) -> None:
    quadlet = tmp_path / "vaultwarden.container"
    quadlet.write_text(contents)
    result = run("image", quadlet)
    if contents == "Image=example@sha256:abc\n":
        assert result == (0, expected, "")
    else:
        assert result == (1, "", expected)


def test_prepare_renames_database_copy(restore) -> None:
    result = run("prepare", restore[1])
    assert result == (0, "", "")
    assert (restore[1] / "db.sqlite3").exists()
    assert not (restore[1] / "db_20260101_123456.sqlite3").exists()


@pytest.mark.parametrize("copies", [0, 2])
def test_prepare_requires_one_database_copy(restore, copies: int) -> None:
    if copies == 0:
        (restore[1] / "db_20260101_123456.sqlite3").unlink()
    else:
        database(restore[1] / "db_20260102_123456.sqlite3")
    result = run("prepare", restore[1])
    assert result == (
        1,
        "",
        "restored server check failed: expected one database copy\n",
    )


def test_unknown_command_reports_error() -> None:
    result = run("invalid")
    assert result == (
        1,
        "",
        "expected counts, compare, image or prepare\n",
    )
