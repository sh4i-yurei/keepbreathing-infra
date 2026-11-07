"""Exercise openbao-read through its command line against a stand-in for OpenBao.

The stand-in answers each endpoint with the bodies OpenBao 2.7.2 gave in the rehearsals of
2026-11-06 and 2026-11-07 (OpenBao on the hub decision 58).
"""

import io
import json
import os
import pwd
import socket
import subprocess
import sys
import threading
from contextlib import redirect_stderr, redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

import pytest
from load_source import load_source

helper = load_source("ansible/roles/openbao_client/files/openbao-read.py")
SCRIPT = (
    Path(__file__).resolve().parents[1] / "roles/openbao_client/files/openbao-read.py"
)

ROLE_ID = "5f0c6a2e-41d7-4c1b-9f3e-role-id-test"
SECRET_ID = "9d1e4b7a-2c8f-4e6d-a1b5-secret-id-test"
TOKEN = "s.clientsvc-token-test-0123456789"
VALUE = "clientsvc-probe"
# The runner's own HOME, before a test points it at a decoy. Its user site-packages hold
# pytest, coverage and mutmut on the laptop, which the child interpreter must still find.
REAL_HOME = os.environ.get("HOME", "")
SECRETS = (ROLE_ID, SECRET_ID, TOKEN, VALUE)
PATH_MESSAGE = (
    "openbao-read: the path must be <consumer>/<name>, "
    "each part matching ^[a-z][a-z0-9-]*$\n"
)
LOGIN = ("POST", "/v1/auth/approle/login")
READ = ("GET", "/v1/secret/data/clientsvc/probe")
REVOKE = ("POST", "/v1/auth/token/revoke-self")
CIDR_ERROR = (
    'source address "198.51.100.7" unauthorized by CIDR restrictions on the role: '
    "%!w(<nil>)"
)
PERMISSION_DENIED = {"errors": ["1 error occurred:\n\t* permission denied\n\n"]}
LOGIN_ANSWER = {
    "request_id": "0b6a3f5e-6f43-4b7d-8d0e-3d2f4c5b6a71",
    "lease_id": "",
    "renewable": False,
    "lease_duration": 0,
    "data": None,
    "wrap_info": None,
    "warnings": None,
    "auth": {
        "client_token": TOKEN,
        "accessor": "Xm1oZtR2kq9aVb3nL7cP4sWd",
        "policies": ["default", "clientsvc"],
        "token_policies": ["default", "clientsvc"],
        "metadata": {"role_name": "clientsvc"},
        "lease_duration": 300,
        "renewable": True,
        "entity_id": "c3f1e2d4-5a6b-4c7d-8e9f-0a1b2c3d4e5f",
        "token_type": "service",
        "orphan": True,
        "mfa_requirement": None,
        "num_uses": 0,
    },
}
READ_ANSWER = {
    "request_id": "7e2d1c0b-9a8f-4e7d-6c5b-4a3f2e1d0c9b",
    "lease_id": "",
    "renewable": False,
    "lease_duration": 0,
    "data": {
        "data": {"value": VALUE},
        "metadata": {
            "created_time": "2026-11-07T09:00:00.000000000Z",
            "custom_metadata": None,
            "deletion_time": "",
            "destroyed": False,
            "version": 1,
        },
    },
    "wrap_info": None,
    "warnings": None,
    "auth": None,
}
# Ways an endpoint can misbehave instead of answering.
HANG_UP = "hang up"
STALL = "stall"
GARBAGE = "garbage"


class StandIn:
    """A stand-in for OpenBao on 127.0.0.1 that records every request it is sent."""

    def __init__(self):
        self.requests = []
        self.overrides = {}
        self.release = threading.Event()
        stand_in = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                stand_in.answer(self)

            do_POST = do_GET

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.address = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(
            target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True
        ).start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()

    def calls(self):
        return [(request.method, request.path) for request in self.requests]

    def answer(self, handler):
        length = int(handler.headers.get("Content-Length") or 0)
        raw = handler.rfile.read(length)
        request = SimpleNamespace(
            method=handler.command,
            path=handler.path,
            headers=handler.headers,
            token=handler.headers.get("X-Vault-Token"),
            body=json.loads(raw) if raw else None,
        )
        self.requests.append(request)
        key = (request.method, request.path)
        answer = self.overrides[key] if key in self.overrides else self.default(request)
        if answer == HANG_UP:
            handler.close_connection = True
            return
        if answer == STALL:
            self.release.wait(60)
            return
        if answer == GARBAGE:
            handler.wfile.write(b"HELLO\r\n\r\n")
            return
        status, payload = answer
        if isinstance(payload, bytes):
            data = payload
        else:
            data = b"" if payload is None else json.dumps(payload).encode()
        handler.send_response(status)
        if data:
            handler.send_header("Content-Type", "application/json")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)

    @staticmethod
    def default(request):
        if (request.method, request.path) == LOGIN:
            if not request.body.get("secret_id"):
                return 400, {"errors": ["missing secret_id"]}
            if request.body == {"role_id": ROLE_ID, "secret_id": SECRET_ID}:
                return 200, LOGIN_ANSWER
            return 400, {"errors": ["invalid role or secret ID"]}
        if request.token != TOKEN:
            return 403, {"errors": ["permission denied"]}
        if (request.method, request.path) == REVOKE:
            return 204, None
        if request.method == "GET" and request.path.startswith(
            "/v1/secret/data/clientsvc/"
        ):
            if request.path == READ[1]:
                return 200, READ_ANSWER
            # A path the consumer may read but nobody wrote (the driver's clientsvc/missing).
            return 404, {"errors": []}
        return 403, PERMISSION_DENIED


@pytest.fixture
def stand_in():
    server = StandIn()
    yield server
    server.close()


@pytest.fixture
def home(tmp_path, monkeypatch):
    """The account's home from the password database, with clientsvc's AppRole files.

    $HOME points at a decoy holding other files, which the helper must never read.
    """
    home = tmp_path / "home"
    folder = home / ".config/openbao/approle/clientsvc"
    folder.mkdir(parents=True)
    (folder / "role-id").write_text(ROLE_ID)
    (folder / "secret-id").write_text(SECRET_ID)
    decoy = tmp_path / "decoy/.config/openbao/approle/clientsvc"
    decoy.mkdir(parents=True)
    (decoy / "role-id").write_text("decoy-role-id")
    (decoy / "secret-id").write_text("decoy-secret-id")
    monkeypatch.setenv("HOME", str(tmp_path / "decoy"))
    uid = os.getuid()

    def getpwuid(asked):
        if asked != uid:
            raise KeyError(f"getpwuid(): uid not found: {asked}")
        return SimpleNamespace(pw_name="clienttest", pw_uid=uid, pw_dir=str(home))

    monkeypatch.setattr(pwd, "getpwuid", getpwuid)
    return home


@pytest.fixture
def config(tmp_path, stand_in):
    path = tmp_path / "client.json"
    path.write_text(json.dumps({"address": stand_in.address}) + "\n")
    return path


def run(*args):
    output = io.StringIO()
    errors = io.StringIO()
    with redirect_stdout(output), redirect_stderr(errors):
        status = helper.main([str(arg) for arg in args])
    return status, output.getvalue(), errors.getvalue()


def failed(result, message):
    """A failure exits 1 with its one line, and prints no credential or value."""
    assert result == (1, "", message)
    for secret in SECRETS:
        assert secret not in result[1] + result[2]


def approle_folder(home):
    return home / ".config/openbao/approle/clientsvc"


def test_prints_the_value_after_sign_in_read_and_one_revoke(home, config, stand_in):
    assert run("--config", config, "clientsvc/probe") == (0, VALUE, "")
    assert stand_in.calls() == [LOGIN, READ, REVOKE]
    login, read, revoke = stand_in.requests
    assert login.body == {"role_id": ROLE_ID, "secret_id": SECRET_ID}
    assert [login.token, read.token, revoke.token] == [None, TOKEN, TOKEN]
    assert [read.body, revoke.body] == [None, None]
    # Tailscale's proxy adds X-Forwarded-For on the hub (decision 16), never the helper.
    assert all(
        "X-Forwarded-For" not in request.headers for request in stand_in.requests
    )


def test_the_value_is_written_exactly_as_stored(home, config, stand_in):
    stored = "line one\nline two\n  trailing space é "
    answer = json.loads(json.dumps(READ_ANSWER))
    answer["data"]["data"]["value"] = stored
    stand_in.overrides[READ] = (200, answer)
    assert run("--config", config, "clientsvc/probe") == (0, stored, "")


@pytest.mark.parametrize(
    "path",
    [
        "ClientSvc/probe",
        "clientsvc",
        "clientsvc/probe/extra",
        "../x/probe",
        "clientsvc/Probe",
        "clientsvc/probe\n",
        "1svc/probe",
        "clientsvc/1probe",
        "client_svc/probe",
        "clientsvc/",
        "/probe",
        "",
    ],
)
def test_a_bad_path_is_refused_before_any_request(path, home, config, stand_in):
    failed(run("--config", config, path), PATH_MESSAGE)
    assert stand_in.requests == []


def test_a_path_starting_with_a_hyphen_is_refused_after_the_separator(
    home, config, stand_in
):
    failed(run("--config", config, "--", "-svc/probe"), PATH_MESSAGE)
    assert stand_in.requests == []


def test_digits_and_hyphens_after_the_first_letter_are_accepted(home, config, stand_in):
    failed(
        run("--config", config, "clientsvc/probe-2"),
        "openbao-read: reading clientsvc/probe-2 failed: 404\n",
    )
    assert stand_in.calls() == [
        LOGIN,
        ("GET", "/v1/secret/data/clientsvc/probe-2"),
        REVOKE,
    ]
    folder = home / ".config/openbao/approle/client-9"
    failed(
        run("--config", config, "client-9/probe"),
        f"openbao-read: no AppRole files for client-9 in {folder}\n",
    )


@pytest.mark.parametrize(
    "damage",
    [
        lambda folder: (folder / "secret-id").unlink(),
        lambda folder: (folder / "role-id").unlink(),
        lambda folder: (
            (folder / "secret-id").unlink(),
            (folder / "secret-id").mkdir(),
        ),
        lambda folder: (folder / "role-id").write_bytes(b"\xff\xfe role"),
        lambda folder: (folder / "secret-id").write_bytes(b"\xff\xfe secret"),
    ],
    ids=[
        "no secret-id",
        "no role-id",
        "secret-id unreadable",
        "role-id not text",
        "secret-id not text",
    ],
)
def test_missing_or_unreadable_approle_files_fail_before_any_request(
    damage, home, config, stand_in
):
    folder = approle_folder(home)
    damage(folder)
    failed(
        run("--config", config, "clientsvc/probe"),
        f"openbao-read: no AppRole files for clientsvc in {folder}\n",
    )
    assert stand_in.requests == []


def test_an_account_missing_from_the_password_database_fails(
    monkeypatch, config, stand_in
):
    def getpwuid(asked):
        raise KeyError(f"getpwuid(): uid not found: {asked}")

    monkeypatch.setattr(pwd, "getpwuid", getpwuid)
    failed(
        run("--config", config, "clientsvc/probe"),
        f"openbao-read: uid {os.getuid()} has no entry in the password database\n",
    )
    assert stand_in.requests == []


def test_a_refused_sign_in_reads_nothing_and_revokes_nothing(home, config, stand_in):
    (approle_folder(home) / "secret-id").write_text("not-the-secret-id")
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: sign-in as clientsvc failed: 400 invalid role or secret ID\n",
    )
    assert stand_in.calls() == [LOGIN]
    assert stand_in.requests[0].body == {
        "role_id": ROLE_ID,
        "secret_id": "not-the-secret-id",
    }


def test_an_empty_secret_id_file_reaches_openbao_and_fails_its_sign_in(
    home, config, stand_in
):
    (approle_folder(home) / "secret-id").write_text("")
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: sign-in as clientsvc failed: 400 missing secret_id\n",
    )
    assert stand_in.calls() == [LOGIN]


@pytest.mark.parametrize(
    ("answer", "message"),
    [
        (
            (400, {"errors": [CIDR_ERROR]}),
            f"openbao-read: sign-in as clientsvc failed: 400 {CIDR_ERROR}\n",
        ),
        ((503, {"errors": []}), "openbao-read: sign-in as clientsvc failed: 503\n"),
        (
            (502, b"<html>Bad Gateway</html>"),
            "openbao-read: sign-in as clientsvc failed: 502\n",
        ),
        (
            (500, {"warnings": ["x"]}),
            "openbao-read: sign-in as clientsvc failed: 500\n",
        ),
        ((500, ["errors"]), "openbao-read: sign-in as clientsvc failed: 500\n"),
        (
            (500, {"errors": [{"code": 1}]}),
            "openbao-read: sign-in as clientsvc failed: 500\n",
        ),
        ((500, b"\xff\xfe"), "openbao-read: sign-in as clientsvc failed: 500\n"),
        ((204, None), "openbao-read: sign-in as clientsvc failed: 204\n"),
    ],
    ids=[
        "CIDR refusal",
        "no errors",
        "not JSON",
        "no errors key",
        "a list",
        "error not text",
        "not text",
        "not 200",
    ],
)
def test_a_failed_sign_in_names_the_status_and_openbao_s_first_error(
    answer, message, home, config, stand_in
):
    stand_in.overrides[LOGIN] = answer
    failed(run("--config", config, "clientsvc/probe"), message)
    assert stand_in.calls() == [LOGIN]


@pytest.mark.parametrize(
    "payload",
    [
        {"auth": None},
        {"auth": {"accessor": "x"}},
        {"auth": {"client_token": 7}},
        b"not json",
        ["auth"],
    ],
    ids=["auth null", "no client token", "token not text", "not JSON", "a list"],
)
def test_a_sign_in_without_a_token_fails_and_reads_nothing(
    payload, home, config, stand_in
):
    stand_in.overrides[LOGIN] = (200, payload)
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: sign-in as clientsvc answered 200 without a token\n",
    )
    assert stand_in.calls() == [LOGIN]


def test_a_refused_read_still_revokes_the_token(home, config, stand_in):
    stand_in.overrides[READ] = (403, PERMISSION_DENIED)
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: reading clientsvc/probe failed: 403 "
        "1 error occurred: * permission denied\n",
    )
    assert stand_in.calls() == [LOGIN, READ, REVOKE]
    assert stand_in.requests[2].token == TOKEN


def test_a_soft_deleted_secret_fails_with_404(home, config, stand_in):
    stand_in.overrides[READ] = (404, {"errors": []})
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: reading clientsvc/probe failed: 404\n",
    )
    assert stand_in.calls() == [LOGIN, READ, REVOKE]


@pytest.mark.parametrize(
    "payload",
    [
        {"data": {"data": {"other": "x"}}},
        {"data": {"data": {"value": 5}}},
        {"data": {"data": None}},
        {"data": None},
        {"warnings": None},
        b"not json",
        ["data"],
    ],
    ids=[
        "no value",
        "value not text",
        "data null",
        "outer data null",
        "no data",
        "not JSON",
        "a list",
    ],
)
def test_a_read_without_a_value_field_fails_and_still_revokes(
    payload, home, config, stand_in
):
    stand_in.overrides[READ] = (200, payload)
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: clientsvc/probe has no value field\n",
    )
    assert stand_in.calls() == [LOGIN, READ, REVOKE]


def test_a_failed_revoke_is_reported_without_changing_the_result(
    home, config, stand_in
):
    stand_in.overrides[REVOKE] = (403, {"errors": ["permission denied"]})
    assert run("--config", config, "clientsvc/probe") == (
        0,
        VALUE,
        "openbao-read: could not revoke the token: 403\n",
    )
    assert stand_in.calls() == [LOGIN, READ, REVOKE]


def test_a_revoke_that_cannot_reach_openbao_does_not_change_the_result(
    home, config, stand_in
):
    stand_in.overrides[REVOKE] = HANG_UP
    assert run("--config", config, "clientsvc/probe") == (
        0,
        VALUE,
        f"openbao-read: could not reach OpenBao at {stand_in.address}: "
        "Remote end closed connection without response\n",
    )


def test_a_failed_read_reports_both_failures_and_exits_1(home, config, stand_in):
    stand_in.overrides[READ] = (403, PERMISSION_DENIED)
    stand_in.overrides[REVOKE] = (500, {"errors": ["internal error"]})
    failed(
        run("--config", config, "clientsvc/probe"),
        "openbao-read: could not revoke the token: 500\n"
        "openbao-read: reading clientsvc/probe failed: 403 "
        "1 error occurred: * permission denied\n",
    )


def test_nothing_listening_fails_with_the_address(home, tmp_path, stand_in):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    address = f"http://127.0.0.1:{port}"
    path = tmp_path / "closed.json"
    path.write_text(json.dumps({"address": address}))
    failed(
        run("--config", path, "clientsvc/probe"),
        f"openbao-read: could not reach OpenBao at {address}: "
        "[Errno 111] Connection refused\n",
    )


def test_a_connection_lost_during_the_read_still_revokes(home, config, stand_in):
    stand_in.overrides[READ] = HANG_UP
    failed(
        run("--config", config, "clientsvc/probe"),
        f"openbao-read: could not reach OpenBao at {stand_in.address}: "
        "Remote end closed connection without response\n",
    )
    assert stand_in.calls() == [LOGIN, READ, REVOKE]


def test_an_answer_that_is_not_http_fails_on_one_line(home, config, stand_in):
    stand_in.overrides[LOGIN] = GARBAGE
    failed(
        run("--config", config, "clientsvc/probe"),
        f"openbao-read: could not reach OpenBao at {stand_in.address}: HELLO\n",
    )


def test_an_openbao_that_never_answers_times_out(home, config, stand_in):
    stand_in.overrides[LOGIN] = STALL
    failed(
        run("--config", config, "clientsvc/probe"),
        f"openbao-read: could not reach OpenBao at {stand_in.address}: timed out\n",
    )


@pytest.mark.parametrize(
    "content",
    [None, "not json", '["address"]', '{"server": "x"}', '{"address": 8200}'],
    ids=["missing", "not JSON", "a list", "no address", "address not text"],
)
def test_a_bad_client_json_fails_before_any_request(content, home, tmp_path, stand_in):
    path = tmp_path / "client.json"
    if content is not None:
        path.write_text(content)
    failed(
        run("--config", path, "clientsvc/probe"),
        f"openbao-read: {path} must hold a JSON object with a string address\n",
    )
    assert stand_in.requests == []


def test_the_default_client_json_is_etc_openbao(home, stand_in):
    failed(
        run("clientsvc/probe"),
        "openbao-read: /etc/openbao/client.json must hold a JSON object with a "
        "string address\n",
    )


@pytest.mark.parametrize(
    ("args", "message"),
    [
        ((), "openbao-read: the following arguments are required: path\n"),
        (("a/b", "c/d"), "openbao-read: unrecognized arguments: c/d\n"),
        (
            ("a/b", "--config"),
            "openbao-read: argument --config: expected one argument\n",
        ),
    ],
)
def test_a_bad_command_line_exits_1_with_one_line(args, message, home, stand_in):
    failed(run(*args), message)
    assert stand_in.requests == []


def test_help_names_the_program_and_its_arguments(capsys):
    with pytest.raises(SystemExit) as exit_:
        helper.main(["--help"])
    assert exit_.value.code == 0
    assert capsys.readouterr().out.splitlines()[0] == (
        "usage: openbao-read [-h] [--config PATH] path"
    )


def test_the_file_runs_as_a_program(tmp_path, home, config, stand_in):
    # A subprocess can't see monkeypatch, so sitecustomize replaces its account lookup.
    site = tmp_path / "site"
    site.mkdir()
    (site / "sitecustomize.py").write_text(
        "import os, pwd, types\n"
        f"_home = {str(home)!r}\n"
        "_uid = os.getuid()\n"
        "def _getpwuid(uid):\n"
        "    if uid != _uid:\n"
        "        raise KeyError(uid)\n"
        "    return types.SimpleNamespace(pw_dir=_home)\n"
        "pwd.getpwuid = _getpwuid\n"
    )
    paths = [str(site), *filter(None, [os.environ.get("PYTHONPATH")])]
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--config", str(config), "clientsvc/probe"],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
        env={**os.environ, "HOME": REAL_HOME, "PYTHONPATH": os.pathsep.join(paths)},
    )
    assert (result.returncode, result.stdout, result.stderr) == (0, VALUE, "")
    assert stand_in.calls() == [LOGIN, READ, REVOKE]
