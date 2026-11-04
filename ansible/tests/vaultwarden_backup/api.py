#!/usr/bin/env python3
"""Create test data through Vaultwarden 1.37.2's HTTP API."""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE = "http://127.0.0.1:8080"


def request(path, data, *, token=None, content_type="application/json"):
    body = json.dumps(data).encode() if content_type == "application/json" else data
    headers = {"Content-Type": content_type}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(BASE + path, data=body, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raise RuntimeError(
            f"Vaultwarden API {path} returned HTTP {error.code}: {error.read().decode()}"
        ) from error


def login():
    body = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": "web",
            "scope": "api offline_access",
            "username": os.environ["TEST_EMAIL"],
            "password": os.environ["TEST_VAULT_PASSWORD"],
            "device_identifier": str(uuid.uuid4()),
            "device_name": "CI",
            "device_type": "10",
        }
    ).encode()
    result = request(
        "/identity/connect/token",
        body,
        content_type="application/x-www-form-urlencoded",
    )
    return result["access_token"]


def create_cipher(token, number):
    result = request(
        "/api/ciphers",
        {
            "type": 2,
            "name": f"encrypted-test-item-{number}",
            "secureNote": {"type": 0},
        },
        token=token,
    )
    return result["id"]


def seed():
    request(
        "/identity/accounts/register",
        {
            "email": os.environ["TEST_EMAIL"],
            "name": "CI vault",
            "masterPasswordHash": os.environ["TEST_VAULT_PASSWORD"],
            "key": os.environ["TEST_VAULT_KEY"],
            "kdf": 0,
            "kdfIterations": 600000,
        },
    )
    token = login()
    first = create_cipher(token, 1)
    create_cipher(token, 2)
    content = b"harmless Vaultwarden backup attachment\n"
    info = request(
        f"/api/ciphers/{first}/attachment/v2",
        {
            "fileName": "proof.txt",
            "fileSize": len(content),
            "key": "test-attachment-key",
        },
        token=token,
    )
    boundary = "vaultwarden-backup-test"
    payload = (
        (
            f'--{boundary}\r\nContent-Disposition: form-data; name="data"; filename="proof.txt"\r\n'
            "Content-Type: application/octet-stream\r\n\r\n"
        ).encode()
        + content
        + f"\r\n--{boundary}--\r\n".encode()
    )
    request(
        info["url"].replace("/ciphers/", "/api/ciphers/", 1),
        payload,
        token=token,
        content_type=f"multipart/form-data; boundary={boundary}",
    )


if __name__ == "__main__":
    if sys.argv[1] == "seed":
        seed()
    elif sys.argv[1] == "third":
        create_cipher(login(), 3)
    else:
        raise SystemExit("expected seed or third")
