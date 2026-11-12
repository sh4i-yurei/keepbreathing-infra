#!/usr/bin/python3
"""Post the morning digest of the band's ticket issues to ntfy's tickets topic.

Usage: ticket-digest <config>

The config is a JSON object with app_id, installation_id, owner, repository, label, key_path,
reader, github_api, ntfy_url and ntfy_token_file (OpenBao on the hub decisions 10, 26 and 78).
In order, the digest reads its ntfy token from ntfy_token_file (decision 82); takes the GitHub
App's key from the reader's standard output, run with key_path as its one argument; signs an App
token with it; asks for an installation token limited to reading the repository's issues; reads
the open issues carrying the label and those closed in the last day; revokes the installation
token; and posts one message listing them, unless there are none (decision 10). The message's
body stays within 4,000 bytes, and links to the rest when it can't hold every line (decision 91).

Every failure is one line on standard error and exit status 1, and nothing goes to standard
output. No line ever holds the key, the App token, the installation token or ntfy's token.
Requests go only to the configured addresses: the opener ignores proxy variables and follows no
redirect, and a next-page address outside github_api is refused.
"""

import http.client
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from operator import itemgetter
from pathlib import Path

import jwt

# Seconds to wait for each connection, each read and the reader.
TIMEOUT = 30
# The most bytes the message's body may hold. The hub's ntfy refuses a message of 4,096 bytes or
# more, because it has no attachment cache (decision 91).
LIMIT = 4000
DAY = timedelta(days=1)
GITHUB_HEADERS = {
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}
# One link-value of a Link header (RFC 8288 section 3): its target in angle brackets, and its
# parameters up to the comma that starts the next link-value.
LINK_VALUE = re.compile(r"<([^>]*)>([^,]*)")


class Failure(Exception):
    """A failure whose message is the one line written to standard error."""


def one_line(text):
    return " ".join(str(text).split())


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


def call(service, method, url, headers, data=None):
    """Send one request and return its status, headers and body, whatever the status."""
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener().open(request, timeout=TIMEOUT) as response:
            return response.status, response.headers, response.read()
    except (OSError, http.client.HTTPException) as error:
        reason = error.reason if isinstance(error, urllib.error.URLError) else error
        raise Failure(
            f"ticket-digest: could not reach {service}: {one_line(reason)}"
        ) from None


def ntfy_token(path):
    """ntfy's token from its file, without the newline Ansible writes after it."""
    try:
        token = Path(path).read_text().strip()
    except (OSError, UnicodeDecodeError):
        token = ""
    if not token:
        raise Failure(f"ticket-digest: could not read the ntfy token from {path}")
    return token


def app_key(reader, key_path):
    """The App's private key, from the reader's standard output."""
    result = subprocess.run(
        [reader, key_path],
        capture_output=True,
        text=True,
        timeout=TIMEOUT,
        check=False,
    )
    if result.returncode != 0:
        raise Failure(
            f"ticket-digest: could not read the App key: {one_line(result.stderr)}"
        )
    return result.stdout


def app_token(app_id, key):
    """An App token as GitHub asks: RS256, issued 60 seconds ago, valid for 10 minutes."""
    now = int(time.time())
    claims = {"iat": now - 60, "exp": now + 540, "iss": str(app_id)}
    return jwt.encode(claims, key, algorithm="RS256")


def installation_token(api, installation_id, repository, token):
    """An installation token that reaches only the repository, and only to read its issues."""
    status, _, body = call(
        "GitHub",
        "POST",
        f"{api}/app/installations/{installation_id}/access_tokens",
        GITHUB_HEADERS
        | {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json.dumps(
            {"repositories": [repository], "permissions": {"issues": "read"}}
        ).encode(),
    )
    if status != 201:
        raise Failure(f"ticket-digest: GitHub refused the installation token: {status}")
    return json.loads(body)["token"]


def next_page(link):
    """The target of the Link header's link whose relation types include next, or None."""
    targets = {}
    for target, parameters in LINK_VALUE.findall(link):
        for parameter in parameters.split(";"):
            name, _, value = parameter.partition("=")
            if name.strip().lower() == "rel":
                for relation in value.strip().strip('"').lower().split():
                    targets.setdefault(relation, target)
    return targets.get("next")


def issues(api, token, owner, repository, query):
    """Every item of one issue list, following each page's Link to the next."""
    url = f"{api}/repos/{owner}/{repository}/issues?{urllib.parse.urlencode(query)}"
    items = []
    while url is not None:
        status, headers, body = call(
            "GitHub",
            "GET",
            url,
            GITHUB_HEADERS | {"Authorization": f"Bearer {token}"},
        )
        if status != 200:
            raise Failure(f"ticket-digest: GitHub refused the issue list: {status}")
        items += json.loads(body)
        url = next_page(headers.get("Link", ""))
        if url is not None and not url.startswith(f"{api}/"):
            raise Failure(f"ticket-digest: GitHub's next page is outside {api}")
    return items


def revoke(api, token):
    """Revoke the installation token; a failure here is reported but changes no exit status."""
    try:
        status, _, _ = call(
            "GitHub",
            "DELETE",
            f"{api}/installation/token",
            GITHUB_HEADERS | {"Authorization": f"Bearer {token}"},
        )
    except Failure as failure:
        print(failure, file=sys.stderr)
        return
    if status != 204:
        print(
            f"ticket-digest: could not revoke the installation token: {status}",
            file=sys.stderr,
        )


def closed_at(item):
    return datetime.fromisoformat(item["closed_at"])


def message(lines, owner, repository, label):
    """The lines joined by newlines, kept to LIMIT bytes in UTF-8 (decision 91).

    When every line doesn't fit, the body is the longest run of whole lines from the start that
    fits with a last line counting the lines left out and linking to the open tickets.
    """
    address = (
        f"https://github.com/{owner}/{repository}/issues"
        f"?q=is%3Aopen+label%3A{urllib.parse.quote_plus(label)}"
    )
    kept = len(lines)
    body = "\n".join(lines)
    while len(body.encode()) > LIMIT:
        kept -= 1
        body = "\n".join([*lines[:kept], f"…and {len(lines) - kept} more: {address}"])
    return body


def digest(argv):
    # Closed tickets count from 24 hours before the run started.
    since = datetime.now(timezone.utc) - DAY
    (config_path,) = argv
    config = json.loads(Path(config_path).read_text())
    ntfy = ntfy_token(config["ntfy_token_file"])
    key = app_key(config["reader"], config["key_path"])
    api = config["github_api"]
    owner = config["owner"]
    repository = config["repository"]
    label = config["label"]
    token = installation_token(
        api,
        config["installation_id"],
        repository,
        app_token(config["app_id"], key),
    )
    try:
        opened = issues(
            api,
            token,
            owner,
            repository,
            {"state": "open", "labels": label, "per_page": 100},
        )
        recently_closed = issues(
            api,
            token,
            owner,
            repository,
            {
                "state": "closed",
                "labels": label,
                "since": since.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "per_page": 100,
            },
        )
    finally:
        revoke(api, token)
    opened = [item for item in opened if "pull_request" not in item]
    recently_closed = [
        item
        for item in recently_closed
        if "pull_request" not in item and closed_at(item) >= since
    ]
    if not opened and not recently_closed:
        return
    lines = [
        f"#{item['number']} {item['title']} {item['html_url']}"
        for item in [
            *sorted(opened, key=itemgetter("number")),
            *sorted(recently_closed, key=itemgetter("number")),
        ]
    ]
    status, _, _ = call(
        "ntfy",
        "POST",
        config["ntfy_url"],
        {
            "Authorization": f"Bearer {ntfy}",
            "Title": f"Tickets: {len(opened)} open, {len(recently_closed)} closed in the last day",
        },
        message(lines, owner, repository, label).encode(),
    )
    if status != 200:
        raise Failure(f"ticket-digest: ntfy refused the digest: {status}")


def main(argv):
    try:
        digest(argv)
    except Failure as failure:
        print(failure, file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - every failure must end as one line
        # Another error's text can hold what the digest was handling, such as a token in an
        # invalid header, and a traceback runs to many lines, so only its class is named.
        print(
            f"ticket-digest: unexpected error: {type(error).__name__}", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":  # pragma: no branch - importing does not run the CLI
    sys.exit(main(sys.argv[1:]))
