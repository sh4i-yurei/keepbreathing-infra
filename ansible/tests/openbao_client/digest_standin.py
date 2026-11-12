"""Stand-ins for GitHub and ntfy, for the openbao_client driver's run of the morning digest.

GitHub listens on 127.0.0.1:18400 and ntfy on 127.0.0.1:18401 (OpenBao on the hub 4.5). GitHub's
token request answers 201 with an installation token only when the App token verifies with the
public key under RS256, and 401 otherwise. The open list holds one ticket and the closed list
none, and they answer only the installation token. The revoke answers 204, and ntfy's post 200.
Each request appends one JSON line to the log: the server, method, path and, for ntfy, the
Authorization and Title headers and the body. The App token itself is never logged.

Usage: python3 digest_standin.py <public key file> <log file>
"""

import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import jwt

GITHUB = ("127.0.0.1", 18400)
NTFY = ("127.0.0.1", 18401)
INSTALLATION_TOKEN = "ghs_driverStandinInstallationToken0123456789"
TOKEN_PATH = "/app/installations/1/access_tokens"
ISSUES_PATH = "/repos/sh4i-yurei/platform-tickets/issues"
TICKET = {
    "number": 1,
    "title": "A stand-in ticket",
    "html_url": "https://github.com/sh4i-yurei/platform-tickets/issues/1",
    "state": "open",
    "closed_at": None,
    "labels": [{"name": "ticket"}],
}


def handler(server_name, public_key, log, lock):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def record(self, entry):
            with lock, log.open("a") as stream:
                stream.write(json.dumps(entry) + "\n")

        def send(self, status, payload=None):
            data = b"" if payload is None else json.dumps(payload).encode()
            self.send_response(status)
            if data:
                self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def answer(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length)
            parts = urlsplit(self.path)
            entry = {"server": server_name, "method": self.command, "path": parts.path}
            if server_name == "ntfy":
                entry |= {
                    "authorization": self.headers.get("Authorization"),
                    "title": self.headers.get("Title"),
                    "body": body.decode("utf-8", "replace"),
                }
                self.record(entry)
                self.send(
                    200, {"id": "standin", "event": "message", "topic": "tickets"}
                )
                return
            authorization = self.headers.get("Authorization", "")
            if (self.command, parts.path) == ("POST", TOKEN_PATH):
                scheme, _, token = authorization.partition(" ")
                try:
                    claims = jwt.decode(token, public_key, algorithms=["RS256"])
                except jwt.InvalidTokenError:
                    claims = None
                entry |= {
                    "verified": scheme == "Bearer" and claims is not None,
                    "claims": claims,
                }
                self.record(entry)
                if entry["verified"]:
                    self.send(201, {"token": INSTALLATION_TOKEN})
                else:
                    self.send(401, {"message": "A JSON web token could not be decoded"})
                return
            entry["installation_token"] = (
                authorization == f"Bearer {INSTALLATION_TOKEN}"
            )
            if self.command == "GET":
                entry["query"] = parse_qs(parts.query)
            self.record(entry)
            if not entry["installation_token"]:
                self.send(401, {"message": "Bad credentials"})
            elif (self.command, parts.path) == ("DELETE", "/installation/token"):
                self.send(204)
            elif (self.command, parts.path) == ("GET", ISSUES_PATH):
                state = entry["query"].get("state", [""])[0]
                self.send(200, [TICKET] if state == "open" else [])
            else:
                self.send(404, {"message": "Not Found"})

        do_GET = do_POST = do_DELETE = answer

    return Handler


def main(argv):
    public_key = Path(argv[0]).read_text()
    log = Path(argv[1])
    lock = threading.Lock()
    servers = [
        ThreadingHTTPServer(GITHUB, handler("github", public_key, log, lock)),
        ThreadingHTTPServer(NTFY, handler("ntfy", public_key, log, lock)),
    ]
    threading.Thread(target=servers[1].serve_forever, daemon=True).start()
    print(f"github on {GITHUB[0]}:{GITHUB[1]}, ntfy on {NTFY[0]}:{NTFY[1]}", flush=True)
    servers[0].serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
