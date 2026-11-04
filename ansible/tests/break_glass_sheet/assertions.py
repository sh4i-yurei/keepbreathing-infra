"""Check externally visible fake B2 calls and printed sheet."""

import json
import sys
from datetime import datetime, timezone


case = sys.argv[1]
if case == "sheet":
    output = sys.stdin.read()
    marker = "TASK [break_glass_sheet : Break-glass sheet | Print the sheet]"
    assert output.count(marker) == 1, output
    before, after = output.split(marker)
    assert "test-glass-secret" not in before
    rendered = after.split("PLAY RECAP", 1)[0]
    value = json.JSONDecoder().raw_decode(rendered[rendered.index("{") :])[0]["msg"]
    date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    endpoint = "http://s3.us-east-1.seaweedfs.test:8333"
    expected = [
        "BREAK-GLASS SHEET",
        f"Made: {date}",
        "B2 key ID: test-key-glass",
        "B2 key: test-glass-secret",
        f"S3 endpoint: {endpoint}",
        "testhost: bucket b2glass-locked, repository password test-b2-password",
        "testhost restore: podman run --rm --network host -e AWS_ACCESS_KEY_ID=test-key-glass "
        "-e AWS_SECRET_ACCESS_KEY=test-glass-secret -e RESTIC_PASSWORD=test-b2-password "
        "-v ./restore:/restore:Z docker.io/restic/restic:0.19.1 "
        f"-r s3:{endpoint}/b2glass-locked/restic --no-lock restore latest --target /restore --verify",
    ]
    assert value == expected, (value, expected)
    sys.exit(0)

state = json.load(sys.stdin)
calls = state["calls"]
create = [call for call in calls if call["name"] == "b2_create_key"]
delete = [call for call in calls if call["name"] == "b2_delete_key"]
if case == "no_writes":
    assert not create and not delete, (create, delete)
elif case == "rotated":
    assert len(create) == 1, create
    assert create[0]["request"] == {
        "accountId": "test-account",
        "keyName": "break-glass-sheet",
        "capabilities": ["listBuckets", "listFiles", "readFiles"],
        "bucketIds": ["bucket-1"],
    }, create
    assert [call["request"]["applicationKeyId"] for call in delete] == [
        "old-glass-1",
        "old-glass-2",
    ], delete
    assert calls.index(create[0]) < calls.index(delete[0])
    assert [
        key["applicationKeyId"]
        for key in state["keys"]
        if key["keyName"] == "break-glass-sheet"
    ] == ["test-key-glass"]
elif case == "rolled_back":
    assert len(create) == 1, create
    assert [call["request"]["applicationKeyId"] for call in delete] == [
        "test-key-glass"
    ], delete
    assert calls.index(create[0]) < calls.index(delete[0])
    assert [
        key["applicationKeyId"]
        for key in state["keys"]
        if key["keyName"] == "break-glass-sheet"
    ] == [
        "old-glass-1",
        "old-glass-2",
    ]
else:
    raise AssertionError(case)
