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
        "@8d1ea0f42d357f6639eda1ac9359b9b1420d8789"
    )
    assert workflow["jobs"]["python"]["with"]["coverage_floor"] == "100"
