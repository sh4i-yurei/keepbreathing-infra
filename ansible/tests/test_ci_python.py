"""Repository CI must exercise Python tests on every branch push."""

from pathlib import Path

import yaml


def test_python_job_and_all_branch_push_trigger() -> None:
    root = Path(__file__).resolve().parents[2]
    workflow = yaml.load(
        (root / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
    )
    assert workflow["on"]["push"] == {}
    assert workflow["jobs"]["python"]["uses"] == (
        "sh4i-yurei/ci-workflows/.github/workflows/python.yml"
        "@c8ff45953cad54fb860d41e4687b8542d5212109"
    )
    assert workflow["jobs"]["python"]["with"]["coverage_floor"] == "100"
