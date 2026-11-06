"""Repository CI must exercise Python tests on every branch push."""

import hashlib
import json
from dataclasses import asdict
from pathlib import Path

import pytest
import yaml

from ci.run_driver import job_steps


ROOT = Path(__file__).resolve().parents[2]
COLLECTION_JOBS = (
    "b2-bucket",
    "b2-copy",
    "backup-server",
    "break-glass-sheet",
    "hub-backup-disk",
    "openbao",
    "vaultwarden-backup",
    "ansible-lint",
    "syntax-check",
)
INSTALL = "ansible-galaxy collection install -r collections/requirements.yml"
CACHE_KEY = "${{ runner.os }}-ansible-collections-${{ hashFiles('ansible/collections/requirements.yml') }}"


def workflow():
    return yaml.load(
        (ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
    )


@pytest.mark.parametrize("job", COLLECTION_JOBS)
def test_collection_install_has_immediately_preceding_cache(job):
    steps = workflow()["jobs"][job]["steps"]
    installs = [index for index, step in enumerate(steps) if step.get("run") == INSTALL]
    assert len(installs) == 1
    install_index = installs[0]
    assert steps[install_index] == {"run": INSTALL}
    assert steps[install_index - 1] == {
        "uses": "actions/cache@v6",
        "with": {
            "path": "~/.ansible/collections",
            "key": CACHE_KEY,
        },
    }


@pytest.mark.parametrize(
    ("job", "expected_digest"),
    [
        (
            "openbao",
            "aa5f4ce904b9d407c33220753ef8de291395e5d3ff904cff21f734c04996f4cf",
        ),
        (
            "b2-bucket",
            "eb8c64a127e9dd54f7797369fad67e579971e9fce43cdb06d3d856d8da7de97d",
        ),
    ],
)
def test_local_runner_run_steps_match_main(job, expected_digest):
    steps = job_steps(ROOT / ".github/workflows/ci.yml", job)
    encoded = json.dumps([asdict(step) for step in steps], sort_keys=True).encode()
    digest = hashlib.sha256(encoded).hexdigest()
    assert digest == expected_digest


def test_architecture_describes_collection_cache_and_python_exception():
    row = next(
        line
        for line in (ROOT / "ARCHITECTURE.md").read_text().splitlines()
        if line.startswith("| `.github/workflows/ci.yml` |")
    )
    assert (
        "nine jobs restore Ansible collections from a cache keyed on `ansible/collections/requirements.yml`"
        in row
    )
    assert (
        "the `python` job's install runs in `ci-workflows`' shared workflow without it"
        in row
    )


def test_python_job_and_all_branch_push_trigger() -> None:
    data = workflow()
    assert data["on"] == {"push": {}, "pull_request": {}}
    assert data["jobs"]["python"]["uses"] == (
        "sh4i-yurei/ci-workflows/.github/workflows/python.yml"
        "@6fa70095587800bf834d27d1cf2313a7b8dbb168"
    )
    assert data["jobs"]["python"]["with"] == {
        "coverage_floor": "100",
        "caller_workflow": ".github/workflows/ci.yml",
        "caller_job": "python",
        "install_command": (
            "sudo apt-get update && sudo apt-get install -y podman && "
            "python -m pip install -r requirements.txt pytest==9.1.1 "
            "pytest-cov==7.1.0 && ansible-galaxy collection install "
            "-r ansible/collections/requirements.yml"
        ),
    }
