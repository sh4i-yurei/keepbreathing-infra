"""Assertions about the fake B2 API and runner-visible role effects."""

import json
from pathlib import Path
import stat
import sys


state = json.load(sys.stdin)
case = sys.argv[1]
file = Path("/home/b2test/.config/b2/vaultserv.env")
bucket_name = "keepbreathing-vaultserv-backup"
capabilities = {"listBuckets", "listFiles", "readFiles", "writeFiles"}
retention = {"mode": "compliance", "period": {"duration": 30, "unit": "days"}}
lifecycle = [
    {
        "daysFromHidingToDeleting": 30,
        "daysFromUploadingToHiding": None,
        "fileNamePrefix": "",
    }
]
calls = state["calls"]


def assert_bucket():
    assert len(state["buckets"]) == 1, state["buckets"]
    bucket = state["buckets"][0]
    assert bucket["bucketName"] == bucket_name
    assert bucket["bucketType"] == "allPrivate"
    assert bucket["fileLockConfiguration"]["value"] == {
        "isFileLockEnabled": True,
        "defaultRetention": retention,
    }
    assert bucket["lifecycleRules"] == lifecycle
    return bucket


def assert_key(extra_keys=False):
    bucket = assert_bucket()
    keys = [key for key in state["keys"] if key["applicationKeyId"] != "test-master-id"]
    assert len(keys) == (2 if extra_keys else 1), keys
    assert file.is_file()
    stored_id = next(
        line.partition("=")[2]
        for line in file.read_text().splitlines()
        if line.startswith("AWS_ACCESS_KEY_ID=")
    )
    key = next(key for key in keys if key["applicationKeyId"] == stored_id)
    assert set(key["capabilities"]) == capabilities
    assert len(key["capabilities"]) == 4
    assert key["bucketIds"] == [bucket["bucketId"]]
    info = file.stat()
    assert stat.S_IMODE(info.st_mode) == 0o600
    assert info.st_uid == __import__("pwd").getpwnam("b2test").pw_uid
    contents = dict(line.split("=", 1) for line in file.read_text().splitlines())
    assert contents == {
        "AWS_ACCESS_KEY_ID": key["applicationKeyId"],
        "AWS_SECRET_ACCESS_KEY": key["applicationKey"],
        "RESTIC_REPOSITORY": f"s3:{state['s3ApiUrl']}/{bucket_name}/restic",
    }
    return key


def named(name):
    return [call for call in calls if call["name"] == name]


if case == "check":
    assert not file.exists()
    assert not file.parent.exists()
    for name in (
        "b2_create_bucket",
        "b2_update_bucket",
        "b2_create_key",
        "b2_delete_key",
    ):
        assert not named(name), name
elif case == "first":
    key = assert_key()
    uploads = named("b2_upload_file")
    assert len(uploads) == 2, uploads
    assert all(call["key"] == key["applicationKeyId"] for call in uploads)
    assert uploads[0]["request"]["fileName"].startswith("verify/")
    assert uploads[1]["request"]["fileName"] == uploads[0]["request"]["fileName"]
    assert uploads[1]["request"]["contentSha1"] == uploads[0]["request"]["contentSha1"]
    hide = named("b2_hide_file")
    assert len(hide) == 1 and hide[0]["status"] == 200
    assert hide[0]["key"] == key["applicationKeyId"]
    assert hide[0]["request"]["fileName"] == uploads[0]["request"]["fileName"]
    delete = named("b2_delete_file_version")
    assert len(delete) == 1 and delete[0]["status"] == 401
    assert delete[0]["code"] == "unauthorized"
    assert delete[0]["key"] == key["applicationKeyId"]
    assert delete[0]["request"]["fileId"] == state["versions"][-1]["fileId"]
    download = named("b2_download_file_by_id")
    assert len(download) == 1 and download[0]["key"] == key["applicationKeyId"]
    assert download[0]["request"]["fileId"] == delete[0]["request"]["fileId"]
    assert any(
        v["action"] == "upload" and v["fileName"] == uploads[0]["request"]["fileName"]
        for v in state["versions"]
    )
    assert len(named("b2_list_file_versions")) == 1
    assert named("b2_list_file_versions")[0]["key"] == key["applicationKeyId"]
    assert named("b2_get_upload_url")[0]["key"] == key["applicationKeyId"]
elif case == "idempotent":
    assert_key()
    for name in (
        "b2_create_bucket",
        "b2_update_bucket",
        "b2_create_key",
        "b2_delete_key",
    ):
        assert not named(name), name
elif case == "new_key":
    assert_key()
    assert len(named("b2_create_key")) == 1
    assert not named("b2_delete_key")
elif case == "replaced_key":
    key = assert_key()
    assert len(named("b2_create_key")) == 1
    assert len(named("b2_delete_key")) == 1
    assert (
        named("b2_delete_key")[0]["request"]["applicationKeyId"]
        != key["applicationKeyId"]
    )
    assert named("b2_delete_key")[0]["credentialIdAtDelete"] == key["applicationKeyId"]
elif case == "drift":
    assert_bucket()
    assert len(named("b2_update_bucket")) == 1
elif case == "legacy":
    assert not named("b2_create_key") and not named("b2_delete_key")
elif case == "paged":
    assert_key(extra_keys=True)
    assert len(named("b2_list_keys")) >= 2
    assert not named("b2_create_key")
elif case == "duplicate":
    assert not file.exists()
    assert not named("b2_create_key")
elif case == "config":
    assert_key()
    config = file.parent.parent.stat()
    directory = file.parent.stat()
    user = __import__("pwd").getpwnam("b2test")
    assert stat.S_IMODE(config.st_mode) == 0o755
    assert config.st_uid == user.pw_uid and config.st_gid == 0
    assert stat.S_IMODE(directory.st_mode) == 0o700
    assert directory.st_uid == user.pw_uid and directory.st_gid == user.pw_gid
elif case == "missing":
    assert calls == []
else:
    raise AssertionError(f"unknown assertion case {case}")
