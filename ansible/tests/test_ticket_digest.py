"""Exercise the morning digest, ticket-digest, against stand-ins for GitHub and ntfy.

The stand-in GitHub serves the issue lists from ticket_digest_github.json, which holds GitHub's
own responses archived on 2026-11-10, and checks the App token the way GitHub does, with the
key's public half. The stand-in reader prints a fresh RSA key in place of openbao-read (OpenBao on
the hub decisions 10, 26, 78, 82 and 91).
"""

import copy
import io
import json
import os
import socket
import subprocess
import sys
import threading
import time
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import jwt
import pytest
import yaml
from cryptography.hazmat.primitives import serialization
from load_source import load_source

digest = load_source("ansible/roles/ticket_band/files/ticket-digest.py")
ANSIBLE = Path(__file__).resolve().parents[1]
SCRIPT = ANSIBLE / "roles/ticket_band/files/ticket-digest.py"
FIXTURES = json.loads((Path(__file__).parent / "ticket_digest_github.json").read_text())
ISSUE_213 = FIXTURES["issue_213"]["body"]
PR_222, PR_221 = FIXTURES["closed_list"]["body"]

APP_ID = 5670133
INSTALLATION_ID = 179920588
INSTALLATION_TOKEN = "ghs_standinInstallationToken0123456789abcd"
NTFY_TOKEN = "tb-digest-token-not-real"
REPO_ISSUES = "/repos/sh4i-yurei/platform-tickets/issues"
TOKEN_PATH = f"/app/installations/{INSTALLATION_ID}/access_tokens"
REVOKE_PATH = "/installation/token"
# The second closed page, at the address GitHub's cursor Link names, with this run's query.
SECOND_PAGE = (
    "/repositories/1368108961/issues?state=closed&labels=ticket&per_page=100"
    "&after=Y3Vyc29yOnYyOpLPAAABob1GK9jPAAAAAXYZ120%3D&page=2"
)
MORE = (
    "https://github.com/sh4i-yurei/platform-tickets/issues?q=is%3Aopen+label%3Aticket"
)
# Ways an endpoint can misbehave instead of answering.
HANG_UP = "hang up"
STALL = "stall"


class StandIn:
    """An HTTP server on 127.0.0.1 that records every request and answers through a function."""

    def __init__(self, answer):
        self.requests = []
        self.answer = answer
        self.release = threading.Event()
        stand_in = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                stand_in.handle(self)

            do_POST = do_DELETE = do_GET

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.address = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(
            target=self.server.serve_forever,
            kwargs={"poll_interval": 0.05},
            daemon=True,
        ).start()

    def close(self):
        self.release.set()
        self.server.shutdown()
        self.server.server_close()

    def handle(self, handler):
        length = int(handler.headers.get("Content-Length") or 0)
        parts = urlsplit(handler.path)
        request = SimpleNamespace(
            method=handler.command,
            target=handler.path,
            path=parts.path,
            query=parse_qs(parts.query),
            headers=handler.headers,
            body=handler.rfile.read(length),
        )
        self.requests.append(request)
        answer = self.answer(request)
        if answer == HANG_UP:
            handler.close_connection = True
            return
        if answer == STALL:
            self.release.wait(60)
            handler.close_connection = True
            return
        status, payload, *extra = answer
        headers = extra[0] if extra else {}
        data = b"" if payload is None else json.dumps(payload).encode()
        handler.send_response(status)
        for name, value in headers.items():
            handler.send_header(name, value)
        if data:
            handler.send_header("Content-Type", "application/json; charset=utf-8")
        handler.send_header("Content-Length", str(len(data)))
        handler.end_headers()
        handler.wfile.write(data)


class GitHub:
    """GitHub's App token, issue list and revoke endpoints, as the digest uses them.

    The token request answers 201 only with an App token that verifies with the key's public
    half, and the lists answer only the installation token. Each list is a list of pages; a page
    after the first is served at SECOND_PAGE, which the page before names in its Link header.
    """

    def __init__(self, public_key):
        self.public_key = public_key
        self.pages = {"open": [[]], "closed": [[]]}
        self.links = {}
        self.overrides = {}
        self.claims = []
        self.stand_in = StandIn(self.answer)
        self.address = self.stand_in.address

    def calls(self):
        return [(request.method, request.target) for request in self.stand_in.requests]

    @property
    def requests(self):
        return self.stand_in.requests

    def answer(self, request):
        if (request.method, request.path) == ("POST", TOKEN_PATH):
            return self.overrides.get("token") or self.token(request)
        if (request.method, request.path) == ("DELETE", REVOKE_PATH):
            return self.overrides.get("revoke") or self.revoke(request)
        if request.method == "GET" and request.path in (
            REPO_ISSUES,
            urlsplit(SECOND_PAGE).path,
        ):
            kind = request.query.get("state", [""])[0]
            return self.overrides.get(kind) or self.issues(request, kind)
        return 404, {"message": "Not Found"}

    def token(self, request):
        scheme, _, token = request.headers.get("Authorization", "").partition(" ")
        try:
            claims = jwt.decode(token, self.public_key, algorithms=["RS256"])
        except jwt.InvalidTokenError:
            claims = None
        if scheme != "Bearer" or claims is None:
            return 401, {"message": "A JSON web token could not be decoded"}
        self.claims.append(claims)
        return 201, {"token": INSTALLATION_TOKEN, "expires_at": "2026-11-12T08:00:00Z"}

    def revoke(self, request):
        if request.headers.get("Authorization") != f"Bearer {INSTALLATION_TOKEN}":
            return 401, {"message": "Bad credentials"}
        return 204, None

    def issues(self, request, kind):
        if request.headers.get("Authorization") != f"Bearer {INSTALLATION_TOKEN}":
            return 401, {"message": "Bad credentials"}
        if kind not in self.pages:
            return 422, {"message": "Validation Failed"}
        index = int(request.query.get("page", ["1"])[0]) - 1
        pages = self.pages[kind]
        headers = {}
        link = self.links.get((kind, index))
        if link is None and index + 1 < len(pages):
            link = f'<{self.address}{SECOND_PAGE}>; rel="next"'
        if link is not None:
            headers["Link"] = link
        return 200, pages[index], headers


class Ntfy:
    """ntfy's publish endpoint: records each post and answers with a set status."""

    def __init__(self):
        self.status = 200
        self.stand_in = StandIn(self.answer)
        self.address = self.stand_in.address

    @property
    def posts(self):
        return self.stand_in.requests

    def answer(self, request):
        if self.status != 200:
            return self.status, {
                "code": 40301,
                "http": self.status,
                "error": "forbidden",
            }
        return 200, {"id": "standin", "event": "message", "topic": "tickets"}


@pytest.fixture(scope="module")
def key():
    """A fresh 2048-bit RSA key in PEM form, and its public half."""
    pem = subprocess.run(
        ["openssl", "genrsa", "2048"], capture_output=True, text=True, check=True
    ).stdout
    private = serialization.load_pem_private_key(pem.encode(), password=None)
    body = [line for line in pem.splitlines() if line and not line.startswith("-----")]
    return SimpleNamespace(pem=pem, public=private.public_key(), body=body)


@pytest.fixture
def github(key):
    server = GitHub(key.public)
    yield server
    server.stand_in.close()


@pytest.fixture
def ntfy():
    server = Ntfy()
    yield server
    server.stand_in.close()


def write_reader(folder, key, *, fail=None, sleep=0):
    """Write the stand-in reader, which appends its arguments to reader-ran beside itself."""
    (folder / "key.pem").write_text(key.pem)
    reader = folder / "standin-key-reader"
    reader.write_text(
        f"#!{sys.executable}\n"
        "import pathlib, sys, time\n"
        "here = pathlib.Path(__file__).parent\n"
        "with open(here / 'reader-ran', 'a') as marker:\n"
        "    marker.write(' '.join(sys.argv[1:]) + '\\n')\n"
        f"fail = {fail!r}\n"
        "if fail:\n"
        "    sys.stderr.write(fail + '\\n')\n"
        "    sys.exit(1)\n"
        f"time.sleep({sleep})\n"
        "sys.stdout.write((here / 'key.pem').read_text())\n"
    )
    reader.chmod(0o755)
    return reader


@pytest.fixture
def setup(tmp_path, key, github, ntfy):
    """The config, token file and reader for one run, with the stand-ins' addresses."""
    token_file = tmp_path / "ntfy-token"
    token_file.write_text(NTFY_TOKEN + "\n")
    config = {
        "app_id": APP_ID,
        "installation_id": INSTALLATION_ID,
        "owner": "sh4i-yurei",
        "repository": "platform-tickets",
        "label": "ticket",
        "key_path": "ticket-band/app-key",
        "reader": str(write_reader(tmp_path, key)),
        "github_api": github.address,
        "ntfy_url": f"{ntfy.address}/tickets",
        "ntfy_token_file": str(token_file),
    }
    path = tmp_path / "ticket-digest.json"

    def write(**changes):
        path.write_text(json.dumps(config | changes) + "\n")
        return path

    write()
    return SimpleNamespace(
        path=path, write=write, token_file=token_file, folder=tmp_path, config=config
    )


def run(config_path):
    output = io.StringIO()
    errors = io.StringIO()
    with redirect_stdout(output), redirect_stderr(errors):
        status = digest.main([str(config_path)])
    return status, output.getvalue(), errors.getvalue()


def labelled(issue):
    """A copy of an issue with its labels replaced by one label named ticket."""
    item = copy.deepcopy(issue)
    item["labels"] = [{"name": "ticket"}]
    return item


def numbered(number, title=None):
    """A copy of the labelled #213 with its own number, address and, optionally, title."""
    item = labelled(ISSUE_213)
    item["number"] = number
    item["url"] = item["url"].removesuffix("/213") + f"/{number}"
    item["html_url"] = item["html_url"].removesuffix("/213") + f"/{number}"
    if title is not None:
        item["title"] = title
    return item


def closed(item, hours_ago):
    item = copy.deepcopy(item)
    item["state"] = "closed"
    item["closed_at"] = (
        datetime.now(timezone.utc) - timedelta(hours=hours_ago)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    return item


def line(item):
    return f"#{item['number']} {item['title']} {item['html_url']}"


def posts(ntfy):
    return [
        (post.path, post.headers.get("Title"), post.body.decode("utf-8"))
        for post in ntfy.posts
    ]


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def assert_no_secret(key, *outputs, extra=()):
    for output in outputs:
        for secret in [*key.body, INSTALLATION_TOKEN, NTFY_TOKEN, *extra]:
            assert secret not in output


def assert_github_headers(github):
    for request in github.requests:
        assert request.headers.get("Accept") == "application/vnd.github+json"
        assert request.headers.get("X-GitHub-Api-Version") == "2022-11-28"


def test_ntfy_address_uses_the_hub_role_port():
    band = yaml.safe_load((ANSIBLE / "roles/ticket_band/defaults/main.yml").read_text())
    hub = yaml.safe_load((ANSIBLE / "roles/hub/defaults/main.yml").read_text())

    assert (
        band.get("ticket_band_digest_ntfy_url")
        == f"http://127.0.0.1:{hub['hub_ntfy_port']}/tickets"
    )


def test_full_digest_posts_open_then_recent_closed_tickets(setup, github, ntfy):
    ticket = labelled(ISSUE_213)
    github.pages["open"] = [[ticket]]
    github.pages["closed"] = [[PR_222, PR_221], [closed(ticket, 1)]]
    started = datetime.now(timezone.utc)

    assert run(setup.path) == (0, "", "")

    assert [(request.method, request.path) for request in github.requests] == [
        ("POST", TOKEN_PATH),
        ("GET", REPO_ISSUES),
        ("GET", REPO_ISSUES),
        ("GET", urlsplit(SECOND_PAGE).path),
        ("DELETE", REVOKE_PATH),
    ]
    token_request, open_list, closed_list, second_page, revoke = github.requests
    # The second page is fetched by the exact address the Link header named.
    assert second_page.target == SECOND_PAGE
    assert len(github.claims) == 1
    claims = github.claims[0]
    assert claims["iss"] == str(APP_ID)
    assert claims["exp"] - claims["iat"] == 600
    assert json.loads(token_request.body) == {
        "repositories": ["platform-tickets"],
        "permissions": {"issues": "read"},
    }
    assert open_list.path == REPO_ISSUES
    assert open_list.query == {
        "state": ["open"],
        "labels": ["ticket"],
        "per_page": ["100"],
    }
    assert closed_list.path == REPO_ISSUES
    since = closed_list.query.pop("since")
    assert closed_list.query == {
        "state": ["closed"],
        "labels": ["ticket"],
        "per_page": ["100"],
    }
    assert len(since) == 1
    expected_since = started - timedelta(hours=24)
    parsed_since = datetime.strptime(since[0], "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=timezone.utc
    )
    assert abs((parsed_since - expected_since).total_seconds()) < 5
    for request in (open_list, closed_list, second_page, revoke):
        assert request.headers.get("Authorization") == f"Bearer {INSTALLATION_TOKEN}"
    assert_github_headers(github)
    assert (setup.folder / "reader-ran").read_text() == "ticket-band/app-key\n"

    assert len(ntfy.posts) == 1
    post = ntfy.posts[0]
    assert post.method == "POST"
    assert post.path == "/tickets"
    assert post.headers.get("Authorization") == f"Bearer {NTFY_TOKEN}"
    assert post.headers.get("Title") == "Tickets: 1 open, 1 closed in the last day"
    assert post.body.decode("utf-8") == f"{line(ticket)}\n{line(ticket)}"
    assert "/pull/" not in post.body.decode("utf-8")


def test_quiet_day_with_both_lists_empty_sends_nothing(setup, github, ntfy):
    assert run(setup.path) == (0, "", "")
    assert ntfy.posts == []


def test_quiet_day_with_only_a_ticket_closed_over_a_day_ago_sends_nothing(
    setup, github, ntfy
):
    github.pages["closed"] = [[closed(labelled(ISSUE_213), 25)]]

    assert run(setup.path) == (0, "", "")
    assert ntfy.posts == []


@pytest.mark.parametrize(
    ("case", "message", "revokes"),
    [
        (
            "reader",
            "ticket-digest: could not read the App key: openbao-read: could not reach "
            "OpenBao at https://openbao.example: timed out",
            0,
        ),
        ("token", "ticket-digest: GitHub refused the installation token: 401", 0),
        ("list", "ticket-digest: GitHub refused the issue list: 502", 1),
        ("ntfy", "ticket-digest: ntfy refused the digest: 403", 1),
        ("next", "ticket-digest: GitHub's next page is outside {address}", 1),
    ],
)
def test_each_failure_is_one_line_and_exit_1(
    setup, github, ntfy, key, case, message, revokes
):
    github.pages["open"] = [[labelled(ISSUE_213)]]
    if case == "reader":
        write_reader(
            setup.folder,
            key,
            fail="openbao-read: could not reach OpenBao at https://openbao.example: timed out",
        )
    elif case == "token":
        github.overrides["token"] = (
            401,
            {"message": "A JSON web token could not be decoded"},
        )
    elif case == "list":
        github.overrides["open"] = (502, {"message": "Server Error"})
    elif case == "ntfy":
        ntfy.status = 403
    else:
        github.pages["closed"] = [[], []]
        github.links[("closed", 0)] = (
            '<http://198.51.100.9/repositories/1/issues?page=2>; rel="next"'
        )

    status, output, errors = run(setup.path)

    assert (status, output, errors) == (
        1,
        "",
        message.format(address=github.address) + "\n",
    )
    assert github.calls().count(("DELETE", REVOKE_PATH)) == revokes
    assert_no_secret(key, output, errors)


@pytest.mark.parametrize("content", [None, "\n"])
def test_an_unreadable_token_file_fails_before_any_other_step(
    setup, github, ntfy, content
):
    if content is None:
        token_file = setup.folder / "absent-token"
    else:
        token_file = setup.folder / "empty-token"
        token_file.write_text(content)
    setup.write(ntfy_token_file=str(token_file))

    assert run(setup.path) == (
        1,
        "",
        f"ticket-digest: could not read the ntfy token from {token_file}\n",
    )
    assert not (setup.folder / "reader-ran").exists()
    assert github.requests == []
    assert ntfy.posts == []


def test_pull_requests_are_left_out(setup, github, ntfy):
    ticket = labelled(ISSUE_213)
    reopened_pull = copy.deepcopy(PR_221)
    reopened_pull["state"] = "open"
    reopened_pull["closed_at"] = None
    github.pages["open"] = [[ticket, reopened_pull]]
    github.pages["closed"] = [[closed(PR_222, 1)]]

    assert run(setup.path) == (0, "", "")
    assert posts(ntfy) == [
        ("/tickets", "Tickets: 1 open, 0 closed in the last day", line(ticket))
    ]


def test_open_tickets_come_first_and_each_group_is_in_number_order(setup, github, ntfy):
    github.pages["open"] = [[numbered(215), numbered(213)]]
    github.pages["closed"] = [[closed(numbered(216), 1), closed(numbered(214), 2)]]

    assert run(setup.path) == (0, "", "")
    assert [
        (title, [entry.split(" ", 1)[0] for entry in body.split("\n")])
        for _, title, body in posts(ntfy)
    ] == [
        ("Tickets: 2 open, 2 closed in the last day", ["#213", "#215", "#214", "#216"])
    ]


def cycling_tickets(count):
    """Copies of #213 numbered from 301, titled in turn after #213, #222 and #221."""
    titles = [ISSUE_213["title"], PR_222["title"], PR_221["title"]]
    return [numbered(300 + n, titles[(n - 1) % 3]) for n in range(1, count + 1)]


def test_a_long_digest_keeps_whole_lines_and_links_to_the_rest(setup, github, ntfy):
    tickets = cycling_tickets(40)
    lines = [line(ticket) for ticket in tickets]
    # The test's own input: every line would not fit, and 35 lines with their last line wouldn't.
    assert len("\n".join(lines).encode()) == 4557
    assert len("\n".join([*lines[:35], f"…and 5 more: {MORE}"]).encode()) == 4076
    github.pages["open"] = [tickets]
    expected = "\n".join([*lines[:34], f"…and 6 more: {MORE}"])
    assert len(expected.encode()) == 3971

    assert run(setup.path) == (0, "", "")
    assert posts(ntfy) == [
        ("/tickets", "Tickets: 40 open, 0 closed in the last day", expected)
    ]


def test_a_digest_of_exactly_4000_bytes_is_sent_whole(setup, github, ntfy):
    title = ISSUE_213["title"].replace("e", "é", 1)
    tickets = [numbered(300 + n) for n in range(1, 32)] + [numbered(332, title)]
    body = "\n".join(line(ticket) for ticket in tickets)
    assert (len(body.encode()), len(body)) == (4000, 3999)
    github.pages["open"] = [tickets]

    assert run(setup.path) == (0, "", "")
    assert [post.headers.get("Authorization") for post in ntfy.posts] == [
        f"Bearer {NTFY_TOKEN}"
    ]
    assert posts(ntfy) == [
        ("/tickets", "Tickets: 32 open, 0 closed in the last day", body)
    ]


def test_a_digest_one_byte_over_counts_bytes_not_characters(setup, github, ntfy):
    title = ISSUE_213["title"].replace("'", "’", 1)
    tickets = [numbered(300 + n) for n in range(1, 32)] + [numbered(332, title)]
    lines = [line(ticket) for ticket in tickets]
    assert (len("\n".join(lines).encode()), len("\n".join(lines))) == (4001, 3999)
    github.pages["open"] = [tickets]
    expected = "\n".join([*lines[:31], f"…and 1 more: {MORE}"])
    assert len(expected.encode()) == 3970

    assert run(setup.path) == (0, "", "")
    assert posts(ntfy) == [
        ("/tickets", "Tickets: 32 open, 0 closed in the last day", expected)
    ]


@pytest.mark.parametrize(
    "case", ["github-down", "hang-up", "ntfy-down", "broken-token"]
)
def test_connection_failures_and_unexpected_errors(setup, github, ntfy, key, case):
    github.pages["open"] = [[labelled(ISSUE_213)]]
    if case == "github-down":
        setup.write(github_api=f"http://127.0.0.1:{free_port()}")
        message = (
            "ticket-digest: could not reach GitHub: [Errno 111] Connection refused"
        )
    elif case == "hang-up":
        github.overrides["open"] = HANG_UP
        message = (
            "ticket-digest: could not reach GitHub: "
            "Remote end closed connection without response"
        )
    elif case == "ntfy-down":
        setup.write(ntfy_url=f"http://127.0.0.1:{free_port()}/tickets")
        message = "ticket-digest: could not reach ntfy: [Errno 111] Connection refused"
    else:
        setup.token_file.write_text(NTFY_TOKEN + "\r\nX-Injected: yes\n")
        message = "ticket-digest: unexpected error: ValueError"

    status, output, errors = run(setup.path)

    assert (status, output, errors) == (1, "", message + "\n")
    if case != "github-down":
        assert github.calls()[-1] == ("DELETE", REVOKE_PATH)
    if case == "hang-up":
        assert [call[0] for call in github.calls()] == ["POST", "GET", "DELETE"]
        assert github.requests[1].query["state"] == ["open"]
    if case != "ntfy-down":
        assert ntfy.posts == []
    assert_no_secret(key, output, errors, extra=("X-Injected",))


@pytest.mark.parametrize(
    ("answer", "message"),
    [
        (
            (500, {"message": "Server Error"}),
            "ticket-digest: could not revoke the installation token: 500",
        ),
        (
            HANG_UP,
            "ticket-digest: could not reach GitHub: "
            "Remote end closed connection without response",
        ),
    ],
)
def test_a_failed_revoke_is_reported_without_changing_the_exit_status(
    setup, github, ntfy, answer, message
):
    github.pages["open"] = [[labelled(ISSUE_213)]]
    github.overrides["revoke"] = answer

    assert run(setup.path) == (0, "", message + "\n")
    assert len(ntfy.posts) == 1


def test_a_github_request_that_never_answers_times_out(setup, github, ntfy):
    github.overrides["token"] = STALL
    started = time.monotonic()

    result = run(setup.path)

    elapsed = time.monotonic() - started
    assert result == (1, "", "ticket-digest: could not reach GitHub: timed out\n")
    assert 29 <= elapsed <= 40
    assert ntfy.posts == []


def test_a_reader_that_never_finishes_is_stopped(setup, github, ntfy, key):
    write_reader(setup.folder, key, sleep=45)
    started = time.monotonic()

    result = run(setup.path)

    elapsed = time.monotonic() - started
    assert result == (1, "", "ticket-digest: unexpected error: TimeoutExpired\n")
    assert 29 <= elapsed <= 40
    assert github.requests == []
    assert ntfy.posts == []


def test_the_program_runs_as_a_file(setup):
    token_file = setup.folder / "absent-token"
    setup.write(ntfy_token_file=str(token_file))
    environment = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"]}
    if "COVERAGE_PROCESS_CONFIG" in os.environ:
        environment["COVERAGE_PROCESS_CONFIG"] = os.environ["COVERAGE_PROCESS_CONFIG"]

    result = subprocess.run(
        [sys.executable, str(SCRIPT), str(setup.path)],
        capture_output=True,
        text=True,
        env=environment,
        timeout=60,
        check=False,
    )

    assert (result.returncode, result.stdout, result.stderr) == (
        1,
        "",
        f"ticket-digest: could not read the ntfy token from {token_file}\n",
    )
