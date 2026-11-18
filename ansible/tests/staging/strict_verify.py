"""Prove that Python's strict TLS verifier accepts the generated Mailpit chain."""

import socket
import ssl
import sys
import threading


def main() -> None:
    folder = sys.argv[1]
    server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server.load_cert_chain(f"{folder}/mailpit.crt", f"{folder}/mailpit.key")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)

    def accept_one() -> None:
        try:
            with server.wrap_socket(listener.accept()[0], server_side=True) as peer:
                peer.recv(1)
        finally:
            listener.close()

    worker = threading.Thread(target=accept_one)
    worker.start()
    client = ssl.create_default_context(cafile=f"{folder}/ca.crt")
    assert client.verify_flags & ssl.VERIFY_X509_STRICT
    with socket.create_connection(listener.getsockname()) as raw:
        with client.wrap_socket(raw, server_hostname="mailpit.staging") as peer:
            peer.sendall(b"x")
            version = peer.version()
    worker.join()
    print(f"PASS strict verify: {version}")


if __name__ == "__main__":
    main()
