"""A stand-in for Tailscale's serve proxy in front of OpenBao, for the openbao_client driver.

It listens on 127.0.0.1:18300 and forwards every request to OpenBao on 127.0.0.1:8200 with
X-Forwarded-For set to the address given on its command line, the way the proxy in front of
svc:openbao adds the client's tailnet address (OpenBao on the hub decision 16).

Usage: python3 proxy.py <client address>
"""

import http.client
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = ("127.0.0.1", 18300)
UPSTREAM = ("127.0.0.1", 8200)
# Headers that belong to one connection, never forwarded (RFC 9110 section 7.6.1).
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


def handler(client_address):
    class Forward(BaseHTTPRequestHandler):
        def forward(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else None
            headers = {
                name: value
                for name, value in self.headers.items()
                if name.lower() not in HOP_BY_HOP and name.lower() != "x-forwarded-for"
            }
            headers["X-Forwarded-For"] = client_address
            upstream = http.client.HTTPConnection(*UPSTREAM, timeout=30)
            try:
                upstream.request(self.command, self.path, body=body, headers=headers)
                response = upstream.getresponse()
                data = response.read()
            finally:
                upstream.close()
            self.send_response(response.status)
            for name, value in response.getheaders():
                if name.lower() not in HOP_BY_HOP:
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    for method in ("GET", "POST", "PUT", "PATCH", "DELETE", "LIST"):
        setattr(Forward, "do_" + method, Forward.forward)
    return Forward


def main(argv):
    server = ThreadingHTTPServer(LISTEN, handler(argv[0]))
    print(f"forwarding {LISTEN[0]}:{LISTEN[1]} as {argv[0]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
