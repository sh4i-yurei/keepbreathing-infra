#!/usr/bin/env python3
"""In-memory subset of the documented B2 v4 API for the role's CI cases."""

import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from urllib.parse import parse_qs, urlparse


MASTER_ID = "test-master-id"
MASTER_SECRET = "test-master-secret"
MASTER_CAPABILITIES = [
    "listBuckets",
    "writeBuckets",
    "writeBucketRetentions",
    "writeBucketLifecycleRules",
    "listKeys",
    "writeKeys",
    "deleteKeys",
    "listFiles",
    "readFiles",
    "writeFiles",
    "deleteFiles",
]
CAPABILITY = {
    "b2_list_buckets": "listBuckets",
    "b2_create_bucket": "writeBuckets",
    "b2_update_bucket": "writeBuckets",
    "b2_list_keys": "listKeys",
    "b2_create_key": "writeKeys",
    "b2_delete_key": "deleteKeys",
    "b2_get_upload_url": "writeFiles",
    "b2_upload_file": "writeFiles",
    "b2_hide_file": "writeFiles",
    "b2_list_file_versions": "listFiles",
    "b2_delete_file_version": "deleteFiles",
    "b2_download_file_by_id": "readFiles",
}


class State:
    def __init__(self):
        self.buckets = []
        self.keys = [
            {
                "applicationKeyId": MASTER_ID,
                "applicationKey": MASTER_SECRET,
                "capabilities": MASTER_CAPABILITIES,
                "bucketIds": None,
                "keyName": "master",
            }
        ]
        self.versions = []
        self.calls = []
        self.next_key = 1
        self.next_key_credentials = None
        self.s3_api_url = None
        self.next_file = 1
        self.page_size = 100
        self.duplicate_bucket = False
        self.allow_delete_without_capability = False
        self.reject_upload = False
        self.bad_upload_sha1 = False
        self.bad_hide_action = False
        self.bad_download = False
        self.no_visible_versions = False
        self.bad_delete_json = False
        self.wrong_visible_action = False
        self.wrong_visible_id = False
        self.auth_missing_code = False


state = State()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    @property
    def origin(self):
        return f"http://127.0.0.1:{self.server.server_port}"

    def send(self, status, value, binary=False):
        data = value if binary else json.dumps(value).encode()
        self.send_response(status)
        self.send_header(
            "Content-Type", "application/octet-stream" if binary else "application/json"
        )
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status, code, message):
        self.send(status, {"status": status, "code": code, "message": message})

    def actor(self, authorization):
        if authorization.startswith("Basic "):
            try:
                key_id, secret = (
                    base64.b64decode(authorization[6:]).decode().split(":", 1)
                )
            except (ValueError, UnicodeError):
                return None
            return next(
                (
                    key
                    for key in state.keys
                    if key["applicationKeyId"] == key_id
                    and key["applicationKey"] == secret
                ),
                None,
            )
        token = authorization.removeprefix("Bearer ")
        return next(
            (
                key
                for key in state.keys
                if token
                in (
                    "token-" + key["applicationKeyId"],
                    "upload-" + key["applicationKeyId"],
                )
            ),
            None,
        )

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        self.connection.settimeout(2)
        raw = self.rfile.read(length)
        if parsed.path == "/_state":
            self.send(
                200,
                {
                    "buckets": state.buckets,
                    "keys": state.keys,
                    "versions": [
                        {k: v for k, v in version.items() if k != "content"}
                        for version in state.versions
                    ],
                    "calls": state.calls,
                    "s3ApiUrl": self.origin,
                },
            )
            return
        if parsed.path == "/_control":
            command = json.loads(raw)
            action = command["action"]
            if action == "reset":
                state.__init__()
            elif action == "clear_calls":
                state.calls.clear()
            elif action == "remove_key":
                state.keys[:] = [
                    key
                    for key in state.keys
                    if key["applicationKeyId"] != command["id"]
                ]
            elif action == "change_key":
                key = next(
                    key
                    for key in state.keys
                    if key["applicationKeyId"] == command["id"]
                )
                key.update(command["values"])
                for field in command.get("remove", []):
                    key.pop(field, None)
            elif action == "change_bucket":
                state.buckets[0].update(command["values"])
            elif action == "page_size":
                state.page_size = command["value"]
            elif action == "add_key":
                state.keys.append(command["key"])
            elif action == "s3_api_url":
                state.s3_api_url = command["value"]
            elif action == "next_key":
                state.next_key_credentials = {
                    "applicationKeyId": command["applicationKeyId"],
                    "applicationKey": command["applicationKey"],
                    "extra_capabilities": command.get("extra_capabilities", []),
                }
            elif action == "duplicate_bucket":
                state.duplicate_bucket = True
            elif action == "allow_delete":
                state.allow_delete_without_capability = True
            elif action == "seed_restic_versions":
                for index in range(command["count"]):
                    state.versions.append(
                        {
                            "bucketId": "bucket-1",
                            "fileName": f"restic/{index:03d}",
                            "fileId": f"older-{index}",
                            "action": "upload",
                            "content": "",
                        }
                    )
            self.send(200, {"ok": True})
            return

        if not parsed.path.startswith("/b2api/v4/b2_"):
            self.error(404, "not_found", "Unknown native API path")
            return

        name = parsed.path.rsplit("/", 1)[-1]
        actor = self.actor(self.headers.get("Authorization", ""))
        actor_id = actor["applicationKeyId"] if actor else None
        params = parse_qs(parsed.query)
        payload = {} if name == "b2_upload_file" else (json.loads(raw) if raw else {})
        if name not in (
            "b2_authorize_account",
            "b2_download_file_by_id",
            "b2_upload_file",
        ):
            if self.headers.get("Content-Type", "").lower() != "application/json":
                self.error(400, "bad_request", "Expected JSON content type")
                return
        for field, values in params.items():
            payload.setdefault(field, values[0])
        call = {"name": name, "key": actor_id, "request": payload}
        state.calls.append(call)
        if name == "b2_authorize_account":
            if actor is None:
                call["status"] = 401
                if state.auth_missing_code:
                    self.send(
                        401, {"status": 401, "message": "Invalid application key"}
                    )
                else:
                    self.error(401, "unauthorized", "Invalid application key")
                return
            call["status"] = 200
            self.send(
                200,
                {
                    "accountId": "test-account",
                    "authorizationToken": "token-" + actor_id,
                    "apiInfo": {
                        "storageApi": {
                            "apiUrl": self.origin,
                            "downloadUrl": self.origin,
                            "s3ApiUrl": state.s3_api_url or self.origin,
                        }
                    },
                },
            )
            return
        capability = CAPABILITY.get(name)
        permitted = actor is not None and capability in actor["capabilities"]
        if (
            name == "b2_delete_file_version"
            and state.allow_delete_without_capability
            and actor
        ):
            permitted = True
        if not permitted:
            call["status"] = 401
            call["code"] = "unauthorized"
            if name == "b2_delete_file_version" and state.bad_delete_json:
                self.send(401, b"invalid", binary=True)
                return
            self.error(401, "unauthorized", "Application key lacks required capability")
            return
        if name == "b2_list_buckets":
            result = {"buckets": state.buckets}
        elif name == "b2_create_bucket":
            if state.duplicate_bucket or any(
                b["bucketName"] == payload["bucketName"] for b in state.buckets
            ):
                call["status"] = 400
                self.error(
                    400, "duplicate_bucket_name", "Bucket name is already in use"
                )
                return
            result = {
                "accountId": "test-account",
                "bucketId": "bucket-1",
                "bucketName": payload["bucketName"],
                "bucketType": payload["bucketType"],
                "fileLockConfiguration": {
                    "isClientAuthorizedToRead": True,
                    "value": {
                        "isFileLockEnabled": payload["fileLockEnabled"],
                        "defaultRetention": {"mode": None, "period": None},
                    },
                },
                "lifecycleRules": [
                    {
                        **rule,
                        "daysFromStartingToCancelingUnfinishedLargeFiles": rule.get(
                            "daysFromStartingToCancelingUnfinishedLargeFiles"
                        ),
                    }
                    for rule in payload.get("lifecycleRules", [])
                ],
                "revision": 1,
            }
            state.buckets.append(result)
        elif name == "b2_update_bucket":
            result = next(
                b for b in state.buckets if b["bucketId"] == payload["bucketId"]
            )
            for field in ("bucketType", "lifecycleRules"):
                if field in payload:
                    result[field] = payload[field]
            if "defaultRetention" in payload:
                result["fileLockConfiguration"]["value"]["defaultRetention"] = payload[
                    "defaultRetention"
                ]
            if "fileLockEnabled" in payload:
                result["fileLockConfiguration"]["value"]["isFileLockEnabled"] = payload[
                    "fileLockEnabled"
                ]
        elif name == "b2_list_keys":
            keys = sorted(state.keys, key=lambda key: key["applicationKeyId"])
            start = next(
                (
                    i
                    for i, key in enumerate(keys)
                    if key["applicationKeyId"]
                    >= payload.get("startApplicationKeyId", "")
                ),
                len(keys),
            )
            limit = min(int(payload.get("maxKeyCount", 100)), state.page_size)
            page = keys[start : start + limit]
            next_id = (
                keys[start + limit]["applicationKeyId"]
                if len(keys) > start + limit
                else None
            )
            result = {
                "keys": [
                    {k: v for k, v in key.items() if k != "applicationKey"}
                    for key in page
                ],
                "nextApplicationKeyId": next_id,
            }
        elif name == "b2_create_key":
            key_id = (
                state.next_key_credentials["applicationKeyId"]
                if state.next_key_credentials
                else f"test-key-{state.next_key:04d}"
            )
            result = {
                "accountId": "test-account",
                "applicationKeyId": key_id,
                "applicationKey": (
                    state.next_key_credentials["applicationKey"]
                    if state.next_key_credentials
                    else f"test-hub-secret-{state.next_key}"
                ),
                "capabilities": payload["capabilities"]
                + (
                    state.next_key_credentials["extra_capabilities"]
                    if state.next_key_credentials
                    else []
                ),
                "bucketIds": payload["bucketIds"],
                "keyName": payload["keyName"],
            }
            state.next_key += 1
            state.next_key_credentials = None
            state.keys.append(result)
        elif name == "b2_delete_key":
            credential = "/home/b2test/.config/b2/vaultserv.env"
            if os.path.exists(credential):
                call["credentialIdAtDelete"] = next(
                    (
                        line.partition("=")[2]
                        for line in open(credential).read().splitlines()
                        if line.startswith("AWS_ACCESS_KEY_ID=")
                    ),
                    None,
                )
            result = next(
                key
                for key in state.keys
                if key["applicationKeyId"] == payload["applicationKeyId"]
            )
            state.keys.remove(result)
            result = {k: v for k, v in result.items() if k != "applicationKey"}
        elif name == "b2_get_upload_url":
            result = {
                "bucketId": payload["bucketId"],
                "uploadUrl": self.origin + "/b2api/v4/b2_upload_file",
                "authorizationToken": "upload-" + actor_id,
            }
        elif name == "b2_upload_file":
            if state.reject_upload:
                call["status"] = 401
                self.error(401, "unauthorized", "Upload refused")
                return
            file_id = f"file-{state.next_file}"
            state.next_file += 1
            file_name = self.headers.get("X-Bz-File-Name")
            sha1 = hashlib.sha1(raw).hexdigest()
            if (
                not file_name
                or self.headers.get("Content-Type", "").lower() != "text/plain"
                or self.headers.get("X-Bz-Content-Sha1") != sha1
                or self.headers.get("Content-Length") != str(len(raw))
            ):
                call["status"] = 400
                self.error(400, "bad_request", "Invalid upload headers")
                return
            result = {
                "accountId": "test-account",
                "bucketId": "bucket-1",
                "action": "upload",
                "fileId": file_id,
                "fileName": file_name,
                "contentSha1": sha1,
                "contentLength": len(raw),
                "contentType": self.headers.get("Content-Type", "text/plain"),
            }
            state.versions.insert(
                0, result | {"content": base64.b64encode(raw).decode()}
            )
            call["request"] = {"fileName": file_name, "contentSha1": sha1}
            if state.bad_upload_sha1:
                result = result | {"contentSha1": "0" * 40}
        elif name == "b2_hide_file":
            result = {
                "accountId": "test-account",
                "bucketId": payload["bucketId"],
                "action": "hide",
                "fileId": f"file-{state.next_file}",
                "fileName": payload["fileName"],
                "contentSha1": hashlib.sha1(b"").hexdigest(),
                "contentLength": 0,
            }
            state.next_file += 1
            state.versions.insert(0, result | {"content": ""})
            if state.bad_hide_action:
                result = result | {"action": "upload"}
        elif name == "b2_delete_file_version":
            version = next(
                (v for v in state.versions if v["fileId"] == payload["fileId"]), None
            )
            if version is None or version["fileName"] != payload.get("fileName"):
                call["status"] = 404
                self.error(404, "not_found", "File version not found")
                return
            state.versions.remove(version)
            result = {"fileId": version["fileId"], "fileName": version["fileName"]}
        elif name == "b2_download_file_by_id":
            version = next(
                (v for v in state.versions if v["fileId"] == payload["fileId"]), None
            )
            if version is None:
                call["status"] = 404
                self.error(404, "not_found", "File version not found")
                return
            call["status"] = 200
            content = base64.b64decode(version["content"])
            self.send(200, b"wrong" if state.bad_download else content, binary=True)
            return
        elif name == "b2_list_file_versions":
            versions = sorted(
                (
                    version
                    for version in state.versions
                    if version["bucketId"] == payload["bucketId"]
                ),
                key=lambda version: version["fileName"],
            )
            if payload.get("prefix"):
                versions = [
                    version
                    for version in versions
                    if version["fileName"].startswith(payload["prefix"])
                ]
            if payload.get("startFileName"):
                start_name = payload["startFileName"]
                start_id = payload.get("startFileId")
                if start_id is None:
                    versions = [
                        version
                        for version in versions
                        if version["fileName"] >= start_name
                    ]
                else:
                    start = next(
                        (
                            index
                            for index, version in enumerate(versions)
                            if version["fileName"] == start_name
                            and version["fileId"] == start_id
                        ),
                        None,
                    )
                    versions = (
                        versions[start:]
                        if start is not None
                        else [
                            version
                            for version in versions
                            if version["fileName"] > start_name
                        ]
                    )
            limit = int(payload.get("maxFileCount") or 100)
            page = versions[:limit]
            following = versions[limit] if len(versions) > limit else None
            result = {
                "files": [
                    {k: v for k, v in version.items() if k != "content"}
                    for version in page
                ],
                "nextFileName": following["fileName"] if following else None,
                "nextFileId": following["fileId"] if following else None,
            }
            if state.no_visible_versions:
                result["files"] = []
            if state.wrong_visible_action and result["files"]:
                result["files"][0]["action"] = "hide"
            if state.wrong_visible_id and result["files"]:
                result["files"][0]["fileId"] = "wrong-file-id"
        else:
            call["status"] = 404
            self.error(404, "not_found", "Unknown endpoint")
            return
        call["status"] = 200
        self.send(200, result)


if __name__ == "__main__":
    ThreadingHTTPServer(
        ("127.0.0.1", int(os.environ.get("B2_FAKE_PORT", "18742"))), Handler
    ).serve_forever()
