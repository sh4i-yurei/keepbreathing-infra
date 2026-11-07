"""Repository CI must exercise Python tests on every branch push."""

from pathlib import Path

import pytest
import yaml

from ci.run_driver import job_steps


ROOT = Path(__file__).resolve().parents[2]
COLLECTION_JOBS = (
    "b2-bucket",
    "b2-copy",
    "backup-prune",
    "backup-server",
    "break-glass-sheet",
    "hub-backup-disk",
    "hub-pull",
    "openbao",
    "ticket-band",
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


def test_collection_install_has_immediately_preceding_cache():
    jobs = workflow()["jobs"]
    collection_jobs = {
        name
        for name, job in jobs.items()
        if any(step.get("run") == INSTALL for step in job.get("steps", []))
    }
    assert collection_jobs == set(COLLECTION_JOBS)
    for name in sorted(collection_jobs):
        steps = jobs[name]["steps"]
        installs = [
            index for index, step in enumerate(steps) if step.get("run") == INSTALL
        ]
        assert len(installs) == 1, name
        install_index = installs[0]
        assert steps[install_index] == {"run": INSTALL}, name
        assert steps[install_index - 1] == {
            "uses": "actions/cache@v6",
            "with": {
                "path": "~/.ansible/collections",
                "key": CACHE_KEY,
            },
        }, name


@pytest.mark.parametrize("job", ("openbao", "b2-bucket", "ticket-band"))
def test_local_runner_run_steps_match_main(job, tmp_path):
    source = ROOT / ".github/workflows/ci.yml"
    data = workflow()
    for spec in data["jobs"].values():
        if "steps" in spec:
            spec["steps"] = [
                step
                for step in spec["steps"]
                if not step.get("uses", "").startswith("actions/cache@")
            ]
    without_cache = tmp_path / "ci.yml"
    without_cache.write_text(yaml.safe_dump(data))
    assert job_steps(source, job) == job_steps(without_cache, job)


def test_architecture_describes_collection_cache_and_python_exception():
    row = next(
        line
        for line in (ROOT / "ARCHITECTURE.md").read_text().splitlines()
        if line.startswith("| `.github/workflows/ci.yml` |")
    )
    assert (
        "twelve jobs restore Ansible collections from a cache keyed on `ansible/collections/requirements.yml`"
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
