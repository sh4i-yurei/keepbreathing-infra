#!/usr/bin/python3
"""Podman's shell secret driver: keep each secret's OpenBao path, and look its value up.

Usage: openbao-podman-secret store|lookup|delete|list

Podman runs each command with SECRET_ID set to the secret's 25-character hex ID, except list.
store takes the secret's data on standard input, which must be an OpenBao path
<consumer>/<name>, and keeps it in .config/openbao/podman-secrets/<SECRET_ID> under the account's
home from the password database. lookup hands that path to openbao-read, whose output, errors
and exit status go straight back to Podman. delete removes the file, and list prints the IDs.
Every failure is one line on standard error and exit status 1, and no line holds a path or a
value; only lookup prints a value, and openbao-read prints it (OpenBao on the hub decision 62).
"""

import os
import pwd
import re
import sys
import tempfile
from pathlib import Path

PROGRAM = "openbao-podman-secret"
SECRET_ID = re.compile(r"[0-9a-f]{25}")
# Decision 58's <consumer>/<name>. Standard input is matched as bytes, so a trailing newline or
# text that isn't UTF-8 is refused like any other wrong shape.
OPENBAO_PATH = re.compile(rb"[a-z][a-z0-9-]*/[a-z][a-z0-9-]*")
FOLDER = ".config/openbao/podman-secrets"
OPENBAO_READ = "/usr/local/bin/openbao-read"


class Failure(Exception):
    """A failure whose message is the one line written to standard error."""


def secret_id():
    """The ID Podman set, which names the secret's file, so it must be exactly an ID."""
    value = os.environ.get("SECRET_ID")
    if value is None or SECRET_ID.fullmatch(value) is None:
        raise Failure(f"{PROGRAM}: SECRET_ID must be 25 lowercase hex characters")
    return value


def folder():
    """The calling account's folder of paths, in its home from the password database."""
    uid = os.getuid()
    try:
        home = pwd.getpwuid(uid).pw_dir
    except KeyError:
        raise Failure(f"{PROGRAM}: no home for uid {uid}") from None
    return Path(home) / FOLDER


def store():
    name = secret_id()
    path = sys.stdin.buffer.read()
    if OPENBAO_PATH.fullmatch(path) is None:
        raise Failure(
            f"{PROGRAM}: store needs <consumer>/<name>, each matching ^[a-z][a-z0-9-]*$"
        )
    paths = folder()
    paths.mkdir(mode=0o700, parents=True, exist_ok=True)
    # A new file of mode 0600 beside the old one, renamed over it, so the ID's file always holds
    # one whole path. Its random name never matches an ID, so list never shows it.
    descriptor, temporary = tempfile.mkstemp(dir=paths)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(path)
        os.replace(temporary, paths / name)
    except BaseException:
        os.unlink(temporary)
        raise


def lookup():
    name = secret_id()
    try:
        path = (folder() / name).read_bytes()
    except FileNotFoundError:
        raise Failure(f"{PROGRAM}: no secret stored for {name}") from None
    # openbao-read replaces this process, so its output, errors and exit status are Podman's.
    os.execv(OPENBAO_READ, ["openbao-read", os.fsdecode(path)])


def delete():
    name = secret_id()
    # Already gone counts as deleted, so podman secret rm never strands a secret.
    (folder() / name).unlink(missing_ok=True)


def list_ids():
    try:
        names = os.listdir(folder())
    except FileNotFoundError:
        return
    sys.stdout.write(
        "".join(f"{name}\n" for name in sorted(names) if SECRET_ID.fullmatch(name))
    )


COMMANDS = {"store": store, "lookup": lookup, "delete": delete, "list": list_ids}


def main(argv):
    try:
        if len(argv) != 1 or argv[0] not in COMMANDS:
            raise Failure(f"{PROGRAM}: usage: {PROGRAM} store|lookup|delete|list")
        command = argv[0]
        try:
            COMMANDS[command]()
        except OSError as error:
            # strerror alone: the error's full text names the file, and no line prints a path.
            raise Failure(f"{PROGRAM}: {command} failed: {error.strerror}") from None
    except Failure as failure:
        print(failure, file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - every failure must end as one line
        # Another error's text can hold what the program was handling, and a traceback runs to
        # many lines, so only its class is named.
        print(f"{PROGRAM}: unexpected error: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":  # pragma: no branch - importing does not run the CLI
    sys.exit(main(sys.argv[1:]))
