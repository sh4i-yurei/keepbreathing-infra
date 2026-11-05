"""Repository CI must exercise Python tests on every branch push."""

from pathlib import Path

import yaml


def test_python_job_and_all_branch_push_trigger() -> None:
    root = Path(__file__).resolve().parents[2]
    workflow = yaml.load(
        (root / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
    )
    assert workflow["on"] == {"push": {}}
    assert workflow["jobs"]["python"]["uses"] == (
        "sh4i-yurei/ci-workflows/.github/workflows/python.yml"
        "@6fa70095587800bf834d27d1cf2313a7b8dbb168"
    )
    assert workflow["jobs"]["python"]["with"] == {
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
