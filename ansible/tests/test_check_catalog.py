"""The machine catalog checker's command-line behavior."""

import json
import subprocess
import sys
from pathlib import Path

import pytest

from machines import check_catalog


ROOT = Path(__file__).resolve().parents[2]
if ROOT.name == "mutants":
    ROOT = ROOT.parent
CATALOG = ROOT / "machines" / "catalog.json"


def assert_result(path, expected_code, expected_stdout, expected_stderr, capsys):
    assert check_catalog.main([str(path)]) == expected_code
    captured = capsys.readouterr()
    assert captured.out == expected_stdout
    assert captured.err == expected_stderr


def test_real_catalog(capsys):
    assert_result(CATALOG, 0, f"{CATALOG}: ok\n", "", capsys)


@pytest.mark.parametrize(
    ("change", "message"),
    [
        (
            "top_extra",
            "(top) | Additional properties are not allowed ('virtualbox' was unexpected)",
        ),
        (
            "disk",
            "digitalocean/classes/small | Additional properties are not allowed ('disk_gb' was unexpected)",
        ),
        ("region_missing", "digitalocean | 'region' is a required property"),
        ("bake_missing", "digitalocean | 'bake_class' is a required property"),
        ("sizes_missing", "digitalocean/classes/bake | 'sizes' is a required property"),
        ("sizes_empty", "digitalocean/classes/bake/sizes | [] should be non-empty"),
        (
            "sizes_repeat",
            "digitalocean/classes/small/sizes | ['s-1vcpu-1gb-amd', 's-1vcpu-1gb-amd'] has non-unique elements",
        ),
        (
            "sizes_string",
            "digitalocean/classes/small/sizes | 's-1vcpu-1gb-amd' is not of type 'array'",
        ),
        (
            "sizes_capital",
            "digitalocean/classes/small/sizes/0 | 'S-1VCPU' does not match '^[a-z0-9][a-z0-9-]*$'",
        ),
        (
            "class_capital",
            "digitalocean/classes | 'Big' does not match '^[a-z][a-z0-9-]*$'",
        ),
        ("classes_empty", "digitalocean/classes | {} should be non-empty"),
        (
            "machine_string",
            "digitalocean/machines/mail | 'small' is not of type 'object'",
        ),
        (
            "machine_empty",
            "digitalocean/machines/mail | 'class' is a required property",
        ),
        (
            "machine_size",
            "digitalocean/machines/mail | Additional properties are not allowed ('size' was unexpected)",
        ),
        ("bake_unknown", "digitalocean/bake_class | 'huge' is not a class"),
        ("machine_unknown", "digitalocean/machines/mail/class | 'big' is not a class"),
        (
            "two_schema",
            "digitalocean | 'region' is a required property\ndigitalocean/classes/small | Additional properties are not allowed ('disk_gb' was unexpected)",
        ),
        (
            "three_names",
            "digitalocean/bake_class | 'huge' is not a class\ndigitalocean/machines/mail/class | 'big' is not a class\ndigitalocean/machines/control/class | 'tiny' is not a class",
        ),
    ],
)
def test_refuses_invalid_catalog(change, message, tmp_path, capsys):
    catalog = json.loads(CATALOG.read_text())
    ocean = catalog["digitalocean"]
    classes = ocean["classes"]
    machines = ocean["machines"]
    if change == "top_extra":
        catalog["virtualbox"] = {}
    elif change == "disk":
        classes["small"]["disk_gb"] = 35
    elif change == "region_missing":
        del ocean["region"]
    elif change == "bake_missing":
        del ocean["bake_class"]
    elif change == "sizes_missing":
        del classes["bake"]["sizes"]
    elif change == "sizes_empty":
        classes["bake"]["sizes"] = []
    elif change == "sizes_repeat":
        classes["small"]["sizes"] = ["s-1vcpu-1gb-amd"] * 2
    elif change == "sizes_string":
        classes["small"]["sizes"] = "s-1vcpu-1gb-amd"
    elif change == "sizes_capital":
        classes["small"]["sizes"] = ["S-1VCPU"]
    elif change == "class_capital":
        classes["Big"] = {"sizes": ["s-1vcpu-1gb-amd"]}
    elif change == "classes_empty":
        ocean["classes"] = {}
    elif change == "machine_string":
        machines["mail"] = "small"
    elif change == "machine_empty":
        machines["mail"] = {}
    elif change == "machine_size":
        machines["mail"]["size"] = "s-1vcpu-1gb-amd"
    elif change == "bake_unknown":
        ocean["bake_class"] = "huge"
    elif change == "machine_unknown":
        machines["mail"]["class"] = "big"
    elif change == "two_schema":
        del ocean["region"]
        classes["small"]["disk_gb"] = 35
    elif change == "three_names":
        ocean["bake_class"] = "huge"
        machines["mail"]["class"] = "big"
        machines["control"]["class"] = "tiny"
    path = tmp_path / "catalog.json"
    path.write_text(json.dumps(catalog))
    assert_result(path, 1, "", f"{message}\n", capsys)


def test_missing_file(tmp_path, capsys):
    path = tmp_path / "missing.json"
    assert_result(
        path, 1, "", f"{path}: [Errno 2] No such file or directory: '{path}'\n", capsys
    )


def test_bad_json(tmp_path, capsys):
    path = tmp_path / "broken.json"
    path.write_text("{")
    assert_result(
        path,
        1,
        "",
        f"{path}: Expecting property name enclosed in double quotes: line 1 column 2 (char 1)\n",
        capsys,
    )


@pytest.mark.parametrize("args", [[], ["one", "two"]])
def test_usage(args, capsys):
    assert check_catalog.main(args) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == "usage: check_catalog.py <file>\n"


def test_program_on_real_catalog():
    result = subprocess.run(
        [sys.executable, str(ROOT / "machines" / "check_catalog.py"), str(CATALOG)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    assert result.stdout == f"{CATALOG}: ok\n"
    assert result.stderr == ""
