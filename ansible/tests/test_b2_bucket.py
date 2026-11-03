"""B2 bucket reconciliation through its Ansible filter interface."""

from pathlib import Path

import yaml
from load_source import load_source
import pytest


ROOT = Path(__file__).resolve().parents[1]
module = load_source("ansible/filter_plugins/b2_bucket.py")


def test_documented_created_bucket_needs_retention_and_lifecycle_update():
    # Fields and values from b2_create_bucket's documented response example.
    example = {
        "bucketType": "allPrivate",
        "fileLockConfiguration": {
            "isClientAuthorizedToRead": True,
            "value": {
                "isFileLockEnabled": True,
                "defaultRetention": {"mode": None, "period": None},
            },
        },
        "lifecycleRules": [],
    }
    assert example["fileLockConfiguration"]["value"]["isFileLockEnabled"] is True
    assert module.b2_bucket_plan(example, 30, 30) == {"create": False, "update": True}


def test_absent_bucket_needs_creation():
    assert module.b2_bucket_plan(None, 30, 30) == {"create": True, "update": False}


def test_matching_bucket_needs_no_change():
    bucket = {
        "bucketType": "allPrivate",
        "fileLockConfiguration": {
            "value": {
                "isFileLockEnabled": True,
                "defaultRetention": {
                    "mode": "compliance",
                    "period": {"duration": 30, "unit": "days"},
                },
            }
        },
        "lifecycleRules": [
            {
                "daysFromHidingToDeleting": 30,
                "daysFromUploadingToHiding": None,
                "fileNamePrefix": "",
            }
        ],
    }
    assert module.b2_bucket_plan(bucket, 30, 30) == {"create": False, "update": False}


def test_filter_interface_exposes_bucket_plan():
    assert module.FilterModule().filters()["b2_bucket_plan"] is module.b2_bucket_plan


def test_bucket_without_file_lock_configuration_needs_update():
    bucket = {"bucketType": "allPrivate", "lifecycleRules": []}
    assert module.b2_bucket_plan(bucket, 30, 30) == {"create": False, "update": True}


@pytest.mark.parametrize(
    "changed",
    [
        {"bucketType": "allPublic"},
        {"fileLockConfiguration": {"value": {"isFileLockEnabled": False}}},
        {
            "fileLockConfiguration": {
                "value": {
                    "isFileLockEnabled": True,
                    "defaultRetention": {"mode": "governance"},
                }
            }
        },
        {"lifecycleRules": []},
        {"fileLockConfiguration": {}},
    ],
)
def test_existing_bucket_drift_needs_exact_update(changed):
    bucket = {
        "bucketType": "allPrivate",
        "fileLockConfiguration": {
            "value": {
                "isFileLockEnabled": True,
                "defaultRetention": {
                    "mode": "compliance",
                    "period": {"duration": 30, "unit": "days"},
                },
            }
        },
        "lifecycleRules": [
            {
                "daysFromHidingToDeleting": 30,
                "daysFromUploadingToHiding": None,
                "fileNamePrefix": "",
            }
        ],
    }
    bucket.update(changed)
    assert module.b2_bucket_plan(bucket, 30, 30) == {"create": False, "update": True}


def test_master_api_calls_are_controller_only():
    tasks = [
        task
        for path in (ROOT / "roles/b2_bucket/tasks").glob("*.yml")
        for task in yaml.safe_load(path.read_text())
    ]
    master_calls = [
        task
        for task in tasks
        if "ansible.builtin.uri" in task
        and (
            "b2_bucket_master_auth" in str(task["ansible.builtin.uri"])
            or "b2_master_key" in str(task["ansible.builtin.uri"])
        )
    ]
    assert len(master_calls) >= 8
    for task in master_calls:
        assert task["delegate_to"] == "localhost", task["name"]
        assert task["become"] is False, task["name"]
        assert task["run_once"] is True, task["name"]
        assert task["no_log"] is True, task["name"]


def test_role_argument_validation_never_sends_master_credential_to_hub():
    spec = yaml.safe_load(
        (ROOT / "roles/b2_bucket/meta/argument_specs.yml").read_text()
    )["argument_specs"]["main"]["options"]
    assert "b2_master_key" not in spec
    assert "b2_master_key_id" not in spec


def test_ci_runs_b2_driver_on_every_branch_push():
    workflow = yaml.load(
        (ROOT.parent / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
    )
    assert workflow["on"]["push"] == {}
    assert "b2-bucket" in workflow["jobs"]
    commands = [
        step["run"] for step in workflow["jobs"]["b2-bucket"]["steps"] if "run" in step
    ]
    assert any(
        "sudo" in command and "tests/b2_bucket/run.sh" in command
        for command in commands
    )
