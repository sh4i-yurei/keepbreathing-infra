"""A listener that accepts every connection and never answers, for the openbao_backup driver.

It listens on 127.0.0.1:18301 and keeps each accepted connection open without reading from it or
writing to it, so a client such as bao waits until its own timeout.

Usage: python3 blackhole.py
"""

import socket

LISTEN = ("127.0.0.1", 18301)


def main():
    server = socket.create_server(LISTEN)
    print(f"accepting on {LISTEN[0]}:{LISTEN[1]} and never answering", flush=True)
    held = []
    while True:
        connection, _ = server.accept()
        # The list keeps each socket referenced, so none is closed by garbage collection.
        held.append(connection)


if __name__ == "__main__":
    main()
