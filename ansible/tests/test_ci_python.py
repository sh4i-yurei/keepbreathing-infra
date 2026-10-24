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
        "@95383033d70f2b91d79792739806b44e1a9bf754"
    )
    assert workflow["jobs"]["python"]["with"]["coverage_floor"] == "100"
