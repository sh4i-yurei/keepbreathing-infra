"""The hub verifier's observable result against the B2 native API stand-in."""

import importlib.util
from http.server import ThreadingHTTPServer
from pathlib import Path
import subprocess
import sys
from threading import Thread

import pytest
from load_source import load_source


HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "roles/b2_bucket/files/b2_verify.py"
FAKE = HERE / "b2_bucket/fake_b2.py"
verifier = load_source("ansible/roles/b2_bucket/files/b2_verify.py")
spec = importlib.util.spec_from_file_location("fake_b2_for_verify", FAKE)
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)


@pytest.fixture
def b2(tmp_path):
    fake.state = fake.State()
    fake.state.buckets.append({"bucketId": "bucket-1", "bucketName": "test-bucket"})
    fake.state.keys.append(
        {
            "applicationKeyId": "test-hub-id",
            "applicationKey": "test-hub-secret",
            "capabilities": ["listBuckets", "listFiles", "readFiles", "writeFiles"],
            "bucketIds": ["bucket-1"],
            "keyName": "test-hub",
        }
    )
    credential = tmp_path / "hub.env"
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=test-hub-secret\n"
    )
    server = ThreadingHTTPServer(("127.0.0.1", 0), fake.Handler)
    thread = Thread(target=server.serve_forever)
    thread.start()
    yield fake.state, f"http://127.0.0.1:{server.server_port}/b2api/v4/", credential
    server.shutdown()
    server.server_close()
    thread.join()


def run_verify(api, credential):
    return subprocess.run(
        [sys.executable, str(SCRIPT), api, str(credential), "bucket-1", "vaultserv"],
        capture_output=True,
        text=True,
        check=False,
    )


def test_hub_key_hides_refuses_version_delete_and_restores(b2):
    state, api, credential = b2
    result = run_verify(api, credential)
    assert result.returncode == 0, result.stderr
    assert result.stdout == "B2 hub key refusal and restore verified\n"
    names = [call["name"] for call in state.calls]
    assert names == [
        "b2_authorize_account",
        "b2_get_upload_url",
        "b2_upload_file",
        "b2_hide_file",
        "b2_delete_file_version",
        "b2_download_file_by_id",
        "b2_upload_file",
        "b2_list_file_versions",
    ]
    assert state.calls[4]["status"] == 401
    assert state.versions[0]["action"] == "upload"
    assert state.versions[0]["contentSha1"] == state.versions[2]["contentSha1"]


def test_verifier_function_restores_using_hub_key(b2):
    state, api, credential = b2
    verifier.verify(api, credential, "bucket-1", "vaultserv")
    assert [call["name"] for call in state.calls].count("b2_upload_file") == 2
    assert state.versions[0]["action"] == "upload"
    assert (
        state.calls[4]["request"]["fileName"] == state.calls[2]["request"]["fileName"]
    )
    assert state.calls[4]["request"]["fileId"] == state.versions[2]["fileId"]


@pytest.mark.parametrize(
    ("flag", "message"),
    [
        ("allow_delete_without_capability", "delete-refusal check failed"),
        ("bad_delete_json", "delete-refusal check failed"),
        ("reject_upload", "B2 upload returned 401"),
        ("bad_upload_sha1", "B2 upload SHA-1 mismatch"),
        ("bad_hide_action", "B2 hide check failed"),
        ("bad_download", "B2 hidden version restore download failed"),
        ("no_visible_versions", "B2 restored file is not visible"),
        ("wrong_visible_action", "B2 restored file is not visible"),
        ("wrong_visible_id", "B2 restored file is not visible"),
    ],
)
def test_hub_verifier_reports_rejected_behavior(b2, flag, message):
    state, api, credential = b2
    setattr(state, flag, True)
    result = run_verify(api, credential)
    assert result.returncode == 1
    assert result.stderr == f"B2 verification failed: {message}\n"
    assert "test-hub-secret" not in result.stdout + result.stderr


@pytest.mark.parametrize(
    ("flag", "message"),
    [
        ("allow_delete_without_capability", "delete-refusal check failed"),
        ("bad_delete_json", "delete-refusal check failed"),
        ("reject_upload", "B2 upload returned 401"),
        ("bad_upload_sha1", "B2 upload SHA-1 mismatch"),
        ("bad_hide_action", "B2 hide check failed"),
        ("bad_download", "B2 hidden version restore download failed"),
        ("no_visible_versions", "B2 restored file is not visible"),
        ("wrong_visible_action", "B2 restored file is not visible"),
        ("wrong_visible_id", "B2 restored file is not visible"),
    ],
)
def test_verifier_function_rejects_bad_b2_behavior(b2, flag, message):
    state, api, credential = b2
    setattr(state, flag, True)
    with pytest.raises(verifier.VerificationError) as raised:
        verifier.verify(api, credential, "bucket-1", "vaultserv")
    assert str(raised.value) == message


def test_invalid_hub_key_is_rejected_without_disclosing_it(b2):
    _state, api, credential = b2
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=wrong\n"
    )
    result = run_verify(api, credential)
    assert result.returncode == 1
    assert (
        result.stderr
        == "B2 verification failed: B2 b2_authorize_account returned 401 unauthorized\n"
    )
    assert "wrong" not in result.stdout + result.stderr


def test_invalid_hub_key_error_without_code_uses_unknown(b2):
    state, api, credential = b2
    state.auth_missing_code = True
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=wrong\n"
    )
    with pytest.raises(verifier.VerificationError) as raised:
        verifier.verify(api, credential, "bucket-1", "vaultserv")
    assert str(raised.value) == "B2 b2_authorize_account returned 401 unknown"


def test_invalid_hub_key_error_reports_exact_b2_code(b2):
    _state, api, credential = b2
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=wrong\n"
    )
    with pytest.raises(verifier.VerificationError) as raised:
        verifier.verify(api, credential, "bucket-1", "vaultserv")
    assert str(raised.value) == "B2 b2_authorize_account returned 401 unauthorized"


def test_credential_value_containing_equals_is_preserved(b2):
    state, api, credential = b2
    state.keys[-1]["applicationKey"] = "test=hub=secret"
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=test=hub=secret\n"
    )
    verifier.verify(api, credential, "bucket-1", "vaultserv")
    assert state.calls[0]["key"] == "test-hub-id"


@pytest.mark.parametrize("content", ["", "AWS_ACCESS_KEY_ID=test-hub-id\n"])
def test_incomplete_credential_file_fails(b2, content):
    _state, api, credential = b2
    credential.write_text(content)
    result = run_verify(api, credential)
    assert result.returncode == 1
    assert "B2 verification failed" in result.stderr


def test_malformed_credential_line_is_rejected(b2):
    _state, api, credential = b2
    credential.write_text(
        "AWS_ACCESS_KEY_ID=test-hub-id\nAWS_SECRET_ACCESS_KEY=test-hub-secret\nmalformed\n"
    )
    result = run_verify(api, credential)
    assert result.returncode == 1
    assert "B2 verification failed" in result.stderr


def test_verifier_function_rejects_malformed_credential(b2):
    _state, api, credential = b2
    credential.write_text("AWS_ACCESS_KEY_ID=test-hub-id\nmalformed\n")
    with pytest.raises(ValueError):
        verifier.verify(api, credential, "bucket-1", "vaultserv")
