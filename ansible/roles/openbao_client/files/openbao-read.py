#!/usr/bin/python3
"""Sign in to OpenBao as the calling account's AppRole and print one secret's value.

Usage: openbao-read [--config PATH] <consumer>/<name>

The consumer names the AppRole, whose role-id and secret-id files live under
~/.config/openbao/approle/<consumer>/ in the account's home from the password database.
The value of secret/data/<consumer>/<name> goes to standard output with no newline. Every
failure is one line on standard error and exit status 1, and no line ever holds a role ID,
secret ID, token or secret value (OpenBao on the hub decision 58).

Requests go only to the configured address: the helper ignores proxy variables in its
environment and follows no redirect, so the token can't be carried anywhere else.
"""

import argparse
import http.client
import json
import os
import pwd
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

NAME = re.compile(r"[a-z][a-z0-9-]*")
DEFAULT_CONFIG = "/etc/openbao/client.json"
# Seconds to wait on OpenBao for each connection and each read, so a stuck server fails the
# caller instead of hanging it.
TIMEOUT = 10


class Failure(Exception):
    """A failure whose message is the one line written to standard error."""


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Failure(f"openbao-read: {message}")


def one_line(text):
    return " ".join(str(text).split())


def parse_path(path):
    parts = path.split("/")
    if len(parts) != 2 or not all(NAME.fullmatch(part) for part in parts):
        raise Failure(
            "openbao-read: the path must be <consumer>/<name>, "
            "each part matching ^[a-z][a-z0-9-]*$"
        )
    return parts


def approle_files(consumer):
    """Read the consumer's role ID and secret ID from the account's own home."""
    uid = os.getuid()
    try:
        home = pwd.getpwuid(uid).pw_dir
    except KeyError:
        raise Failure(
            f"openbao-read: uid {uid} has no entry in the password database"
        ) from None
    folder = Path(home) / ".config/openbao/approle" / consumer
    try:
        return (folder / "role-id").read_text(), (folder / "secret-id").read_text()
    except (OSError, UnicodeDecodeError):
        raise Failure(
            f"openbao-read: no AppRole files for {consumer} in {folder}"
        ) from None


def read_address(config):
    try:
        address = json.loads(Path(config).read_text())["address"]
    except (OSError, ValueError, KeyError, TypeError):
        address = None
    if not isinstance(address, str):
        raise Failure(
            f"openbao-read: {config} must hold a JSON object with a string address"
        )
    return address


def opener():
    """An opener for HTTP and HTTPS only, with no proxy handler and no redirect handler.

    Any answer, a redirect included, comes back as it is, and any other scheme fails as an
    unknown url type.
    """
    director = urllib.request.OpenerDirector()
    for handler in (
        urllib.request.HTTPHandler(),
        urllib.request.HTTPSHandler(),
        urllib.request.UnknownHandler(),
    ):
        director.add_handler(handler)
    return director


def call(address, method, path, token=None, body=None):
    """Send one request and return its status and body, whatever the status."""
    headers = {}
    data = None
    if token is not None:
        headers["X-Vault-Token"] = token
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    request = urllib.request.Request(
        f"{address}/v1/{path}", data=data, headers=headers, method=method
    )
    try:
        with opener().open(request, timeout=TIMEOUT) as response:
            return response.status, response.read()
    except (OSError, http.client.HTTPException) as error:
        reason = error.reason if isinstance(error, urllib.error.URLError) else error
        raise Failure(
            f"openbao-read: could not reach OpenBao at {address}: {one_line(reason)}"
        ) from None


def described(status, body):
    """The status and OpenBao's first error, if it gave one, on one line."""
    try:
        error = json.loads(body)["errors"][0]
    except (ValueError, KeyError, IndexError, TypeError):
        error = None
    if isinstance(error, str):
        return f"{status} {one_line(error)}"
    return str(status)


def sign_in(address, consumer, role_id, secret_id):
    status, body = call(
        address,
        "POST",
        "auth/approle/login",
        body={"role_id": role_id, "secret_id": secret_id},
    )
    if status != 200:
        raise Failure(
            f"openbao-read: sign-in as {consumer} failed: {described(status, body)}"
        )
    try:
        token = json.loads(body)["auth"]["client_token"]
    except (ValueError, KeyError, TypeError):
        token = None
    if not isinstance(token, str):
        raise Failure(
            f"openbao-read: sign-in as {consumer} answered 200 without a token"
        )
    return token


def read_value(address, token, consumer, name):
    status, body = call(address, "GET", f"secret/data/{consumer}/{name}", token=token)
    if status != 200:
        raise Failure(
            f"openbao-read: reading {consumer}/{name} failed: {described(status, body)}"
        )
    try:
        value = json.loads(body)["data"]["data"]["value"]
    except (ValueError, KeyError, TypeError):
        value = None
    if not isinstance(value, str):
        raise Failure(f"openbao-read: {consumer}/{name} has no value field")
    return value


def revoke(address, token):
    """Revoke the token; a failure here is reported but changes no exit status."""
    try:
        status, _ = call(address, "POST", "auth/token/revoke-self", token=token)
    except Failure as failure:
        print(failure, file=sys.stderr)
        return
    if status != 204:
        print(f"openbao-read: could not revoke the token: {status}", file=sys.stderr)


def secret(argv):
    parser = Parser(prog="openbao-read")
    parser.add_argument("--config", default=DEFAULT_CONFIG, metavar="PATH")
    parser.add_argument("path")
    args = parser.parse_args(argv)
    consumer, name = parse_path(args.path)
    role_id, secret_id = approle_files(consumer)
    address = read_address(args.config)
    token = sign_in(address, consumer, role_id, secret_id)
    try:
        return read_value(address, token, consumer, name)
    finally:
        revoke(address, token)


def main(argv):
    try:
        sys.stdout.write(secret(argv))
    except Failure as failure:
        print(failure, file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - every failure must end as one line
        # Another error's text can hold what the helper was handling, such as the token in an
        # invalid header, and a traceback runs to many lines, so only its class is named.
        print(
            f"openbao-read: unexpected error: {type(error).__name__}", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":  # pragma: no branch - importing does not run the CLI
    sys.exit(main(sys.argv[1:]))
