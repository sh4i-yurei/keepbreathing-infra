"""CI driver selection follows the repository's actual dependencies."""

import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

from ci.select_jobs import main, select_jobs


ROOT = Path(__file__).resolve().parents[2]
JOBS = {
    "b2-bucket",
    "b2-copy",
    "backup-server",
    "break-glass-sheet",
    "hub-backup-disk",
    "openbao",
    "vaultwarden-backup",
}


DIFF_115 = """ARCHITECTURE.md
ansible/roles/break_glass_sheet/tasks/proof.yml
ansible/roles/break_glass_sheet/tasks/prove-write-refusal.yml
ansible/tests/b2_bucket/fake_b2.py
ansible/tests/break_glass_sheet/assertions.py
ansible/tests/break_glass_sheet/run.sh""".splitlines()
DIFF_114 = """.github/workflows/ci.yml
ARCHITECTURE.md
ansible/host_vars/hub.yml
ansible/playbooks/hub.yml
ansible/roles/openbao/defaults/main.yml
ansible/roles/openbao/handlers/main.yml
ansible/roles/openbao/meta/argument_specs.yml
ansible/roles/openbao/tasks/account.yml
ansible/roles/openbao/tasks/main.yml
ansible/roles/openbao/tasks/predict.yml
ansible/roles/openbao/tasks/verify.yml
ansible/roles/openbao/templates/first-start.hcl.j2
ansible/roles/openbao/templates/openbao.container.j2
ansible/roles/openbao/templates/openbao.hcl.j2
ansible/tests/openbao/missing-admin.yml
ansible/tests/openbao/missing-user.yml
ansible/tests/openbao/role.yml
ansible/tests/openbao/run.sh
ansible/tests/openbao/verify.yml""".splitlines()
DIFF_111 = [
    ".github/workflows/ci.yml",
    "AGENTS.md",
    "ARCHITECTURE.md",
    "ansible/tests/test_ci_python.py",
]


@pytest.mark.parametrize(
    ("paths", "full", "jobs"),
    [
        (DIFF_115, False, {"b2-bucket", "break-glass-sheet"}),
        (DIFF_114, True, JOBS),
        (DIFF_111, True, JOBS),
        (
            ["ansible/roles/openbao/tasks/main.yml", "ansible/tests/openbao/run.sh"],
            False,
            {"openbao"},
        ),
        (
            ["ansible/tests/lib/undo.sh"],
            False,
            {"b2-copy", "break-glass-sheet", "openbao", "vaultwarden-backup"},
        ),
        (
            ["ansible/roles/backup_server/tasks/main.yml"],
            False,
            {"b2-copy", "backup-server", "vaultwarden-backup"},
        ),
        (["ansible/roles/tailscale_service/tasks/main.yml"], False, {"backup-server"}),
        (["ansible/roles/hub/tasks/main.yml"], False, {"hub-backup-disk"}),
        (["ansible/roles/baseline/tasks/main.yml"], False, set()),
        (["ansible/tests/test_ci_python.py", "README.md"], False, set()),
        (
            ["ansible/roles/backup_server/README.md"],
            False,
            {"b2-copy", "backup-server", "vaultwarden-backup"},
        ),
        (["ansible/roles/README.md"], True, JOBS),
        (["docs/a/b/c.txt"], True, JOBS),
        (
            [
                "ansible/playbooks/hub.yml",
                "workstation/setup.ps1",
                "tailscale/policy.hujson",
                "docs/notes.md",
            ],
            False,
            set(),
        ),
        *[
            ([path], True, JOBS)
            for path in (
                "pyproject.toml",
                "ansible/group_vars/all.yml",
                "ansible/filter_plugins/b2_bucket.py",
                "ansible/ansible.cfg",
                "docs/notes.txt",
            )
        ],
    ],
)
def test_real_path_selection(paths, full, jobs):
    assert select_jobs(paths, ROOT) == (full, jobs)


def test_new_driver_is_discovered(tmp_path):
    shutil.copytree(
        ROOT / "ansible",
        tmp_path / "ansible",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    shutil.copytree(ROOT / ".github", tmp_path / ".github")
    folder = tmp_path / "ansible/tests/newdriver"
    folder.mkdir()
    (folder / "run.sh").write_text("#!/bin/sh\n")
    (folder / "role.yml").write_text("- hosts: localhost\n  roles:\n    - openbao\n")
    workflow_path = tmp_path / ".github/workflows/ci.yml"
    workflow = yaml.load(workflow_path.read_text(), Loader=yaml.BaseLoader)
    workflow["jobs"]["newdriver"] = {"steps": [{"run": "bash tests/newdriver/run.sh"}]}
    workflow_path.write_text(yaml.safe_dump(workflow))
    assert select_jobs(["ansible/roles/openbao/tasks/main.yml"], tmp_path) == (
        False,
        {"openbao", "newdriver"},
    )


def test_nested_role_and_meta_dependencies(tmp_path):
    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / ".github/workflows/ci.yml").write_text(
        "jobs:\n  example:\n    steps:\n      - run: bash tests/example/run.sh\n"
    )
    driver = tmp_path / "ansible/tests/example"
    driver.mkdir(parents=True)
    (driver / "run.sh").write_text("#!/bin/sh\n")
    (driver / "nested").mkdir()
    (driver / "nested/empty.yml").write_text("")
    (driver / "nested/cache.pyc").write_bytes(b"\xff\xfe\x00")
    (driver / "nested/helpers.yaml").write_text(
        "# tests/decoy/ignored.sh\n- vars:\n    source: tests/lib/runner.sh\n"
    )
    (driver / "role.yaml").write_text(
        "- hosts: localhost\n  roles:\n    - first\n"
        "  tasks:\n    - block:\n        - ansible.builtin.include_role:\n            name: first\n"
    )
    (tmp_path / "ansible/tests/lib").mkdir()
    (tmp_path / "ansible/tests/decoy").mkdir()
    first = tmp_path / "ansible/roles/first"
    (first / "meta").mkdir(parents=True)
    (first / "meta/main.yml").write_text("dependencies:\n  - name: second\n")
    second = tmp_path / "ansible/roles/second/tasks"
    second.mkdir(parents=True)
    (second / "main.yaml").write_text(
        "- import_role:\n    name: third\n"
        "- ansible.builtin.import_role:\n    name: first\n"
    )
    third = tmp_path / "ansible/roles/third/tasks"
    third.mkdir(parents=True)
    (third / "main.yaml").write_text(
        "- ansible.builtin.include_role:\n    name: fourth\n"
    )
    (tmp_path / "ansible/roles/fourth").mkdir()
    try:
        library_result = select_jobs(["ansible/tests/lib/runner.sh"], tmp_path)
        decoy_result = select_jobs(["ansible/tests/decoy/ignored.sh"], tmp_path)
        role_result = select_jobs(["ansible/roles/fourth/tasks/main.yml"], tmp_path)
    except UnicodeDecodeError:
        library_result, decoy_result, role_result = None, None, None
    assert library_result == (False, {"example"})
    assert decoy_result == (False, set())
    assert role_result == (False, {"example"})


@pytest.mark.parametrize(
    "reference",
    [
        "roles:\n  - alpha\n",
        "roles:\n  - role: alpha\n",
        "roles:\n  - name: alpha\n",
        "tasks:\n  - import_role: alpha\n",
        "tasks:\n  - include_role:\n      name: alpha\n",
        "tasks:\n  - ansible.builtin.import_role:\n      name: alpha\n",
        "tasks:\n  - block:\n      - ansible.builtin.include_role:\n          name: alpha\n",
    ],
)
def test_each_role_reference_form_selects_its_driver(tmp_path, reference):
    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / ".github/workflows/ci.yml").write_text(
        "jobs:\n  example:\n    steps:\n      - run: bash tests/example/run.sh\n"
    )
    driver = tmp_path / "ansible/tests/example"
    driver.mkdir(parents=True)
    (driver / "run.sh").write_text("#!/bin/sh\n")
    (driver / "role.yml").write_text(
        "- hosts: localhost\n  " + reference.replace("\n", "\n  ")
    )
    (tmp_path / "ansible/roles/alpha").mkdir(parents=True)
    assert select_jobs(["ansible/roles/alpha/tasks/main.yml"], tmp_path) == (
        False,
        {"example"},
    )


@pytest.mark.parametrize(
    "role_yaml",
    [
        "roles:\n  - foo: bar\n",
        "roles:\n  - - nested\n",
        "tasks:\n  - include_role:\n      foo: bar\n",
    ],
)
def test_invalid_role_reference_fails_selection(tmp_path, role_yaml):
    (tmp_path / ".github/workflows").mkdir(parents=True)
    (tmp_path / ".github/workflows/ci.yml").write_text(
        "jobs:\n  example:\n    steps:\n      - run: bash tests/example/run.sh\n"
    )
    driver = tmp_path / "ansible/tests/example"
    driver.mkdir(parents=True)
    (driver / "run.sh").write_text("#!/bin/sh\n")
    (driver / "role.yml").write_text(
        "- hosts: localhost\n  " + role_yaml.replace("\n", "\n  ")
    )
    (tmp_path / "ansible/roles").mkdir()
    with pytest.raises(ValueError):
        select_jobs(["ansible/tests/example/run.sh"], tmp_path)


def git(repo, *args):
    env = {key: os.environ[key] for key in ("PATH",) if key in os.environ}
    env.update(
        {
            "HOME": str(repo),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        }
    )
    subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True)


@pytest.fixture
def git_repo(tmp_path):
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    (repo / "README.md").write_text("initial\n")
    (repo / "pyproject.toml").write_text("initial\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "initial")
    git(repo, "branch", "-M", "main")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(repo, "checkout", "-qb", "feature")
    (repo / "ansible/roles/openbao/tasks").mkdir(parents=True)
    (repo / "ansible/roles/openbao/tasks/main.yml").write_text("---\n")
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "role edit")
    (repo / ".github/workflows").mkdir(parents=True)
    shutil.copy2(ROOT / ".github/workflows/ci.yml", repo / ".github/workflows/ci.yml")
    for folder in (ROOT / "ansible/tests").iterdir():
        if folder.is_dir() and (folder / "run.sh").exists():
            shutil.copytree(folder, repo / "ansible/tests" / folder.name)
    for role in (ROOT / "ansible/roles").iterdir():
        if role.is_dir() and not (repo / "ansible/roles" / role.name).exists():
            shutil.copytree(role, repo / "ansible/roles" / role.name)
    return repo


@pytest.mark.parametrize(
    ("event", "ref", "remove_base", "expected_full"),
    [
        ("push", "refs/heads/main", False, True),
        ("pull_request", "refs/heads/feature", False, True),
        ("push", "refs/heads/feature", False, False),
        ("push", "refs/heads/feature", True, True),
    ],
)
def test_main_outputs(
    git_repo, tmp_path, monkeypatch, capsys, event, ref, remove_base, expected_full
):
    if remove_base:
        git(git_repo, "update-ref", "-d", "refs/remotes/origin/main")
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main(event, ref, git_repo)
    lines = output.read_text().splitlines()
    assert capsys.readouterr().out == output.read_text()
    if expected_full:
        assert lines == ["full=true"] + [
            f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
        ]
    else:
        assert lines == ["full=false"] + [
            f"{job.replace('-', '_')}={'true' if job == 'openbao' else 'false'}"
            for job in sorted(JOBS)
        ]


def test_main_selects_readers_of_both_rename_paths(tmp_path, monkeypatch, capsys):
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "-q")
    workflow = repo / ".github/workflows"
    workflow.mkdir(parents=True)
    shutil.copy2(ROOT / ".github/workflows/ci.yml", workflow / "ci.yml")
    for folder in (ROOT / "ansible/tests").iterdir():
        if folder.is_dir() and ((folder / "run.sh").exists() or folder.name == "lib"):
            shutil.copytree(folder, repo / "ansible/tests" / folder.name)
    for role in (ROOT / "ansible/roles").iterdir():
        if role.is_dir():
            shutil.copytree(role, repo / "ansible/roles" / role.name)
    git(repo, "add", ".")
    git(repo, "commit", "-qm", "base")
    git(repo, "branch", "-M", "main")
    git(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
    git(repo, "checkout", "-qb", "feature")
    git(repo, "mv", "ansible/tests/lib/undo.sh", "ansible/tests/openbao/undo.sh")
    git(repo, "commit", "-qm", "move shared helper")

    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main("push", "refs/heads/feature", repo)
    assert output.read_text().splitlines() == ["full=false"] + [
        f"{job.replace('-', '_')}={'true' if job in {'b2-copy', 'break-glass-sheet', 'openbao', 'vaultwarden-backup'} else 'false'}"
        for job in sorted(JOBS)
    ]
    assert capsys.readouterr().out == output.read_text()


def test_main_fails_open_when_selector_raises(git_repo, tmp_path, monkeypatch):
    import ci.select_jobs as selector

    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))

    def fail(*_args):
        raise ValueError("broken selector")

    monkeypatch.setattr(selector, "select_jobs", fail)
    main("push", "refs/heads/feature", git_repo)
    assert output.read_text().splitlines() == ["full=true"] + [
        f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
    ]


def test_main_fails_open_when_workflow_cannot_be_read(tmp_path, monkeypatch):
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main("push", "refs/heads/feature", tmp_path)
    assert output.read_text() == "full=true\n"


def test_main_branch_with_workflow_change_is_full(git_repo, tmp_path, monkeypatch):
    git(git_repo, "add", ".github/workflows/ci.yml")
    git(git_repo, "commit", "-qm", "workflow edit")
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main("push", "refs/heads/feature", git_repo)
    assert output.read_text().splitlines() == ["full=true"] + [
        f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
    ]


def test_main_compares_commits_not_uncommitted_files(git_repo, tmp_path, monkeypatch):
    (git_repo / "pyproject.toml").write_text("uncommitted\n")
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main("push", "refs/heads/feature", git_repo)
    assert output.read_text().splitlines() == ["full=false"] + [
        f"{job.replace('-', '_')}={'true' if job == 'openbao' else 'false'}"
        for job in sorted(JOBS)
    ]


def test_main_uses_repository_root_by_default(tmp_path, monkeypatch):
    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    main("push", "refs/heads/main")
    assert output.read_text().splitlines() == ["full=true"] + [
        f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
    ]


def test_command_entry_writes_full_for_main(git_repo, tmp_path, monkeypatch):
    import runpy
    import sys

    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    (git_repo / "ci").mkdir()
    script = git_repo / "ci/select_jobs.py"
    shutil.copy2(ROOT / "ci/select_jobs.py", script)
    monkeypatch.setattr(sys, "argv", [str(script), "push", "refs/heads/main"])
    runpy.run_path(str(script), run_name="__main__")
    assert output.read_text().splitlines() == ["full=true"] + [
        f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
    ]


def test_repository_command_entry_writes_full_for_main(tmp_path, monkeypatch):
    import runpy
    import sys

    output = tmp_path / "output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    script = ROOT / "ci/select_jobs.py"
    monkeypatch.setattr(sys, "argv", [str(script), "push", "refs/heads/main"])
    runpy.run_path(str(script), run_name="__main__")
    assert output.read_text().splitlines() == ["full=true"] + [
        f"{job.replace('-', '_')}=true" for job in sorted(JOBS)
    ]


def test_workflow_jobs():
    workflow = yaml.load(
        (ROOT / ".github/workflows/ci.yml").read_text(), Loader=yaml.BaseLoader
    )
    assert workflow["on"] == {"push": {}, "pull_request": {}}
    jobs = workflow["jobs"]
    assert set(jobs) == JOBS | {"changes", "ansible-lint", "syntax-check", "python"}
    for job in JOBS:
        assert jobs[job]["needs"] == "changes"
        assert jobs[job]["if"] == (
            "${{ !cancelled() && (needs.changes.result != 'success' || "
            "needs.changes.outputs.full == 'true' || "
            "needs.changes.outputs." + job.replace("-", "_") + " == 'true') }}"
        )
    for job in ("ansible-lint", "syntax-check", "python"):
        assert "needs" not in jobs[job]
        assert "if" not in jobs[job]
