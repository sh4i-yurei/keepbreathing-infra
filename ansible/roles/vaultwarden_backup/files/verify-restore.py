#!/usr/bin/env python3
"""Check the public restore artifacts against Vaultwarden's live files."""

import filecmp
import json
import re
import sqlite3
import sys
from pathlib import Path

EXCLUDED = {"db.sqlite3", "db.sqlite3-wal", "db.sqlite3-shm"}
EXCLUDED_DIRS = {"icon_cache", "tmp"}
COPY_NAME = re.compile(r"db_\d{8}_\d{6}\.sqlite3\Z")


def counts(path):
    with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
        return {
            table: db.execute(f"SELECT count(*) FROM {table}").fetchone()[0]
            for table in ("users", "ciphers", "attachments")
        }


def files(folder):
    return {p.relative_to(folder): p for p in folder.rglob("*") if p.is_file()}


def compare(live_data, restored_data, live_quadlet, restored_quadlet, expected):
    copies = [p for p in restored_data.iterdir() if COPY_NAME.fullmatch(p.name)]
    if len(copies) != 1:
        raise ValueError(
            f"counts check failed: expected one database copy, found {len(copies)}"
        )
    actual = counts(copies[0])
    if actual != expected:
        raise ValueError(
            f"counts check failed: live counts {expected}, restored counts {actual}; "
            "the vault may have changed between checks, so rerun the play"
        )

    restored = files(restored_data)
    if any(
        p.name in EXCLUDED or any(part in EXCLUDED_DIRS for part in p.parts)
        for p in restored
    ):
        raise ValueError(
            "attachments and files check failed: an excluded path was restored"
        )
    restored.pop(copies[0].relative_to(restored_data))
    live = {
        relative: path
        for relative, path in files(live_data).items()
        if relative.name not in EXCLUDED
        and not COPY_NAME.fullmatch(relative.name)
        and not any(part in EXCLUDED_DIRS for part in relative.parts)
    }
    if live.keys() != restored.keys():
        missing = sorted(str(p) for p in live.keys() - restored.keys())
        extra = sorted(str(p) for p in restored.keys() - live.keys())
        raise ValueError(
            f"attachments and files check failed: missing {missing}, extra {extra}"
        )
    for relative in live:
        if not filecmp.cmp(live[relative], restored[relative], shallow=False):
            raise ValueError(f"attachments and files check failed: {relative} differs")
    if not filecmp.cmp(live_quadlet, restored_quadlet, shallow=False):
        raise ValueError("attachments and files check failed: Quadlet differs")


def image(quadlet):
    values = [
        line.removeprefix("Image=").strip()
        for line in quadlet.read_text().splitlines()
        if line.startswith("Image=")
    ]
    if len(values) != 1 or not values[0]:
        raise ValueError(
            "restored server check failed: Quadlet has no single Image= line"
        )
    return values[0]


def prepare(restored_data):
    copies = [p for p in restored_data.iterdir() if COPY_NAME.fullmatch(p.name)]
    if len(copies) != 1:
        raise ValueError("restored server check failed: expected one database copy")
    copies[0].rename(restored_data / "db.sqlite3")


if __name__ == "__main__":
    try:
        if sys.argv[1] == "counts":
            print(json.dumps(counts(Path(sys.argv[2])), sort_keys=True))
        elif sys.argv[1] == "compare":
            compare(
                Path(sys.argv[2]),
                Path(sys.argv[3]),
                Path(sys.argv[4]),
                Path(sys.argv[5]),
                json.loads(sys.argv[6]),
            )
            print("restore files and counts match")
        elif sys.argv[1] == "image":
            print(image(Path(sys.argv[2])))
        elif sys.argv[1] == "prepare":
            prepare(Path(sys.argv[2]))
        else:
            raise ValueError("expected counts, compare, image or prepare")
    except (OSError, sqlite3.Error, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
