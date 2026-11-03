#!/usr/bin/env python3
"""Verify B2 refusal and restore behavior using the key kept on the hub."""

import base64
import hashlib
import json
from pathlib import Path
import sys
import time
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen


class VerificationError(Exception):
    pass


def request(url, token, body=None, headers=None, method=None):
    fields = dict(headers or {})
    fields["Authorization"] = token
    data = None if body is None else json.dumps(body).encode()
    if data is not None:
        fields["Content-Type"] = "application/json"
    req = Request(url, data=data, headers=fields, method=method)
    try:
        with urlopen(req, timeout=30) as response:
            content = response.read()
            return response.status, content
    except HTTPError as error:
        return error.code, error.read()


def json_request(url, token, body=None):
    status, raw = request(url, token, body)
    value = json.loads(raw)
    if status != 200:
        raise VerificationError(
            f"B2 {url.rsplit('/', 1)[-1]} returned {status} {value.get('code', 'unknown')}"
        )
    return value


def credential(path):
    return dict(line.split("=", 1) for line in Path(path).read_text().splitlines())


def upload(upload_url, upload_token, name, content):
    headers = {
        "Authorization": upload_token,
        "X-Bz-File-Name": quote(name, safe="/"),
        "Content-Type": "text/plain",
        "Content-Length": str(len(content)),
        "X-Bz-Content-Sha1": hashlib.sha1(content).hexdigest(),
    }
    req = Request(upload_url, data=content, headers=headers, method="POST")
    try:
        with urlopen(req, timeout=30) as response:
            value = json.load(response)
    except HTTPError as error:
        raise VerificationError(f"B2 upload returned {error.code}") from error
    if value["contentSha1"] != hashlib.sha1(content).hexdigest():
        raise VerificationError("B2 upload SHA-1 mismatch")
    return value


def verify(api_url, key_file, bucket_id, machine):
    values = credential(key_file)
    basic = base64.b64encode(
        (values["AWS_ACCESS_KEY_ID"] + ":" + values["AWS_SECRET_ACCESS_KEY"]).encode()
    ).decode()
    auth = json_request(api_url + "b2_authorize_account", "Basic " + basic)
    storage = auth["apiInfo"]["storageApi"]
    base = storage["apiUrl"] + "/b2api/v4/"
    token = auth["authorizationToken"]
    name = f"verify/{machine}-{time.time_ns()}.txt"
    content = b"B2 backup key verification\n"
    target = json_request(base + "b2_get_upload_url", token, {"bucketId": bucket_id})
    first = upload(target["uploadUrl"], target["authorizationToken"], name, content)
    hidden = json_request(
        base + "b2_hide_file", token, {"bucketId": bucket_id, "fileName": name}
    )
    if hidden["action"] != "hide" or hidden["fileName"] != name:
        raise VerificationError("B2 hide check failed")
    status, raw = request(
        base + "b2_delete_file_version",
        token,
        {"fileName": name, "fileId": first["fileId"]},
    )
    try:
        refused = json.loads(raw)
    except ValueError:
        refused = {}
    if status != 401 or refused.get("code") != "unauthorized":
        raise VerificationError("delete-refusal check failed")
    download_url = (
        storage["downloadUrl"]
        + "/b2api/v4/b2_download_file_by_id?"
        + urlencode({"fileId": first["fileId"]})
    )
    status, restored = request(download_url, token)
    if status != 200 or hashlib.sha1(restored).hexdigest() != first["contentSha1"]:
        raise VerificationError("B2 hidden version restore download failed")
    second = upload(target["uploadUrl"], target["authorizationToken"], name, restored)
    versions = json_request(
        base + "b2_list_file_versions",
        token,
        {"bucketId": bucket_id, "startFileName": name},
    )
    visible = next(
        (item for item in versions["files"] if item["fileName"] == name), None
    )
    if (
        visible is None
        or visible["action"] != "upload"
        or visible["fileId"] != second["fileId"]
    ):
        raise VerificationError("B2 restored file is not visible")


if __name__ == "__main__":
    try:
        verify(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    except (VerificationError, KeyError, OSError, ValueError) as error:
        print(f"B2 verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("B2 hub key refusal and restore verified")
