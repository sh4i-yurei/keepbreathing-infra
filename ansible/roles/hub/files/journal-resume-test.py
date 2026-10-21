#!/usr/bin/python3
"""Coordinate a live journal resume test from a source and the hub.

Run the source and hub modes in separate terminals. The vacuum mode deletes
archived source journals and requires an explicit confirmation option.
"""

from __future__ import annotations

import argparse
from collections import Counter
import json
import re
import subprocess
import sys
import time
from urllib.parse import urlencode
from urllib.request import urlopen


HOSTS = {"web", "mail", "control", "vaultserv", "almaserv"}
TAG = "journal-resume-test"


def command(*argv: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(argv, check=check, capture_output=True, text=True)


def source_markers(run_id: str, count: int, interval: float) -> None:
    for number in range(1, count + 1):
        command("logger", "--tag", TAG, f"run={run_id} seq={number:04d}")
        time.sleep(interval)


def journal_lines(host: str, run_id: str) -> list[str]:
    directory = f"/var/log/journal/remote/{host}"
    result = command(
        "journalctl",
        f"--directory={directory}",
        "--identifier",
        TAG,
        "--output=cat",
        "--no-pager",
        "--quiet",
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cannot read {host}'s imported journal")
    return [
        line
        for line in result.stdout.splitlines()
        if line.startswith(f"run={run_id} seq=")
    ]


def wait_for_count(host: str, run_id: str, minimum: int, timeout: float = 180) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = len(journal_lines(host, run_id))
        if found >= minimum:
            return found
        time.sleep(1)
    raise RuntimeError(
        f"only {len(journal_lines(host, run_id))} of {minimum} markers arrived"
    )


def hub_cycle(host: str, run_id: str, count: int) -> None:
    unit = f"journal-pull@{host}.service"
    points = sorted({max(1, count // 6), max(2, count // 3), max(3, count * 2 // 3)})
    if points[-1] >= count:
        raise ValueError(
            "at least six markers are needed for three interruption points"
        )
    for point in points:
        observed = wait_for_count(host, run_id, point)
        if observed >= count:
            raise RuntimeError("the source finished before a mid-stream interruption")
        command("systemctl", "stop", unit)
        time.sleep(2)
        command("systemctl", "start", unit)
    wait_for_count(host, run_id, count)


def marker_counts(lines: list[str], run_id: str) -> Counter[int]:
    pattern = re.compile(rf"^run={re.escape(run_id)} seq=([0-9]{{4}})$")
    return Counter(
        int(match.group(1)) for line in lines if (match := pattern.fullmatch(line))
    )


def loki_lines(host: str, run_id: str) -> list[str]:
    query = f'{{host="{host}",identifier="{TAG}"}} |= "run={run_id}"'
    url = "http://127.0.0.1:3100/loki/api/v1/query_range?" + urlencode(
        {"query": query, "since": "1h", "limit": "5000", "direction": "forward"}
    )
    with urlopen(url, timeout=20) as response:
        data = json.load(response)
    if data.get("status") != "success":
        raise RuntimeError("Loki did not complete the marker query")
    return [
        line
        for stream in data["data"]["result"]
        for _timestamp, line in stream["values"]
    ]


def verify(host: str, run_id: str, count: int) -> None:
    expected = Counter({number: 1 for number in range(1, count + 1)})
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        imported = marker_counts(journal_lines(host, run_id), run_id)
        stored = marker_counts(loki_lines(host, run_id), run_id)
        if imported == expected and stored == expected:
            print(
                f"All {count} markers occur exactly once in the imported journal and Loki."
            )
            return
        time.sleep(2)
    raise RuntimeError(
        f"markers differ: imported={imported}; loki={stored}; expected={expected}"
    )


def prepare_cursor_loss(host: str) -> None:
    command("systemctl", "stop", f"journal-pull@{host}.service")
    print(
        "Puller stopped. On the source, run source-vacuum only after confirming archive deletion."
    )


def source_vacuum(confirmed: bool) -> None:
    if not confirmed:
        raise RuntimeError(
            "source-vacuum deletes archived journals; pass --confirm-delete-archived-journals"
        )
    command("journalctl", "--rotate")
    time.sleep(2)
    command("journalctl", "--vacuum-time=1s")
    print("Archived source journals were vacuumed. Verify the puller fails on the hub.")


def verify_cursor_loss(host: str) -> None:
    unit = f"journal-pull@{host}.service"
    command("systemctl", "start", unit, check=False)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        state = command("systemctl", "is-failed", unit, check=False).stdout.strip()
        if state == "failed":
            logs = command(
                "journalctl", "--unit", unit, "--lines=100", "--no-pager"
            ).stdout
            if "saved source cursor has rotated away" not in logs:
                raise RuntimeError(
                    "the puller failed for a reason other than the lost cursor"
                )
            print(
                f"{unit} is failed after its retry limit, with the lost-cursor error recorded."
            )
            return
        time.sleep(2)
    raise RuntimeError(f"{unit} did not enter the failed state within five minutes")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subcommands = parser.add_subparsers(dest="mode", required=True)
    marker_source = subcommands.add_parser("source-markers")
    marker_source.add_argument("--run-id", required=True)
    marker_source.add_argument("--count", type=int, default=24)
    marker_source.add_argument("--interval", type=float, default=1.0)
    for mode in ("hub-cycle", "verify"):
        command_parser = subcommands.add_parser(mode)
        command_parser.add_argument("--host", choices=sorted(HOSTS), required=True)
        command_parser.add_argument("--run-id", required=True)
        command_parser.add_argument("--count", type=int, default=24)
    for mode in ("prepare-loss", "verify-loss"):
        subcommands.add_parser(mode).add_argument(
            "--host", choices=sorted(HOSTS), required=True
        )
    subcommands.add_parser("source-vacuum").add_argument(
        "--confirm-delete-archived-journals", action="store_true"
    )
    args = parser.parse_args()
    if args.mode in {"source-markers", "hub-cycle", "verify"}:
        if not args.run_id or not re.fullmatch(r"[a-zA-Z0-9-]{1,40}", args.run_id):
            parser.error("--run-id must contain 1-40 letters, digits or hyphens")
        if args.count < 6 or args.count > 5000:
            parser.error("--count must be between 6 and 5000")
    if args.mode == "source-markers" and args.interval <= 0:
        parser.error("--interval must be positive")
    try:
        if args.mode == "source-markers":
            source_markers(args.run_id, args.count, args.interval)
        elif args.mode == "hub-cycle":
            hub_cycle(args.host, args.run_id, args.count)
        elif args.mode == "verify":
            verify(args.host, args.run_id, args.count)
        elif args.mode == "prepare-loss":
            prepare_cursor_loss(args.host)
        elif args.mode == "source-vacuum":
            source_vacuum(args.confirm_delete_archived_journals)
        elif args.mode == "verify-loss":
            verify_cursor_loss(args.host)
        return 0
    except (OSError, subprocess.CalledProcessError, RuntimeError, ValueError) as error:
        print(f"journal-resume-test: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
